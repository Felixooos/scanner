/*
 * empreinte_scanner.ino — ESP32 DevKit + capteur d'empreintes JM-101
 *
 * Capture l'image brute de l'empreinte (commande UpImage du protocole
 * ZhianTec, le même que les modules R307 / AS608 / R503) et l'envoie
 * en hexadécimal sur le port USB, encadrée par des marqueurs
 * <IMG_START ...> / <IMG_END>.
 *
 * Sur le Mac, lancer capture_empreinte.py : il écoute le port série
 * et enregistre chaque capture en PNG.
 *
 * Branchements JM-101 8 fils (brochage officiel du manuel v1.8) :
 *   broche 1  +3.3V    -> 3V3 ESP32   (JAMAIS le 5V / VIN !)
 *   broche 2  TX       -> GPIO 16 (RX2)
 *   broche 3  RX       -> GPIO 17 (TX2)
 *   broche 4  GND      -> GND
 *   broche 5  Touch    -> GPIO 4 (detection du doigt, conseille !)
 *   broche 6  TouchVin -> 3V3 (obligatoire si Touch est branché)
 *   broche 7  D+ USB   -> non branché
 *   broche 8  D- USB   -> non branché
 * La broche 1 est repérée sur le connecteur du module (le fil rouge
 * de la nappe est en général dessus).
 */

#include <HardwareSerial.h>

HardwareSerial capteur(2);                 // UART2 de l'ESP32

static const int  BROCHE_RX2   = 16;       // relié au TX du capteur
static const int  BROCHE_TX2   = 17;       // relié au RX du capteur
static const int  BROCHE_TOUCH = 4;        // relié au TCH du capteur (haut = doigt)
static const int  BROCHE_VA    = 32;       // sortie 3,3 V pour le VA du capteur
                                           // (si la broche 3V3 est deja prise)
static const uint32_t BAUD_CAPTEUR = 57600;   // vitesse STABLE du capteur
// (a 115200 le capteur se bloquait apres 1-2 scans, sur les deux cartes)
/* ---------- bouton + LEDs (le tableau de bord) ---------- */

static const int BROCHE_BOUTON  = 33;      // bouton -> GND (resistance interne)
static const int BROCHE_BLEUE_A = 25;      // LED bleue 1 (+ resistance 220-330 O)
static const int BROCHE_BLEUE_B = 26;      // LED bleue 2
static const int BROCHE_RGB_R   = 27;      // LED RGB : rouge
static const int BROCHE_RGB_V   = 14;      //           vert
static const int BROCHE_RGB_B   = 13;      //           bleu

// Passe a true si ta LED RGB est a ANODE commune (patte longue au 3V3).
// A false = cathode commune (patte longue au GND) : le cas le plus courant.
static const bool RGB_ANODE_COMMUNE = false;

// Etats possibles : chacun a sa couleur et son animation.
enum EtatLed {
  ETAT_DEMARRAGE,   // blanc clignotant : ca demarre
  ETAT_PRET,        // bleu qui respire : pret, en attente
  ETAT_ATTENTE,     // orange qui pulse : pose ton doigt !
  ETAT_TRANSFERT,   // cyan + chenillard : l'image arrive
  ETAT_OK,          // vert : raccorde / reussi
  ETAT_ERREUR,      // rouge : rate
  ETAT_TRAVAIL,     // violet qui respire : le Mac calcule
  ETAT_MUET         // rouge/orange alterne : capteur introuvable
};

static const uint32_t BAUD_USB     = 921600;  // OK pour CP2102 (= BAUD du
                                              // script Mac). CH340 : 115200 !

static const uint32_t ADRESSE = 0xFFFFFFFF;   // adresse par défaut du module

// Tampon image : 256x288 pixels sur 4 bits = 36 864 octets maxi
static uint8_t image[40960];
static size_t  tailleImage = 0;

/* ---------- couche protocole ---------- */

// Envoie un paquet de commande (pid 0x01)
void envoyerCommande(const uint8_t *charge, uint16_t n) {
  uint16_t longueur = n + 2;                       // charge + checksum
  uint16_t somme = 0x01 + (longueur >> 8) + (longueur & 0xFF);
  uint8_t entete[9] = {
    0xEF, 0x01,
    (uint8_t)(ADRESSE >> 24), (uint8_t)(ADRESSE >> 16),
    (uint8_t)(ADRESSE >> 8),  (uint8_t)(ADRESSE),
    0x01, (uint8_t)(longueur >> 8), (uint8_t)(longueur & 0xFF)
  };
  capteur.write(entete, 9);
  for (uint16_t i = 0; i < n; i++) somme += charge[i];
  capteur.write(charge, n);
  capteur.write((uint8_t)(somme >> 8));
  capteur.write((uint8_t)(somme & 0xFF));
}

