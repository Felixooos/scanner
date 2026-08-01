#!/usr/bin/env python3
"""
capture_empreinte.py — reçoit l'image d'empreinte envoyée par l'ESP32
(sketch empreinte_scanner.ino) et l'enregistre en PNG.

Utilisation :
    pip3 install pyserial          (une seule fois)
    python3 capture_empreinte.py               # détecte le port tout seul
    python3 capture_empreinte.py --port /dev/cu.usbserial-0001

Commandes dans le terminal :
    go / Entrée : un scan -> montage comparaison ouvert à l'écran
    fusion      : 4 scans en roulant le doigt, assemblés en une seule
                  grande empreinte (mosaïquage)
    q           : quitter
"""

import argparse
import datetime
import math
import os
import struct
import subprocess
import sys
import time
import zlib

# pour pouvoir importer ameliorer_empreinte.py / fusionner_empreinte.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("Le module pyserial n'est pas installé. Lance :  pip3 install pyserial")

BAUD = 921600      # doit correspondre à BAUD_USB dans le sketch ESP32

# Le capteur est monté à l'envers dans le boîtier : on redresse l'image dès
# la réception, comme ça tous les modes (live, fusion, rendu) sont d'accord.
ROTATION_180 = True

# toutes les images finissent dans le sous-dossier photos/ — sauf quand le
# moteur tourne embarqué dans l'app : écrire dans le bundle casserait sa
# signature, on range alors les photos dans la bibliothèque de l'utilisateur.
_ICI = os.path.dirname(os.path.abspath(__file__))
if ".app/Contents/" in _ICI:
    DOSSIER_PHOTOS = os.path.expanduser(
        "~/Library/Application Support/EmpreinteMMD/photos")
else:
    DOSSIER_PHOTOS = os.path.join(_ICI, "photos")
os.makedirs(DOSSIER_PHOTOS, exist_ok=True)


def trouver_port():
    """Cherche un port série USB typique (CP2102 / CH340 de l'ESP32)."""
    for p in serial.tools.list_ports.comports():
        d = p.device
        if any(m in d for m in ("usbserial", "SLAB", "wchusbserial", "usbmodem")):
            return d
    return None


