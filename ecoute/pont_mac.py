#!/usr/bin/env python3
"""
pont_mac.py — le pont qui tourne sur le Mac TOUJOURS ALLUMÉ de la chambre.

Il se connecte *vers* le relais du VPS (connexion sortante : aucune box à
configurer) et attend. Quand quelqu'un écoute, le relais envoie "START" ;
le pont demande alors le son au boîtier (ESP32, commande ECOUTE sur l'USB),
lit le flux PCM et le recopie vers le relais. "STOP" => il éteint le micro.

    ECOUTE_RELAIS_URL    wss://mon-vps/source      (l'adresse du relais)
    ECOUTE_JETON_SOURCE  le même jeton que le relais

    python3 pont_mac.py            # micro réel (ESP32 sur l'USB)
    python3 pont_mac.py --faux     # son de test (sinus) : vérifie le réseau
                                    # sans toucher au boîtier

Le micro ne s'allume QUE pendant une écoute : au repos, le boîtier ne diffuse
rien. Et comme le pont n'ouvre le port série que le temps d'une écoute, il ne
gêne pas l'app d'empreintes (de toute façon on ne scanne pas en écoutant).
"""

import asyncio
import math
import os
import struct
import sys
import time

import aiohttp

RELAIS = os.environ.get("ECOUTE_RELAIS_URL", "ws://127.0.0.1:8787/source")
JETON = os.environ.get("ECOUTE_JETON_SOURCE", "")
FREQ = 16000                      # Hz, mono, 16 bits
BLOC = 320                        # échantillons par envoi = 20 ms
FAUX = "--faux" in sys.argv

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    serial = None


def trouver_port():
    if serial is None:
        return None
    for p in serial.tools.list_ports.comports():
        if any(m in p.device for m in ("usbserial", "SLAB", "wchusbserial", "usbmodem")):
            return p.device
    return None


# --- source « faux son » : un sinus doux, pour tester le réseau -----------
async def flux_faux(envoyer, actif):
    """Génère un sinus 440 Hz tant que `actif` est vrai."""
    phase = 0.0
    pas = 2 * math.pi * 440 / FREQ
    prochain = time.monotonic()
    while actif():
        ech = bytearray()
        for _ in range(BLOC):
            ech += struct.pack("<h", int(6000 * math.sin(phase)))
            phase += pas
        await envoyer(bytes(ech))
        prochain += BLOC / FREQ
        await asyncio.sleep(max(0, prochain - time.monotonic()))


# --- source réelle : l'ESP32 par l'USB ------------------------------------
async def flux_esp32(envoyer, actif):
    """Ouvre le port, demande ECOUTE, recopie le son de l'ESP32.

    L'ESP32 envoie une ligne par bloc de 16 ms : '@' + base64 de 256
    échantillons PCM 16 bits. On décode et on transmet le PCM brut au relais.
    On lui renvoie un PING toutes les 5 s, sinon il coupe au bout de 15 s."""
    import base64
    port = trouver_port()
    if port is None:
        print("pont: aucun ESP32 trouvé (USB).", flush=True)
        return
    try:
        sp = serial.Serial(port, 921600, timeout=0.2)
    except Exception as e:
        print(f"pont: port occupé ou inaccessible ({e}).", flush=True)
        return
    try:
        sp.reset_input_buffer()
        sp.write(b"ECOUTE\n")
        boucle = asyncio.get_event_loop()
        tampon = bytearray()
        dernier_ping = time.monotonic()
        while actif():
            if time.monotonic() - dernier_ping > 5:
                sp.write(b"PING\n")               # garde l'écoute vivante
                dernier_ping = time.monotonic()
            data = await boucle.run_in_executor(None, sp.read, 2048)
            if data:
                tampon += data
            while True:
                fl = tampon.find(b"\n")
                if fl < 0:
                    break
                ligne = tampon[:fl]
                del tampon[:fl + 1]
                if ligne[:1] == b"@":
                    try:
                        await envoyer(base64.b64decode(ligne[1:]))
                    except Exception:
                        pass                      # ligne tronquée : on saute
    finally:
        try:
            sp.write(b"STOP\n")
            sp.flush()
            sp.close()
        except Exception:
            pass


async def une_session(session):
    async with session.ws_connect(RELAIS, heartbeat=20, max_msg_size=0) as ws:
        await ws.send_str(JETON)
        print("pont: relié au relais, en attente d'un auditeur…", flush=True)

        diffuser = {"on": False}
        tache = {"t": None}

        async def envoyer(octets):
            if not ws.closed:
                await ws.send_bytes(octets)

        async def demarrer():
            if tache["t"] and not tache["t"].done():
                return
            diffuser["on"] = True
            source = flux_faux if FAUX else flux_esp32
            tache["t"] = asyncio.ensure_future(
                source(envoyer, lambda: diffuser["on"]))
            print("pont: écoute démarrée (micro allumé).", flush=True)

        async def arreter():
            diffuser["on"] = False
            if tache["t"]:
                try:
                    await tache["t"]
                except Exception:
                    pass
            print("pont: écoute arrêtée (micro éteint).", flush=True)

        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                if msg.data == "START":
                    await demarrer()
                elif msg.data == "STOP":
                    await arreter()
            elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
                break
        await arreter()


async def principal():
    if not JETON:
        sys.exit("Définis ECOUTE_JETON_SOURCE (le même que sur le relais).")
    while True:
        try:
            async with aiohttp.ClientSession() as session:
                await une_session(session)
        except Exception as e:
            print(f"pont: déconnecté ({e}), nouvel essai dans 5 s.", flush=True)
        else:
            print("pont: relais fermé, nouvel essai dans 5 s.", flush=True)
        await asyncio.sleep(5)


if __name__ == "__main__":
    try:
        asyncio.run(principal())
    except KeyboardInterrupt:
        pass