int lireOctet(uint32_t delaiMs) {
  uint32_t debut = millis();
  while (millis() - debut < delaiMs) {
    if (capteur.available()) return capteur.read();
  }
  return -1;                                       // délai dépassé
}

// Lit un paquet du capteur. Retourne le pid (0x07 ack, 0x02 données,
// 0x08 dernier paquet de données) ou -1 en cas d'erreur.
// La charge utile (sans checksum) est copiée dans `charge`, taille dans `n`.
int lirePaquet(uint8_t *charge, uint16_t maxN, uint16_t *n, uint32_t delaiMs) {
  // Cherche l'en-tête EF 01
  while (true) {
    int o = lireOctet(delaiMs);
    if (o < 0) return -1;
    if (o != 0xEF) continue;
    o = lireOctet(delaiMs);
    if (o == 0x01) break;
  }
  for (int i = 0; i < 4; i++) if (lireOctet(delaiMs) < 0) return -1;  // adresse

  int pid = lireOctet(delaiMs);
  int lh  = lireOctet(delaiMs);
  int ll  = lireOctet(delaiMs);
  if (pid < 0 || lh < 0 || ll < 0) return -1;

  uint16_t longueur = ((uint16_t)lh << 8) | ll;    // charge + 2 (checksum)
  if (longueur < 2) return -1;
  uint16_t nCharge = longueur - 2;
  if (nCharge > maxN) return -1;

  uint16_t somme = pid + lh + ll;
  for (uint16_t i = 0; i < nCharge; i++) {
    int o = lireOctet(delaiMs);
    if (o < 0) return -1;
    charge[i] = (uint8_t)o;
    somme += o;
  }
  int sh = lireOctet(delaiMs);
  int sl = lireOctet(delaiMs);
  if (sh < 0 || sl < 0) return -1;
  if ((((uint16_t)sh << 8) | sl) != somme) {
    Serial.println("# Attention : checksum invalide sur un paquet");
  }
  *n = nCharge;
  return pid;
}

// Envoie une commande et retourne le code de confirmation de l'ack
int commande(const uint8_t *charge, uint16_t n, uint32_t delaiMs = 1000) {
  // vide ce qui traine dans le tampon de réception
  while (capteur.available()) capteur.read();
  envoyerCommande(charge, n);
  uint8_t rep[64];
  uint16_t nRep = 0;
  int pid = lirePaquet(rep, sizeof(rep), &nRep, delaiMs);
  if (pid != 0x07 || nRep < 1) return -1;
  return rep[0];
}

/* ---------- commandes du capteur ---------- */

int verifierMotDePasse() {                         // VfyPwd, mot de passe 0
  uint8_t c[5] = { 0x13, 0x00, 0x00, 0x00, 0x00 };
  return commande(c, 5);
}

// SetSysPara : réglage n°4 = vitesse série, valeur N -> N x 9600 bauds
int reglerVitesseCapteur(uint32_t bauds) {
  uint8_t c[3] = { 0x0E, 0x04, (uint8_t)(bauds / 9600) };
  return commande(c, 3);
}

// Vide tout ce qui traine sur la liaison capteur (par exemple une image
// dont l'envoi a ete interrompu par un redemarrage) : on attend 300 ms
// de silence complet avant de reprendre la parole. Evite de desynchroniser
// le capteur, qui sinon peut se bloquer jusqu'a une coupure de courant.
void purgerCapteur(uint32_t maxMs = 6000) {
  uint32_t debut = millis();
  uint32_t dernierOctet = millis();
  while (millis() - debut < maxMs) {
    if (capteur.available()) {
      capteur.read();
      dernierOctet = millis();
    } else if (millis() - dernierOctet > 300) {
      return;
    }
  }
}

