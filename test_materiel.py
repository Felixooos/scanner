#!/usr/bin/env python3
"""
test_materiel.py — vérifie le câblage du bouton et des LEDs.

    python3 test_materiel.py

1. fait défiler les couleurs de la LED RGB (tu vérifies qu'elles
   correspondent au nom annoncé) ;
2. suit le bouton en direct : appuie et relâche, l'écran l'affiche.
"""

import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("pyserial manquant : pip3 install pyserial")

BAUD = 921600


def trouver_port():
    for p in serial.tools.list_ports.comports():
        if any(m in p.device for m in ("usbserial", "SLAB", "wchusbserial")):
            return p.device
    return None


def lire(sp, secondes, prefixe="   "):
    """Affiche les messages de la carte pendant N secondes."""
    debut = time.time()
    vus = 0
    while time.time() - debut < secondes:
        ligne = sp.readline().decode("ascii", errors="ignore").strip()
        if not ligne:
            continue
        if ligne.startswith("#"):
            print(prefixe + ligne[1:].strip(), flush=True)
            vus += 1
        elif ligne.startswith("<BOUTON>"):
            print(prefixe + "🔘 APPUI reçu par le Mac !", flush=True)
            vus += 1
    return vus


def principal():
    port = trouver_port()
    if not port:
        sys.exit("Aucun ESP32 trouvé. Branche-le en USB.")
    print(f"Connexion à {port}…\n")
    with serial.Serial(port, BAUD, timeout=0.2) as sp:
        time.sleep(2.0)                 # laisse la carte redémarrer
        sp.reset_input_buffer()

        print("=== 1) TEST DES LEDS ===")
        print("Regarde la LED RGB : la couleur annoncée doit correspondre.\n")
        sp.write(b"TESTLED\n")
        lire(sp, 9)

        print("\n=== 2) TEST DU BOUTON ===")
        for n in (3, 2, 1):
            print(f"   Prépare-toi… {n}", flush=True)
            time.sleep(1)
        print("   >>> APPUIE ET RELÂCHE LE BOUTON plusieurs fois (8 s) <<<\n",
              flush=True)
        sp.reset_input_buffer()
        sp.write(b"DIAG\n")
        vus = lire(sp, 9)

        print()
        if vus <= 2:
            print("❌ Aucun changement détecté : le bouton n'est pas vu.")
            print("   Vérifie qu'il est bien entre GPIO 33 et GND.")
            print("   (Bouton 4 pattes : prends deux pattes en DIAGONALE.)")
        else:
            print("✅ Le bouton répond.")

        print("\n=== 3) SIGNAL BRUT DU FIL TCH ===")
        print("Vérifie que la broche réagit vraiment au doigt.\n")
        for n in (3, 2, 1):
            print(f"   Prépare-toi… {n}", flush=True)
            time.sleep(1)
        print("   >>> POSE ET RETIRE TON DOIGT plusieurs fois (20 s) <<<\n",
              flush=True)
        sp.reset_input_buffer()
        sp.write(b"DIAGTCH\n")
        lire(sp, 21)

        print("\n=== 4) TEST DU TOUCHER (chiffon vs doigt) ===")
        for n in (3, 2, 1):
            print(f"   Prépare-toi… {n}", flush=True)
            time.sleep(1)
        print("   >>> passe le CHIFFON, puis pose ton DOIGT (25 s) <<<\n",
              flush=True)
        sp.reset_input_buffer()
        valides = ignores = 0
        debut = time.time()
        while time.time() - debut < 25:
            ligne = sp.readline().decode("ascii", errors="ignore").strip()
            if ligne.startswith("<TOUCHE>"):
                valides += 1
                print("   ✅ EMPREINTE validée → le scan partirait", flush=True)
            elif "ignore" in ligne:
                ignores += 1
                print("   🧹 contact ignoré (pas une empreinte)", flush=True)

        print()
        print(f"   empreintes validées : {valides}   |   contacts ignorés : {ignores}")
        if valides and ignores:
            print("✅ Parfait : le doigt passe, le chiffon est filtré.")
        elif valides:
            print("✅ Le doigt est bien détecté.")
        elif ignores:
            print("⚠️  Rien n'a été validé : si ton doigt a été refusé,")
            print("   souffle dessus (doigt trop sec) et réessaie.")
        else:
            print("❌ Aucun contact détecté : vérifie TCH (GPIO 4) et VA (3V3).")


if __name__ == "__main__":
    try:
        principal()
    except KeyboardInterrupt:
        print("\nArrêté.")
