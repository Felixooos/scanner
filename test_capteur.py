#!/usr/bin/env python3
"""
test_capteur.py — teste la liaison ESP32 <-> capteur en continu.

Lance-le, puis remue doucement chaque fil UN PAR UN (V+, TX, RX, GND,
le connecteur du capteur, le câble USB) en regardant l'écran :
quand le statut change, tu as trouvé le fil fautif.

    python3 test_capteur.py          (Ctrl+C pour arrêter)

Le test redémarre la carte toutes les ~3 secondes : à chaque démarrage,
elle annonce si elle voit le capteur.
"""

import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("pyserial manquant : pip3 install pyserial")


def trouver_port():
    for p in serial.tools.list_ports.comports():
        if any(m in p.device for m in ("usbserial", "SLAB", "wchusbserial", "usbmodem")):
            return p.device
    return None


def principal():
    print("Test du capteur en continu — Ctrl+C pour arrêter.")
    print("Remue doucement chaque fil un par un et regarde le statut :\n")
    ok_suite = rate_suite = 0
    while True:
        port = trouver_port()
        horodatage = time.strftime("%H:%M:%S")
        if not port:
            print(f"[{horodatage}]  !! USB DEBRANCHE — la carte n'est plus vue par le Mac")
            time.sleep(1.5)
            continue
        try:
            statut = None
            for baud in (921600, 115200):       # essaie les deux vitesses
                with serial.Serial(port, baud, timeout=0.4) as sp:
                    sp.dtr = False
                    sp.rts = True
                    time.sleep(0.1)
                    sp.rts = False              # redémarre la carte
                    debut = time.time()
                    while time.time() - debut < 3:
                        ligne = sp.readline().decode("ascii", errors="ignore")
                        if "Capteur detecte" in ligne:
                            statut = True
                            break
                        if "Capteur introuvable" in ligne:
                            statut = False
                            break
                if statut is not None:
                    break
            if statut is True:
                ok_suite += 1
                rate_suite = 0
                print(f"[{horodatage}]  CAPTEUR OK        ({ok_suite} de suite, {baud} bauds)")
            elif statut is False:
                rate_suite += 1
                ok_suite = 0
                print(f"[{horodatage}]  !! CAPTEUR MUET   ({rate_suite} de suite)")
            else:
                print(f"[{horodatage}]  ?? carte silencieuse (redémarrage raté)")
        except serial.SerialException as erreur:
            print(f"[{horodatage}]  !! PORT PERDU : {erreur}")
            time.sleep(1.5)


if __name__ == "__main__":
    try:
        principal()
    except KeyboardInterrupt:
        print("\nFin du test.")