// Cherche le capteur a 57600 puis 115200 ; s'il est sur une autre vitesse
// que BAUD_CAPTEUR, on le remet dessus (grave dans sa memoire flash).
// Deux tentatives completes, avec purge de la liaison entre chaque.
int connecterCapteur() {
  const uint32_t vitesses[2] = { BAUD_CAPTEUR, 115200 };
  for (int essai = 0; essai < 2; essai++) {
    for (int v = 0; v < 2; v++) {
      capteur.updateBaudRate(vitesses[v]);
      purgerCapteur();
      if (verifierMotDePasse() != 0x00) continue;
      if (vitesses[v] == BAUD_CAPTEUR) return 0x00;

      Serial.println("# Capteur remis a la vitesse stable (57600)...");
      if (reglerVitesseCapteur(BAUD_CAPTEUR) == 0x00) {
        delay(100);
        capteur.updateBaudRate(BAUD_CAPTEUR);
        delay(100);
        if (verifierMotDePasse() == 0x00) return 0x00;
      } else {
        return 0x00;                    // reste sur l'autre vitesse, tant pis
      }
    }
  }
  return -1;
}

int capturerImage() {                              // GenImg
  uint8_t c[1] = { 0x01 };
  return commande(c, 1);                           // 0x00 ok, 0x02 pas de doigt
}

// Img2Tz : tente d'extraire les minuties (les details caracteristiques) de
// l'image capturee. C'est LE bon filtre anti-chiffon : une vraie empreinte
// donne 0x00, une surface sans cretes donne 0x06 (image confuse) ou 0x07
// (trop peu de points caracteristiques).
int genererModele(uint8_t buffer) {
  uint8_t c[2] = { 0x02, buffer };                 // vers le buffer 1 ou 2
  return commande(c, 2, 3000);
}

// Match : compare les deux modeles extraits (buffer 1 vs buffer 2).
// Deux captures d'un MEME doigt immobile concordent (0x00) ; deux captures
// d'un chiffon donnent des motifs aleatoires qui ne concordent pas.
int comparerModeles() {
  uint8_t c[1] = { 0x03 };
  return commande(c, 1, 3000);                     // 0x00 = concordance
}

// UpImage : demande le transfert de l'image vers l'ESP32
bool telechargerImage() {
  uint8_t c[1] = { 0x0A };
  int code = commande(c, 1);
  if (code != 0x00) {
    Serial.print("# Erreur UpImage, code 0x");
    Serial.println(code, HEX);
    return false;
  }
  tailleImage = 0;
  uint8_t charge[300];
  uint16_t n = 0;
  while (true) {
    int pid = lirePaquet(charge, sizeof(charge), &n, 3000);
    if (pid < 0) {
      Serial.println("# Erreur : transfert interrompu (delai depasse)");
      return false;
    }
    if (pid == 0x02 || pid == 0x08) {
      if (tailleImage + n <= sizeof(image)) {
        memcpy(image + tailleImage, charge, n);
        tailleImage += n;
      }
      if (pid == 0x08) return true;                // dernier paquet
    }
  }
}

/* ---------- envoi vers le Mac ---------- */

void envoyerImageUSB() {
  Serial.println();
  Serial.print("<IMG_START octets=");
  Serial.print(tailleImage);
  Serial.println(">");
  char hexa[3];
  for (size_t i = 0; i < tailleImage; i++) {
    sprintf(hexa, "%02X", image[i]);
    Serial.print(hexa);
    if ((i + 1) % 64 == 0) Serial.println();       // lignes de 64 octets
  }
  if (tailleImage % 64 != 0) Serial.println();
  Serial.println("<IMG_END>");
}

/* ---------- le tableau de bord lumineux ---------- */

static bool doigtArme = true;      // false = doigt pas encore relache (anti-repetition)

// Veille (declarees ici : setup() s'en sert, et l'Arduino exige que les
// variables soient connues AVANT leur premiere utilisation).
static const uint32_t SILENCE_VEILLE = 30000;   // ms de silence du Mac
static bool enVeille = false;
static uint32_t dernierMot = 0;                 // date du dernier octet recu
static EtatLed etatLed = ETAT_DEMARRAGE;
static uint32_t etatDepuis = 0;
static EtatLed etatApres = ETAT_PRET;      // etat vers lequel revenir (OK/ERREUR)

static const uint32_t PWM_FREQ = 5000;
static const uint8_t  PWM_RES  = 8;

static void pwmInit(int broche, int canal) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttachChannel(broche, PWM_FREQ, PWM_RES, canal);
#else
  ledcSetup(canal, PWM_FREQ, PWM_RES);
  ledcAttachPin(broche, canal);
