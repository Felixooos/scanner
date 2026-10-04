#!/usr/bin/env python3
"""
relais.py — le « point de rendez-vous » qui tourne sur le VPS (ineko).

Personne n'ouvre de port chez Félix : le Mac de la chambre ET le téléphone se
connectent TOUS LES DEUX *vers* ce serveur (connexions sortantes, toujours
autorisées par une box). Le relais ne fait que recopier le son reçu du Mac
vers les navigateurs qui écoutent.

    source  (le Mac, pont_mac.py)  --WebSocket-->  /source   ┐
                                                              ├─ relais ─┐
    auditeur (le téléphone, page)  --WebSocket-->  /ecouter  ┘          │
                                                                        │
    le son du Mac est recopié tel quel vers chaque auditeur  <──────────┘

Le micro ne tourne que quand quelqu'un écoute : dès qu'un auditeur arrive, le
relais dit "START" à la source ; quand le dernier part, "STOP".

Secrets (variables d'environnement) :
    ECOUTE_MOT_DE_PASSE   mot de passe demandé à l'auditeur (le téléphone)
    ECOUTE_JETON_SOURCE   jeton que le Mac présente pour avoir le droit d'émettre

    python3 relais.py          # écoute sur 0.0.0.0:8787 (derrière le proxy TLS)
"""

import asyncio
import os
import secrets
import sys

from aiohttp import web, WSMsgType

MOT_DE_PASSE = os.environ.get("ECOUTE_MOT_DE_PASSE", "")
JETON_SOURCE = os.environ.get("ECOUTE_JETON_SOURCE", "")
PORT = int(os.environ.get("ECOUTE_PORT", "8787"))

if not MOT_DE_PASSE or not JETON_SOURCE:
    sys.exit("Définis ECOUTE_MOT_DE_PASSE et ECOUTE_JETON_SOURCE avant de lancer.")

ICI = os.path.dirname(os.path.abspath(__file__))

auditeurs = set()            # WebSockets des navigateurs qui écoutent
source_actuelle = {"ws": None}   # le Mac, s'il est connecté

# Blocage anti-essais : après trop de mauvais codes depuis une même adresse,
# on la met en pause. Un code court reste donc impossible à deviner par
# force brute (sans ça, un robot teste 10000 codes en quelques secondes).
ECHECS_MAX = 5               # essais ratés avant blocage
BLOCAGE_SEC = 60            # durée du blocage, qui double à chaque récidive
_echecs = {}                 # ip -> [nb_echecs, bloquee_jusqua, duree_courante]


def _est_bloquee(ip):
    e = _echecs.get(ip)
    return bool(e and e[1] > time.time())


def _note_echec(ip):
    e = _echecs.get(ip, [0, 0, BLOCAGE_SEC])
    e[0] += 1
    if e[0] >= ECHECS_MAX:
        e[1] = time.time() + e[2]
        e[2] = min(e[2] * 2, 3600)     # récidive : blocage de plus en plus long
        e[0] = 0
    _echecs[ip] = e


def _reset_echec(ip):
    _echecs.pop(ip, None)


async def dire_a_la_source(mot):
    ws = source_actuelle["ws"]
    if ws is not None and not ws.closed:
        try:
            await ws.send_str(mot)
        except Exception:
            pass


async def page(requete):
    return web.FileResponse(os.path.join(ICI, "page.html"))


async def etat(requete):
    """Petit point de santé : la source est-elle là, combien d'auditeurs."""
    return web.json_response({"source": source_actuelle["ws"] is not None,
                              "auditeurs": len(auditeurs)})


async def canal_source(requete):
    """Le Mac se branche ici et pousse le son (frames binaires PCM)."""
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=0)
    await ws.prepare(requete)

    # premier message = le jeton, comparé sans fuite de timing
    try:
        premier = await ws.receive(timeout=10)
    except asyncio.TimeoutError:
        await ws.close()
        return ws
    jeton = premier.data if premier.type == WSMsgType.TEXT else ""
    if not secrets.compare_digest(jeton or "", JETON_SOURCE):
        await ws.close(code=4003, message=b"jeton invalide")
        return ws

    if source_actuelle["ws"] is not None and not source_actuelle["ws"].closed:
        await source_actuelle["ws"].close(code=4000, message=b"remplacee")
    source_actuelle["ws"] = ws
    print("source connectée", flush=True)
    # si des gens attendent déjà, on lui dit de commencer tout de suite
    if auditeurs:
        await ws.send_str("START")

    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                morts = []
                for a in auditeurs:
                    try:
                        await a.send_bytes(msg.data)
                    except Exception:
                        morts.append(a)
                for a in morts:
                    auditeurs.discard(a)
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break
    finally:
        if source_actuelle["ws"] is ws:
            source_actuelle["ws"] = None
        print("source déconnectée", flush=True)
    return ws


async def canal_auditeur(requete):
    """Un navigateur se branche ici pour écouter (après le mot de passe)."""
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(requete)

    ip = requete.remote or "?"
    if _est_bloquee(ip):
        await ws.send_str("BLOQUE")
        await ws.close(code=4029, message=b"trop d'essais, patiente")
        return ws

    try:
        premier = await ws.receive(timeout=10)
    except asyncio.TimeoutError:
        await ws.close()
        return ws
    mdp = premier.data if premier.type == WSMsgType.TEXT else ""
    if not secrets.compare_digest(mdp or "", MOT_DE_PASSE):
        _note_echec(ip)
        await ws.send_str("NON")
        await ws.close(code=4003, message=b"mot de passe invalide")
        return ws
    _reset_echec(ip)
    await ws.send_str("OK")

    premier_auditeur = not auditeurs
    auditeurs.add(ws)
    if premier_auditeur:
        await dire_a_la_source("START")   # on réveille le micro
    print(f"auditeur connecté ({len(auditeurs)})", flush=True)

    try:
        async for msg in ws:
            if msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break
    finally:
        auditeurs.discard(ws)
        if not auditeurs:
            await dire_a_la_source("STOP")  # plus personne : micro au repos
        print(f"auditeur parti ({len(auditeurs)})", flush=True)
    return ws


def construire_app():
    app = web.Application()
    app.add_routes([
        web.get("/", page),
        web.get("/etat", etat),
        web.get("/source", canal_source),
        web.get("/ecouter", canal_auditeur),
    ])
    return app


if __name__ == "__main__":
    web.run_app(construire_app(), host="0.0.0.0", port=PORT)
