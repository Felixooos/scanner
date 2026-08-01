# Scanner d'empreinte JM-101 + ESP32 → image PNG

Capture l'image brute de ton empreinte depuis un module JM-101 et
l'enregistre en PNG sur le Mac.

## 🖐️ L'app Mac « Empreinte » (le plus simple)

Une petite application native macOS (SwiftUI) : une fenêtre, un gros bouton
**« Nouveau scan »**, et l'empreinte se construit en direct sous tes yeux.
Elle ne fait que du **scan live** et pilote exactement les mêmes scripts
Python que le terminal (rien de dupliqué).

**La construire** (une fois, ~5 s) :

```bash
cd ~/Desktop/empreintescanner/app_mac
./construire.sh
```

Ça crée `Empreinte.app` dans le dossier `empreintescanner`. **Double-clique
dessus** (ou `open ~/Desktop/empreintescanner/Empreinte.app`).

**L'utiliser** — c'est une app de **commandes** (pour graver les empreintes
des clients). L'app se connecte toute seule à l'ESP32 (pastille verte
« Capteur prêt » ; sinon choisis le port dans le menu).

1. **Créer une nouvelle commande** → donne-lui un nom (le client).
2. **Ajouter une empreinte** → saisis le prénom de la personne, puis scanne
   (bouton **Nouveau scan** ou barre d'espace ; l'empreinte se construit en
   direct). **Valider** l'enregistre dans la commande. Répète pour chaque
   personne (jusqu'à 4).
3. **Choisis la forme** (selon le nombre d'empreintes) et le **style**, puis
   **Composer & enregistrer** : le SVG final part dans le dossier
   `commandes/`.

**Formes** : `simple` (ovales côte à côte), `cœur` (2 empreintes, une par
moitié, fin espace au milieu), `trèfle` (3 ou 4 feuilles ; chaque empreinte
est tournée de 120° / 90° pour rayonner). Un fin espace sépare toujours les
lobes.

**Styles** (tous exportés en SVG vectoriel, prêt à graver) :
- **Gabor plein** — crêtes pleines épaisses, lissées (vectorisées) ;
- **Traits fins** — traits fins qui ne se touchent pas ;
- **Traits soudés** — traits fins dont les bifurcations se rejoignent.

> Au premier lancement macOS peut demander l'accès au dossier Bureau
> (l'app y lit les scripts et y écrit les photos) : accepte.
> Le code Swift est dans `app_mac/Empreinte/`, relance `construire.sh`
> après chaque modif.

## Branchements (JM-101 version 8 fils → ESP32 DevKit)

Brochage officiel du manuel JM-101 (v1.8). La broche 1 est repérée sur le
connecteur du module (pastille carrée ou petit triangle ; le fil rouge de la
nappe est en général sur la broche 1).

| Broche | Étiquette sur le module | Rôle | → Broche ESP32 |
|---|---|---|---|
| 1 | V+ | Alimentation du module (3,3 V) | **3V3** |
| 2 | TX | Sortie série du capteur | **GPIO 16** (marquée RX2) |
| 3 | RX | Entrée série du capteur | **GPIO 17** (marquée TX2) |
| 4 | GND | Masse | **GND** |
| 5 | TCH | Détection du doigt (niveau haut = doigt posé) | **GPIO 4** (conseillé : scan instantané) |
| 6 | VA | Alimentation du circuit tactile | **3V3** (obligatoire si TCH est branché) |
| 7 | D+ | USB D+ | **non branché** |
| 8 | D- | USB D- | **non branché** |

Seuls **4 fils sont indispensables** : 1 (3,3 V), 2 (TX), 3 (RX), 4 (GND).
Les broches 7 et 8 servent uniquement à brancher le module directement en
USB sur un PC avec le logiciel du fabricant — inutile ici, laisse-les en l'air.

⚠️ **Important**
- Alimente le module en **3,3 V uniquement** (3,0–3,6 V d'après le manuel) :
  broche 3V3 de l'ESP32, **jamais VIN/5V**.
- TX et RX se **croisent** : broche 2 (TX du capteur) → RX2 de l'ESP32
  (GPIO 16), broche 3 (RX du capteur) → TX2 (GPIO 17).
- Les couleurs de la nappe varient selon les lots : compte les broches à
  partir de la broche 1, ne te fie pas aux couleurs.

## Mise en route

1. **Téléverser le sketch** : ouvre `empreinte_scanner/empreinte_scanner.ino`
   dans l'Arduino IDE, carte « **ESP32 Dev Module** », choisis le port USB,
   puis Téléverser. (Si les cartes ESP32 ne sont pas installées : Outils →
   Type de carte → Gestionnaire de cartes → cherche « esp32 » par Espressif.)
2. **Fermer le moniteur série** de l'IDE (un seul programme peut utiliser le
   port à la fois).
3. **Lancer le script** dans le Terminal :
   ```bash
   pip3 install pyserial        # une seule fois
   cd ~/Desktop/empreintescanner
   python3 capture_empreinte.py
   ```
4. **Tape `go`** (ou juste Entrée) dans le Terminal : compte à rebours de
   3 secondes pour poser ton doigt, puis le scan part (le capteur cherche le
   doigt pendant 10 s maxi). Le script capture, améliore, **ouvre à
   l'écran le montage** `comparaison_*.png` (originale → améliorée →
   crêtes Gabor) — **seul fichier conservé**, les intermédiaires sont
   supprimés — puis attend ton prochain `go`. Tape `q` pour quitter.
   Toutes les images sont rangées dans le sous-dossier **`photos/`**.
5. **Tape `live`** (le mode recommandé) : une **fenêtre s'ouvre** et
   l'empreinte se construit dedans, en direct, à chaque pose du doigt.
   Commandes au clavier (fenêtre au premier plan) :
   - **ESPACE** : compte à rebours 3 s puis scan — la pose se raccorde et
     l'image se met à jour ;
   - **F** : terminer -> rendu final aux filtres de Gabor
     (`empreinte_fusion_*.png`), ouvert à l'écran ;
   - **R** : tout recommencer ;  **Q** : quitter sans enregistrer.
   Pose le doigt un peu décalé ou penché à chaque fois pour agrandir la
   zone couverte.
6. **Tape `fusion`** pour la variante guidée en 4 poses fixes (gauche, à
   plat, droite, appuyé) assemblées d'un coup.

## Grande empreinte : les modes live et fusion (mosaïquage)

La fenêtre utile du capteur ne fait que 13 × 14,6 mm : un seul scan ne voit
qu'une partie du doigt. Les modes `live` et `fusion` reproduisent la
technique des « empreintes roulées ». Pour chaque scan :

1. la capture est améliorée (contraste, CLAHE, reconnexion des crêtes) ;
2. la zone de doigt réelle est détectée (masque de contraste local) ;
3. elle est positionnée dans la mosaïque en cours : points SIFT + RANSAC,
   sinon template matching multi-angle (-12° à +12°) sur cartes signées ;
4. l'alignement est affiné au dixième de degré près (findTransformECC) et
   un raccord n'est accepté que si les crêtes corrèlent vraiment avec la
   mosaïque à cet endroit ;
5. fondu progressif aux raccords (feathering par carte de distance), et à
   la fin rendu aux filtres de Gabor : les belles lignes continues.

En mode `live`, chaque nouvelle pose n'a besoin de recouvrir que la zone
déjà scannée : on peut explorer tout le doigt de proche en proche, l'aperçu
se met à jour à chaque raccord.

Conseils : décale ou penche le doigt **progressivement** (bon recouvrement
avec ce qui est déjà posé), ne le tourne pas de plus de ~10°, appuie fort.
Fusion possible aussi à la main : `python3 fusionner_empreinte.py a.png b.png ...`

## Complétion des trous

Les zones sans données (doigt sec, pose légère, centre trop encré) sont
**complétées automatiquement** (`completer_empreinte.py`) : le champ
d'orientation des crêtes est calculé sur les vraies données, diffusé dans
les trous, puis les crêtes « poussent » à travers par filtrage de Gabor
itératif — elles restent ancrées sur les données réelles et se prolongent
de façon plausible dans les manques. Le contour du doigt n'est pas
gonflé : seuls les trous internes sont comblés. C'est cette version
complétée qui alimente le montage et le SVG.

Le rendu final (mode live « Terminer » / fusion) donne une **forme d'ovale
« façon œuf »** : une ellipse est ajustée sur la pulpe du doigt, les crêtes
sont poussées jusqu'à son bord puis découpées net, et le tracé SVG s'arrête
proprement sur ce bord. Réglage `RATIO_OVALE` en tête de
`completer_empreinte.py` (plus petit = ovale plus rond, rogne davantage la
base du doigt).

À la main : `python3 completer_empreinte.py image_amelioree.png [--ovale]`

## Vitesse

Il y a **deux liaisons série distinctes**, chacune sa vitesse :

- **capteur ↔ ESP32** : fixé à **57600 bauds**. C'est la seule vitesse
  stable du JM-101 : à 115200 il se bloquait après 1-2 scans (il ne
  conserve pas le réglage et repart à 57600 à chaque mise sous tension).
  Un scan complet prend ~7 s.
- **ESP32 ↔ Mac (USB)** : **921600 bauds** avec la carte à puce **CP2102**
  (transfert de l'image en <1 s). Avec une vieille carte **CH340**, reste à
  115200 : au-delà elle corrompt les données sur macOS.

`BAUD` du script Python (et de `moteur_live.py`) doit correspondre à
`BAUD_USB` du sketch ; `BAUD_CAPTEUR` reste à 57600.

## Dessin vectoriel : le tracé SVG

Chaque scan et chaque fusion produit aussi un **SVG** (`*_traits.svg`) :
un dessin aux traits continus et lisses qui suivent les crêtes, comme un
relevé tracé à la main — aucun trait n'en touche un autre.

Comment c'est fait (`tracer_svg.py`) : squelette des crêtes Gabor (1 px),
découpe aux carrefours, recousage des traits dans le prolongement l'un de
l'autre (les coupures et carrefours sont traversés tout droit, les
bifurcations restent des traits séparés), suppression des **demi-tours**
(épingles serrées **et** gouttes/spirales qui reviennent se coller à
elles-mêmes — jamais de virage à 180°), lissage, léger **prolongement**
de chaque bout dans le vide (sans jamais s'approcher d'un autre trait :
écart mini garanti), export en courbes de Bézier. Réglages en tête du
fichier (épaisseur du trait, distance de recousage, écart mini...).

À la main : `python3 tracer_svg.py photos/xxx_cretes.png [sortie.svg]`

## Comment ça marche

- Le JM-101 parle le protocole ZhianTec (identique aux R307/AS608/R503) à
  57 600 bauds. Le sketch envoie la commande `GenImg` (prendre l'image) puis
  `UpImage` (transférer l'image, 36 864 octets, 2 pixels par octet).
- L'ESP32 renvoie l'image en hexadécimal sur l'USB entre les marqueurs
  `<IMG_START>` / `<IMG_END>`.
- `capture_empreinte.py` décode le flux et écrit le PNG (niveaux de gris,
  aucune bibliothèque d'image nécessaire).

## Améliorer les résultats

### Au moment de la capture (le plus important !)

1. **Appuie fermement et bien à plat** : pose la pulpe du doigt (pas le bout),
   couvre toute la fenêtre du capteur, et maintiens la pression sans bouger.
2. **Doigt trop sec = crêtes en pointillés** : souffle sur ton doigt ou
   passe-le sur ton front avant de le poser (un léger film gras améliore
   énormément le contact optique).
3. **Nettoie la fenêtre** du capteur avec un chiffon microfibre.
4. **Fais plusieurs captures** et garde la meilleure : le script
   d'amélioration affiche pour chacune une note de couverture et de netteté.

### Après la capture (automatique)

L'amélioration se lance toute seule à chaque capture (il faut juste avoir
installé les outils une fois) :

```bash
pip3 install numpy opencv-python scipy scikit-image fingerprint-enhancer
```

Pour retraiter des captures existantes à la main :

```bash
python3 ameliorer_empreinte.py
```

Pour chaque `empreinte_*.png` le script produit :
- `*_amelioree.png` — contraste étiré, agrandie 2x, égalisation adaptative
  (CLAHE), fermeture morphologique (ressoude les pointillés), débruitage ;
- `*_cretes.png` — crêtes reconstruites en traits continus par filtres de
  Gabor orientés (méthode Hong-Wan-Jain, la référence académique) ;
- `comparaison_*.png` — montage avant/après pour juger d'un coup d'œil.

Il affiche aussi la **couverture** (% de la fenêtre couverte par le doigt)
et la **netteté** de chaque capture : vise > 15 % de couverture et la
netteté la plus haute possible.

## Dépannage

- « Capteur introuvable » au démarrage → TX/RX inversés (échange GPIO 16 et
  17) ou capteur mal alimenté.
- Rien ne s'affiche → vérifie que le moniteur série de l'IDE est fermé et
  que le script écoute le bon port (`python3 capture_empreinte.py --port /dev/cu.xxxx`).
- Image très pâle ou taille inattendue → certains clones envoient l'image en
  8 bits/pixel ou en 192×192 : le script gère ces cas automatiquement.