#endif
}

static void pwmEcrire(int broche, int canal, int valeur) {
  if (valeur < 0) valeur = 0;
  if (valeur > 255) valeur = 255;
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  (void)canal;
  ledcWrite(broche, valeur);
#else
  (void)broche;
  ledcWrite(canal, valeur);
#endif
}

static void rgb(int r, int v, int b) {
  if (RGB_ANODE_COMMUNE) { r = 255 - r; v = 255 - v; b = 255 - b; }
  pwmEcrire(BROCHE_RGB_R, 2, r);
  pwmEcrire(BROCHE_RGB_V, 3, v);
  pwmEcrire(BROCHE_RGB_B, 4, b);
}

static void bleues(int a, int b) {
  pwmEcrire(BROCHE_BLEUE_A, 0, a);
  pwmEcrire(BROCHE_BLEUE_B, 1, b);
}

static void changerEtat(EtatLed nouvel) {
  etatLed = nouvel;
  etatDepuis = millis();
}

// Courbe de respiration douce (0 -> 255 -> 0) sur une periode donnee.
static int respiration(uint32_t t, uint32_t periode) {
  float phase = (float)(t % periode) / (float)periode;          // 0..1
  return (int)(255.0f * (0.5f - 0.5f * cosf(phase * 2.0f * PI)));
}

// A appeler tres souvent : fait vivre les LEDs sans jamais bloquer.
void animerLeds() {
  uint32_t t = millis() - etatDepuis;
  switch (etatLed) {
    case ETAT_DEMARRAGE: {
      int v = respiration(t, 700);
      rgb(v, v, v);                            // blanc qui pulse
      bleues(v / 3, v / 3);
      break;
    }
    case ETAT_PRET: {
      int v = respiration(t, 2600);            // bleu lent = ca dort tranquille
      rgb(0, v / 6, 20 + v * 3 / 4);
      bleues(v / 5, v / 5);
      break;
    }
    case ETAT_ATTENTE: {
      int v = respiration(t, 550);             // orange rapide = pose ton doigt
      rgb(255, 60 + v / 3, 0);
      // chenillard : les deux bleues se repondent
      bool gauche = ((t / 220) % 2) == 0;
      bleues(gauche ? 255 : 25, gauche ? 25 : 255);
      break;
    }
    case ETAT_TRANSFERT: {
      rgb(0, 200, 255);                        // cyan fixe = ca transfere
      int v = respiration(t, 300);
      bleues(v, 255 - v);
      break;
    }
    case ETAT_OK: {
      rgb(0, 255, 40);                         // vert franc
      bleues(255, 255);
      if (t > 1400) changerEtat(etatApres);
      break;
    }
    case ETAT_ERREUR: {
      bool on = ((t / 180) % 2) == 0;          // rouge qui clignote
      rgb(on ? 255 : 30, 0, 0);
      bleues(0, 0);
      if (t > 1600) changerEtat(etatApres);
      break;
    }
    case ETAT_TRAVAIL: {
      int v = respiration(t, 1200);            // violet = le Mac calcule
      rgb(120 + v / 3, 0, 200);
      int p = (t / 130) % 4;                   // aller-retour entre les bleues
      bleues(p == 0 || p == 1 ? 255 : 20, p == 2 || p == 3 ? 255 : 20);
      break;
    }
    case ETAT_MUET: {
      bool on = ((t / 400) % 2) == 0;          // rouge/orange = capteur absent
      rgb(255, on ? 90 : 0, 0);
      bleues(on ? 60 : 0, on ? 0 : 60);
      break;
    }
  }
}

// Petite pause qui garde les LEDs vivantes (remplace delay()).
static void attendreAnime(uint32_t ms) {
  uint32_t debut = millis();
  while (millis() - debut < ms) {
    animerLeds();
    delay(5);
  }
}

/* ---------- programme principal ---------- */

