#!/usr/bin/env python3
"""
test_toucher.py — vérifie la détection du doigt (fils TCH et VA).

    python3 test_toucher.py

Deux étapes :
  1. signal BRUT de la broche TCH (le câblage répond-il ?) ;
  2. déclenchement réel (doigt accepté / chiffon rejeté).

⚠️ Ferme l'app Empreinte avant de lancer : un seul programme à la fois
   peut lire le port série.
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


def lire(sp, secondes):
    """Affiche les messages de la carte, sans planter sur un hoquet USB."""
    debut = time.time()
    lignes = []
    while time.time() - debut < secondes:
        try:
            brut = sp.readline()
        except serial.SerialException:
            time.sleep(0.2)          # hoquet USB : on continue
            continue
        ligne = brut.decode("ascii", errors="ignore").strip()
        if not ligne:
            continue
        lignes.append(ligne)
        if ligne.startswith("<TOUCHE>"):
            print("   ✅ EMPREINTE VALIDÉE → le scan partirait", flush=True)
        elif ligne.startswith("#"):
            print("   " + ligne[1:].strip(), flush=True)
    return lignes


def principal():
    port = trouver_port()
    if not port:
        sys.exit("Aucun ESP32 trouvé. Branche-le en USB.")
    print(f"Connexion à {port}…\n")
    with serial.Serial(port, BAUD, timeout=0.3) as sp:
        time.sleep(2.0)
        sp.reset_input_buffer()

        # --- 1) signal brut -------------------------------------------------
        print("=== 1) SIGNAL BRUT DU FIL TCH ===")
        for n in (3, 2, 1):
            print(f"   Prépare-toi… {n}", flush=True)
            time.sleep(1)
        print("\n   >>> POSE ET RETIRE TON DOIGT plusieurs fois (20 s) <<<\n",
              flush=True)
        sp.reset_input_buffer()
        sp.write(b"DIAGTCH\n")
        lignes = lire(sp, 22)

        haut = any("DOIGT (haut)" in l for l in lignes)
        bas = any("rien (bas)" in l for l in lignes)
        pourcent = next((l for l in lignes if "% du temps" in l), "")

        print("\n   --- verdict câblage ---")
        if haut and bas:
            print("   ✅ Le fil TCH répond au doigt : câblage OK.")
        elif haut and not bas:
            print("   ⚠️  TCH reste TOUJOURS haut, même sans doigt.")
            print("      -> le fil TCH touche du 3V3 quelque part.")
        else:
            print("   ❌ TCH ne bouge jamais (toujours bas).")
            print("      -> vérifie VA (fil 6) sur 3V3 : c'est lui qui")
            print("         alimente le circuit tactile. Et TCH (fil 5)")
            print("         sur GPIO 4. Compte depuis la broche 1 !")
        if pourcent:
            print("   " + pourcent.lstrip("# "))

        if not haut:
            print("\n   (test 2 sauté : le câblage doit d'abord répondre)")
            return

        # --- 2) déclenchement réel ------------------------------------------
        print("\n=== 2) DÉCLENCHEMENT RÉEL ===")
        for n in (3, 2, 1):
            print(f"   Prépare-toi… {n}", flush=True)
            time.sleep(1)
        print("\n   >>> pose ton DOIGT (3-4 fois), puis un coup de CHIFFON (30 s) <<<\n",
              flush=True)
        sp.reset_input_buffer()
        lignes = lire(sp, 30)

        valides = sum(1 for l in lignes if l.startswith("<TOUCHE>"))
        ignores = sum(1 for l in lignes if "ignore" in l)
        print(f"\n   empreintes validées : {valides}   |   contacts ignorés : {ignores}")
        if valides and not ignores:
            print("   ✅ Parfait.")
        elif valides and ignores:
            print("   ✅ Le doigt passe et le chiffon est filtré.")
        elif ignores and not valides:
            print("   ⚠️  Tout est rejeté, même le doigt : je vais assouplir")
            print("      la validation (dis-moi les codes affichés ci-dessus).")
        else:
            print("   ⚠️  Aucun déclenchement : le contact ne dure pas 1 s,")
            print("      ou le doigt ne couvre pas assez la zone tactile.")


if __name__ == "__main__":
    try:
        principal()
    except KeyboardInterrupt:
        print("\nArrêté.")