def ecrire_png(chemin, largeur, hauteur, pixels):
    """Écrit un PNG niveaux de gris 8 bits, sans aucune dépendance externe."""

    def bloc(nom, donnees):
        return (struct.pack(">I", len(donnees)) + nom + donnees
                + struct.pack(">I", zlib.crc32(nom + donnees) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", largeur, hauteur, 8, 0, 0, 0, 0)
    brut = b"".join(b"\x00" + bytes(pixels[y * largeur:(y + 1) * largeur])
                    for y in range(hauteur))
    with open(chemin, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(bloc(b"IHDR", ihdr))
        f.write(bloc(b"IDAT", zlib.compress(brut, 9)))
        f.write(bloc(b"IEND", b""))


def deduire_dimensions(nb_octets):
    """Déduit (largeur, hauteur, 4 bits par pixel ?) du nombre d'octets reçus."""
    connues = {
        36864: (256, 288, True),    # standard JM-101 / R307 / AS608 (4 bpp)
        18432: (192, 192, True),    # R503 et variantes capacitives
        12800: (160, 160, True),
        73728: (256, 288, False),   # variante 8 bits par pixel
    }
    if nb_octets in connues:
        return connues[nb_octets]
    cote = int(math.isqrt(nb_octets * 2))
    if cote * cote == nb_octets * 2:
        return (cote, cote, True)
    return None


def decoder_hex(donnees_hex):
    """Flux hexadécimal -> (pixels, largeur, hauteur), ou None si invalide."""
    try:
        donnees = bytes.fromhex(donnees_hex)
    except ValueError:
        print("!! Données corrompues, scan à refaire.")
        return None
    dims = deduire_dimensions(len(donnees))
    if dims is None:
        print(f"!! Taille inattendue ({len(donnees)} octets), image ignorée.")
        return None
    largeur, hauteur, quatre_bits = dims
    if quatre_bits:
        # chaque octet contient 2 pixels : quartet haut puis quartet bas
        pixels = bytearray()
        for o in donnees:
            pixels.append(o & 0xF0)
            pixels.append((o & 0x0F) << 4)
    else:
        pixels = bytearray(donnees)
    if ROTATION_180:
        # inverser l'ordre des pixels = rotation exacte de 180°
        # (le pixel (x, y) se retrouve en (largeur-1-x, hauteur-1-y))
        pixels = pixels[::-1]
    return pixels, largeur, hauteur


def lancer_scan(sp):
    """Envoie l'ordre SCAN et attend l'image. Retourne (pixels, l, h) ou None."""
    sp.reset_input_buffer()
    sp.write(b"SCAN\n")
    en_cours = False
    tampon = []
    debut = time.time()
    while time.time() - debut < 60:
        ligne = sp.readline().decode("ascii", errors="ignore").strip()
        if not ligne:
            continue
        if ligne.startswith("<IMG_START"):
            en_cours = True
            tampon = []
            print("Réception de l'image...")
        elif ligne.startswith("<IMG_END"):
            return decoder_hex("".join(tampon))
        elif ligne.startswith("<SCAN_FAIL"):
            print("Scan raté (pas de doigt détecté ?).")
            return None
        elif en_cours:
            tampon.append(ligne)
        elif ligne.startswith("#"):
            print(ligne[1:].strip())          # messages d'état de l'ESP32
    print("Pas de réponse de l'ESP32 (délai dépassé). Vérifie le branchement.")
    return None


def compte_a_rebours(consigne):
    for n in (3, 2, 1):
        print(f"   {consigne} — scan dans {n}...")
        time.sleep(1)


def traitement_automatique(chemin_png):
    """Améliore la capture et ouvre le montage avant/après à l'écran."""
    try:
        import ameliorer_empreinte
    except ImportError:
        print("   (amélioration sautée : lance d'abord "
              "pip3 install numpy opencv-python scipy fingerprint-enhancer)")
        return
    print("Amélioration en cours (quelques secondes)...")
    try:
        comparaison = ameliorer_empreinte.traiter(chemin_png)
    except Exception as erreur:
        print(f"   (amélioration impossible : {erreur})")
        return
    if comparaison:
        # ne garde que le montage : supprime la brute et les intermédiaires
        nom = os.path.splitext(chemin_png)[0]
        for fichier in (chemin_png, f"{nom}_amelioree.png", f"{nom}_cretes.png"):
            if os.path.exists(fichier):
                os.remove(fichier)
        subprocess.run(["open", comparaison], check=False)
        print(f"** Comparaison ouverte : {os.path.abspath(comparaison)}")


def scan_simple(sp):
    compte_a_rebours("pose ton doigt")
    resultat = lancer_scan(sp)
    if resultat is None:
        return
    pixels, largeur, hauteur = resultat
    horodatage = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    chemin = os.path.join(DOSSIER_PHOTOS, f"empreinte_{horodatage}.png")
    ecrire_png(chemin, largeur, hauteur, pixels)
    print(f"** Image reçue ({largeur}x{hauteur})")
    traitement_automatique(chemin)


def sans_accents(texte):
    """Les polices OpenCV ne connaissent pas les accents."""
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFD", texte)
                   if unicodedata.category(c) != "Mn")


def scan_live(sp):
    """Fenêtre en direct : l'empreinte se construit sous tes yeux à chaque
    pose du doigt. ESPACE = scanner, F = terminer, R = recommencer, Q = quitter."""
    try:
        import cv2
        import numpy as np
        import fusionner_empreinte
    except ImportError as erreur:
        print(f"Mode live impossible ({erreur}). Lance d'abord :\n"
              "    pip3 install numpy opencv-python scipy fingerprint-enhancer")
        return
    import threading

    contexte = {"session": fusionner_empreinte.SessionFusion()}
    etat = {"message": "ESPACE : scanner ta premiere pose",
            "sous": "ESPACE = scanner   F = terminer   R = recommencer   Q = quitter"}
    FENETRE = "Empreinte en direct"
    cv2.namedWindow(FENETRE, cv2.WINDOW_AUTOSIZE)

    def composer():
        session = contexte["session"]
        if session.nb_posees:
            apercu = fusionner_empreinte.normaliser_affichage(
                session._recadrer(session.image_actuelle()))
        else:
            apercu = np.full((420, 620), 245, np.uint8)
            cv2.putText(apercu, "(aucune pose pour l'instant)", (150, 215),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, 150, 1, cv2.LINE_AA)
        echelle = min(620.0 / apercu.shape[0], 940.0 / apercu.shape[1], 1.0)
        if echelle < 1.0:
            apercu = cv2.resize(apercu, None, fx=echelle, fy=echelle,
                                interpolation=cv2.INTER_AREA)
        largeur = max(apercu.shape[1], 640)
        bandeau = np.full((92, largeur), 30, np.uint8)
        cv2.putText(bandeau, sans_accents(etat["message"]), (12, 38),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, 255, 2, cv2.LINE_AA)
        cv2.putText(bandeau, sans_accents(etat["sous"]), (12, 74),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, 190, 1, cv2.LINE_AA)
        if apercu.shape[1] < largeur:
            fond = np.full((apercu.shape[0], largeur), 245, np.uint8)
            x0 = (largeur - apercu.shape[1]) // 2
            fond[:, x0:x0 + apercu.shape[1]] = apercu
            apercu = fond
        return np.vstack([bandeau, apercu])

    def afficher(image=None):
        cv2.imshow(FENETRE, composer() if image is None else image)

    def travailler(fonction):
        """Exécute une tâche longue dans un fil en gardant la fenêtre vivante."""
        fige = composer()
        boite = {}
        fil = threading.Thread(target=lambda: boite.setdefault("r", fonction()))
        fil.start()
        while fil.is_alive():
            afficher(fige)
            cv2.waitKey(50)
        return boite.get("r")

    afficher()
    chemin_final = None
    while True:
        if cv2.getWindowProperty(FENETRE, cv2.WND_PROP_VISIBLE) < 1:
            break
        touche = cv2.waitKey(30) & 0xFF
        session = contexte["session"]

        if touche in (ord('q'), 27):                      # Q ou Echap
            break

        elif touche == ord('r'):
            contexte["session"] = fusionner_empreinte.SessionFusion()
            etat["message"] = "On repart de zero - ESPACE pour scanner"
            afficher()

        elif touche in (32, 13):                          # ESPACE ou Entree
            for n in (3, 2, 1):
                etat["message"] = f"Pose ton doigt... scan dans {n}"
                afficher()
                cv2.waitKey(1000)
            etat["message"] = "SCAN EN COURS - garde le doigt appuye"
            resultat = travailler(lambda: lancer_scan(sp))
            if resultat is None:
                etat["message"] = "Scan rate - ESPACE pour reessayer"
            else:
                pixels, largeur, hauteur = resultat
                brute = np.frombuffer(bytes(pixels), np.uint8).reshape(hauteur, largeur)
                etat["message"] = "Raccordement..."
                try:
                    raccordee = travailler(lambda: contexte["session"].ajouter(brute))
                except Exception as erreur:
                    print(f"   (erreur pendant le raccord : {erreur})")
                    raccordee = False
                if raccordee:
                    etat["message"] = (f"Raccordee ! {contexte['session'].nb_posees} pose(s)"
                                       " - decale un peu le doigt puis ESPACE")
                else:
                    # garde la capture ratée pour pouvoir diagnostiquer
                    horodatage = datetime.datetime.now().strftime("%H%M%S")
                    chemin_rate = os.path.join(DOSSIER_PHOTOS, f"rate_{horodatage}.png")
                    ecrire_png(chemin_rate, largeur, hauteur, pixels)
                    print(f"   (capture non raccordée gardée : {chemin_rate})")
                    etat["message"] = ("Pas raccordee - repose le doigt en recouvrant"
                                       " la zone deja scannee")
            afficher()

        elif touche == ord('f'):
            if session.nb_posees == 0:
                etat["message"] = "Aucune pose a enregistrer !"
                afficher()
                continue
            etat["message"] = "Rendu final (filtres de Gabor)... environ 1 min"
            afficher()
            try:
                chemin_final = travailler(
                    lambda: fusionner_empreinte.finaliser_et_enregistrer(contexte["session"]))
            except Exception as erreur:
                print(f"Le rendu final a plante : {erreur}")
            break

    cv2.destroyAllWindows()
    cv2.waitKey(1)
    if chemin_final:
        subprocess.run(["open", chemin_final], check=False)
        print(f"** Empreinte finale ouverte : {os.path.abspath(chemin_final)}")


POSITIONS_FUSION = [
    "penche le doigt vers la GAUCHE",
    "pose le doigt bien à PLAT au centre",
    "penche le doigt vers la DROITE",
    "bien à PLAT, appuie FORT",
]


def scan_fusion(sp):
    try:
        import numpy as np
        import fusionner_empreinte
    except ImportError as erreur:
        print(f"Fusion impossible ({erreur}). Lance d'abord :\n"
              "    pip3 install numpy opencv-python scipy fingerprint-enhancer")
        return

    captures = []
    for position in POSITIONS_FUSION:
        for essai in (1, 2):
            compte_a_rebours(position)
            resultat = lancer_scan(sp)
            if resultat is not None:
                pixels, largeur, hauteur = resultat
                captures.append(np.frombuffer(bytes(pixels), np.uint8)
                                .reshape(hauteur, largeur))
                print(f"   Capture {len(captures)} OK.")
                break
            if essai == 1:
                print("   On retente cette position.")
        else:
            print("   Position abandonnée, on passe à la suivante.")

    if len(captures) < 2:
        print("Pas assez de captures réussies pour fusionner.")
        return

    print(f"Fusion de {len(captures)} captures en cours (~30 s)...")
    try:
        chemin = fusionner_empreinte.fusionner_et_enregistrer(captures)
    except Exception as erreur:
        print(f"La fusion a planté : {erreur}")
        return
    if chemin:
        subprocess.run(["open", chemin], check=False)
        print(f"** Empreinte fusionnée ouverte : {os.path.abspath(chemin)}")
    else:
        print("Fusion impossible : pas assez de recouvrement entre les scans.\n"
              "Refais un essai en roulant le doigt moins fort entre chaque position.")


def principal():
    ana = argparse.ArgumentParser(description="Enregistre les empreintes en PNG")
    ana.add_argument("--port", help="port série (ex. /dev/cu.usbserial-0001)")
    args = ana.parse_args()

    port = args.port or trouver_port()
    if not port:
        sys.exit("Aucun port USB trouvé. Branche l'ESP32 ou précise --port ...")

    print(f"Connexion à {port} ({BAUD} bauds)...")
    with serial.Serial(port, BAUD, timeout=1) as sp:
        # laisse l'ESP32 redémarrer et affiche ses messages de démarrage
        debut = time.time()
        while time.time() - debut < 3:
            ligne = sp.readline().decode("ascii", errors="ignore").strip()
            if ligne.startswith("#"):
                print(ligne[1:].strip())

        while True:
            reponse = input("\nTape go (scan), live (empreinte progressive), "
                            "fusion (4 scans guidés) ou q (quitter) : ").strip().lower()
            if reponse == "q":
                break
            if reponse in ("go", ""):
                scan_simple(sp)
            elif reponse == "live":
                scan_live(sp)
            elif reponse == "fusion":
                scan_fusion(sp)
            else:
                print("Commandes : go (ou Entrée), live, fusion, q")


if __name__ == "__main__":
    try:
        principal()
    except KeyboardInterrupt:
        print("\nAu revoir !")