void setup() {
  Serial.begin(BAUD_USB);
  pinMode(BROCHE_BOUTON, INPUT_PULLUP);    // bouton entre GPIO et GND
  pwmInit(BROCHE_BLEUE_A, 0);
  pwmInit(BROCHE_BLEUE_B, 1);
  pwmInit(BROCHE_RGB_R, 2);
  pwmInit(BROCHE_RGB_V, 3);
  pwmInit(BROCHE_RGB_B, 4);
  changerEtat(ETAT_DEMARRAGE);
  animerLeds();
  pinMode(BROCHE_TOUCH, INPUT_PULLDOWN);   // TCH non branché -> lit toujours 0
  pinMode(BROCHE_VA, OUTPUT);
  digitalWrite(BROCHE_VA, HIGH);           // alimente le circuit tactile (VA)
  capteur.setRxBufferSize(4096);
  capteur.begin(BAUD_CAPTEUR, SERIAL_8N1, BROCHE_RX2, BROCHE_TX2);
  delay(300);

  Serial.println();
  Serial.println("# ESP32 + JM-101 : capture d'image d'empreinte");

  int code = connecterCapteur();
  if (code == 0x00) {
    Serial.println("# Capteur detecte, tout est pret.");
    etatApres = ETAT_PRET;
    changerEtat(ETAT_OK);                  // petit flash vert de bienvenue
  } else {
    Serial.print("# Capteur introuvable (code ");
    Serial.print(code);
    Serial.println("). Verifie les branchements TX/RX et l'alimentation 3V3.");
    etatApres = ETAT_MUET;
    changerEtat(ETAT_MUET);
  }
  Serial.println("# Appuie sur le bouton (ou envoie SCAN depuis le Mac).");
  // Le compte a rebours de la veille ne demarre qu'ici : la detection du
  // capteur prend plusieurs secondes, elles ne doivent pas etre comptees.
  dernierMot = millis();
}

// Tente la capture pendant 10 s, puis transfere l'image.
void lancerScan() {
  Serial.println("# Scan lance : pose ton doigt !");
  doigtArme = false;      // pas de nouveau declenchement tant qu'on n'a pas retire le doigt
  etatApres = ETAT_PRET;
  changerEtat(ETAT_ATTENTE);               // orange : pose ton doigt
  uint32_t debut = millis();
  uint32_t pasDeDoigt = 0, echecImage = 0, autres = 0;
  int dernierCode = 0;
  uint32_t dernierEssai = 0;
  bool toucherVu = false;
  while (millis() - debut < 10000) {
    bool doigt = digitalRead(BROCHE_TOUCH) == HIGH;   // detection tactile
    if (doigt) toucherVu = true;
    // doigt pose -> capture immediate ; sinon (ou TCH non branche) on
    // sonde quand meme le capteur toutes les 700 ms en repli
    if (!doigt && millis() - dernierEssai < 700) {
      animerLeds();
      delay(20);
      continue;
    }
    dernierEssai = millis();
    int code = capturerImage();
    if (code == 0x00) {                            // doigt détecté, image prise
      Serial.println("# Doigt detecte, transfert de l'image...");
      changerEtat(ETAT_TRANSFERT);                 // cyan : l'image arrive
      animerLeds();
      if (telechargerImage()) {
        envoyerImageUSB();
        Serial.println("# Termine.");
        etatApres = ETAT_PRET;
        changerEtat(ETAT_OK);                      // vert : c'est dans la boite
      } else {
        Serial.println("<SCAN_FAIL>");
        etatApres = ETAT_PRET;
        changerEtat(ETAT_ERREUR);
      }
      return;
    }
    if (code == 0x02) pasDeDoigt++;                // capteur : "pas de doigt"
    else if (code == 0x03) echecImage++;           // capteur : "image ratee"
    else {                                         // timeout / autre erreur
      autres++;
      dernierCode = code;
      if (autres == 3) {                           // capteur muet : on le reveille
        Serial.println("# Capteur muet, tentative de reveil...");
        if (connecterCapteur() == 0x00) {
          Serial.println("# Capteur revenu, scan toujours en cours !");
        }
      }
    }
    attendreAnime(100);
  }
  Serial.print("# Echec. Reponses du capteur : pas_de_doigt=");
  Serial.print(pasDeDoigt);
  Serial.print("  image_ratee=");
  Serial.print(echecImage);
  Serial.print("  autres=");
  Serial.print(autres);
  Serial.print("  toucher=");
  Serial.print(toucherVu ? "oui" : "non");
  if (autres > 0) {
    Serial.print(" (dernier code ");
    Serial.print(dernierCode);
    Serial.print(")");
  }
  Serial.println();
  if (autres > pasDeDoigt) {
    Serial.println("# Capteur bloque ? Coupe son fil GND 2 secondes, rebranche, et rescanne.");
  }
  Serial.println("<SCAN_FAIL>");
  etatApres = ETAT_PRET;
  changerEtat(ETAT_ERREUR);
}

String ordre;

// Le Mac pilote la couleur : "LED PRET", "LED TRAVAIL", "LED OK", ...
static void ordreLed(const String &mot) {
  etatApres = ETAT_PRET;
  if      (mot == "PRET")    changerEtat(ETAT_PRET);
  else if (mot == "TRAVAIL") changerEtat(ETAT_TRAVAIL);
  else if (mot == "ATTENTE") changerEtat(ETAT_ATTENTE);
  else if (mot == "OK")      changerEtat(ETAT_OK);
  else if (mot == "ERREUR")  changerEtat(ETAT_ERREUR);
  else if (mot == "MUET")  { etatApres = ETAT_MUET; changerEtat(ETAT_MUET); }
}

// "DIAG" : suit l'etat du bouton en direct pendant 8 s (pour le cablage).
static void diagnostic() {
  Serial.print("# DIAG bouton sur GPIO ");
  Serial.print(BROCHE_BOUTON);
  Serial.println(" : appuie et relache plusieurs fois (8 s).");
  uint32_t debut = millis();
  int dernier = -1;
  while (millis() - debut < 8000) {
    int etat = digitalRead(BROCHE_BOUTON);
    if (etat != dernier) {
      dernier = etat;
      Serial.print("# bouton = ");
      Serial.println(etat == LOW ? "APPUYE" : "relache");
    }
    animerLeds();
    delay(10);
  }
  Serial.println("# DIAG fini.");
}

// "DIAGTCH" : affiche l'etat BRUT du fil TCH pendant 20 s (cablage tactile).
static void diagnosticToucher() {
  Serial.print("# DIAGTCH sur GPIO ");
  Serial.print(BROCHE_TOUCH);
  Serial.println(" : pose et retire ton doigt (20 s).");
  uint32_t debut = millis(), dernierRapport = 0;
  int dernier = -1;
  uint32_t nbHaut = 0, nbTotal = 0;
  while (millis() - debut < 20000) {
    int etat = digitalRead(BROCHE_TOUCH);
    nbTotal++;
    if (etat == HIGH) nbHaut++;
    if (etat != dernier) {
      dernier = etat;
      Serial.print("# TCH -> ");
      Serial.println(etat == HIGH ? "DOIGT (haut)" : "rien (bas)");
    }
    if (millis() - dernierRapport > 2000) {        // rappel periodique
      dernierRapport = millis();
      Serial.print("# TCH niveau actuel = ");
      Serial.println(dernier == HIGH ? "haut" : "bas");
    }
    delay(10);
  }
  Serial.print("# DIAGTCH fini : ");
  Serial.print((100UL * nbHaut) / (nbTotal ? nbTotal : 1));
  Serial.println(" % du temps a l'etat haut.");
}

// "TESTLED" : allume chaque couleur une par une pour verifier le cablage.
static void testLeds() {
  Serial.println("# TESTLED : chaque couleur 1,2 s");
  Serial.println("# -> ROUGE");   rgb(255, 0, 0);   delay(1200);
  Serial.println("# -> VERT");    rgb(0, 255, 0);   delay(1200);
  Serial.println("# -> BLEU");    rgb(0, 0, 255);   delay(1200);
  Serial.println("# -> BLANC");   rgb(255, 255, 255); delay(1200);
  rgb(0, 0, 0);
  Serial.println("# -> bleue A"); bleues(255, 0);   delay(1000);
  Serial.println("# -> bleue B"); bleues(0, 255);   delay(1000);
  bleues(0, 0);
  Serial.println("# TESTLED fini.");
  etatApres = ETAT_PRET;
  changerEtat(ETAT_PRET);
}

// Declenchement au toucher : des que le doigt se pose sur la vitre, on
// attend qu'il se stabilise puis on previent le Mac, qui lance le scan.
static const uint32_t DELAI_POSE = 1500;   // temps de stabilisation (ms)

static void surveillerToucher() {
  if (digitalRead(BROCHE_TOUCH) != HIGH) { // plus de doigt : on rearme
    doigtArme = true;
    return;
  }
  if (!doigtArme) return;                  // doigt encore pose depuis le scan
  // doigt pose : on lui laisse le temps de se placer bien a plat
  uint32_t debut = millis();
  while (millis() - debut < DELAI_POSE) {
    if (digitalRead(BROCHE_TOUCH) != HIGH) return;   // retire trop tot
    animerLeds();
    delay(10);
  }
  doigtArme = false;                       // un seul declenchement par pose
  Serial.println("# TCH: contact stable, verification...");

  // Verification : le TCH est juste un detecteur de contact (un chiffon le
  // declenche aussi). On demande donc au capteur OPTIQUE s'il voit vraiment
  // une empreinte : lui seul sait faire la difference. On laisse au doigt le
  // temps de bien se plaquer (plusieurs essais sur ~1,5 s).
  int dernier = -1, dernierModele = -1;
  for (int essai = 0; essai < 10; essai++) {
    if (digitalRead(BROCHE_TOUCH) != HIGH) {        // contact parti = pas un doigt
      Serial.print("# TCH: contact retire pendant la verification (essai ");
      Serial.print(essai + 1);
      Serial.println(")");
      return;
    }
    dernier = capturerImage();
    if (dernier == 0x00) {
      // Une image a ete prise. Mais un chiffon aussi donne une image !
      // Epreuve 2 : le capteur trouve-t-il de vraies minuties ?
      dernierModele = genererModele(1);
      if (dernierModele == 0x00) {
        // Epreuve 3 : on reprend une 2e image et on verifie qu'elle
        // CONCORDE avec la premiere. Un doigt pose est immobile et donne
        // deux fois le meme motif ; un chiffon donne du bruit different.
        attendreAnime(120);
        if (digitalRead(BROCHE_TOUCH) == HIGH
            && capturerImage() == 0x00
            && genererModele(2) == 0x00
            && comparerModeles() == 0x00) {
          Serial.print("# TCH: empreinte confirmee (2 captures concordantes) au bout de ");
          Serial.print(essai + 1);
          Serial.println(" essai(s).");
          Serial.println("<TOUCHE>");
          return;
        }
        Serial.println("# TCH: minuties trouvees mais les 2 captures ne concordent pas.");
      }
    }
    attendreAnime(150);
  }
  Serial.print("# TCH: contact ignore apres 10 essais (image=");
  Serial.print(dernier);
  Serial.print(", minuties=");
  Serial.print(dernierModele);
  Serial.println(dernierModele == 6 || dernierModele == 7
                 ? " -> pas de cretes : ce n'est pas un doigt)"
                 : ")");
}

/* ---------- veille ----------
 * App fermee = plus rien ne doit rester allume. On coupe VA, la broche qui
 * alimente le circuit tactile du capteur (et son anneau lumineux), ainsi que
 * les LEDs du tableau de bord. L'ESP32 reste alimente par l'USB et guette la
 * reouverture de l'app : le moindre caractere recu le reveille.
 *
 * L'alimentation principale du capteur (broche 1) est cablee en dur sur le
 * 3V3 : elle, on ne peut pas la couper sans ajouter un transistor.
 */
/* ---------- extinction de la lampe du capteur ----------
 * L'alimentation du capteur (broche 1) est cablee en dur sur le 3V3 : on ne
 * peut pas la couper. En revanche le protocole ZhianTec prevoit d'eteindre
 * l'eclairage par commande. Deux dialectes existent selon le modele, on
 * essaie les deux et on garde celui qui repond 0x00.
 *   0x50 / 0x51 : allumer / eteindre (R305, R307, AS608...)
 *   0x35        : "aura" (R503) — ctrl 3 = allumee fixe, 4 = eteinte
 */
static int lampeSimple(bool allumee) {
  uint8_t charge[1] = { (uint8_t)(allumee ? 0x50 : 0x51) };
  return commande(charge, 1, 500);
}

static int lampeAura(bool allumee) {
  // ctrl, vitesse, couleur (1=rouge 2=bleu 3=violet), nombre de fois
  uint8_t charge[5] = { 0x35, (uint8_t)(allumee ? 3 : 4), 0x00, 0x02, 0x00 };
  return commande(charge, 5, 500);
}

static int dialecteLampe = -1;      // 0 = aucun, 1 = 0x50/0x51, 2 = aura

// Eteint (ou rallume) la lampe avec le dialecte qui marche sur CE module.
static void lampeCapteur(bool allumee) {
  if (dialecteLampe == 0) return;                  // module muet la-dessus
  if (dialecteLampe == 1) { lampeSimple(allumee); return; }
  if (dialecteLampe == 2) { lampeAura(allumee); return; }
  if (lampeSimple(allumee) == 0x00) { dialecteLampe = 1; return; }
  if (lampeAura(allumee) == 0x00)   { dialecteLampe = 2; return; }
  dialecteLampe = 0;
}

// "DIAGLED" : dit quelles commandes d'extinction le capteur accepte.
static void diagnosticLampe() {
  Serial.println("# DIAGLED : test des commandes d'extinction");
  int a = lampeSimple(false);
  Serial.print("#   0x51 (eteindre, dialecte simple) -> code ");
  Serial.println(a);
  delay(1200);
  int b = lampeSimple(true);
  Serial.print("#   0x50 (rallumer, dialecte simple) -> code ");
  Serial.println(b);
  delay(600);
  int c = lampeAura(false);
  Serial.print("#   0x35 (eteindre, dialecte aura)   -> code ");
  Serial.println(c);
  delay(1200);
  int d = lampeAura(true);
  Serial.print("#   0x35 (rallumer, dialecte aura)   -> code ");
  Serial.println(d);
  Serial.println(a == 0 || b == 0 ? "# -> dialecte SIMPLE accepte."
                 : (c == 0 || d == 0 ? "# -> dialecte AURA accepte."
                                     : "# -> aucun : il faudra couper le 3V3."));
}

static void entrerVeille() {
  if (enVeille) return;
  enVeille = true;
  lampeCapteur(false);                          // lampe du capteur eteinte
  digitalWrite(BROCHE_VA, LOW);                 // circuit tactile eteint
  rgb(0, 0, 0);
  bleues(0, 0);
  Serial.println("# veille : capteur eteint, en attente de l'app.");
}

static void sortirVeille() {
  if (!enVeille) return;
  enVeille = false;
  digitalWrite(BROCHE_VA, HIGH);
  delay(60);
  lampeCapteur(true);                           // on rallume la lampe                                    // le tactile se stabilise
  doigtArme = true;                             // pas de faux declenchement
  changerEtat(ETAT_PRET);
  Serial.println("# reveil : capteur rallume.");
}

// Bouton : anti-rebond simple, un seul evenement par appui.
static void lireBouton() {
  static bool enfonceAvant = false;
  static uint32_t dernierChangement = 0;
  bool enfonce = digitalRead(BROCHE_BOUTON) == LOW;   // LOW = appuye (pull-up)
  if (enfonce == enfonceAvant) return;
  if (millis() - dernierChangement < 40) return;      // rebond
  dernierChangement = millis();
  enfonceAvant = enfonce;
  if (enfonce) {
    Serial.println("<BOUTON>");                       // le Mac lancera le scan
    bleues(255, 255);                                 // petit flash de retour
  }
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    dernierMot = millis();                 // le Mac parle : il est toujours la
    sortirVeille();                        // (sans effet s'il ne dormait pas)
    if (c == '\n' || c == '\r') {
      ordre.trim();
      if (ordre.equalsIgnoreCase("PING")) { /* battement : rien a faire */ }
      else if (ordre.equalsIgnoreCase("VEILLE")) { ordre = ""; entrerVeille(); break; }
      else if (ordre.equalsIgnoreCase("SCAN")) lancerScan();
      else if (ordre.equalsIgnoreCase("DIAG")) diagnostic();
      else if (ordre.equalsIgnoreCase("DIAGTCH")) diagnosticToucher();
      else if (ordre.equalsIgnoreCase("DIAGLED")) diagnosticLampe();
      else if (ordre.equalsIgnoreCase("TESTLED")) testLeds();
      else if (ordre.startsWith("LED ") || ordre.startsWith("led ")) {
        String mot = ordre.substring(4);
        mot.trim();
        mot.toUpperCase();
        ordreLed(mot);
      }
      ordre = "";
    } else if (ordre.length() < 32) {
      ordre += c;
    }
  }
  // App fermee (ou plantee) : on s'eteint tout seul au bout d'un silence.
  if (!enVeille && millis() - dernierMot > SILENCE_VEILLE) entrerVeille();

  if (enVeille) {                          // rien ne tourne, rien ne brille
    delay(50);
    return;
  }
  lireBouton();
  surveillerToucher();                     // doigt pose -> scan automatique
  animerLeds();
  delay(8);
}
