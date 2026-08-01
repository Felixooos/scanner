#!/usr/bin/env python3
"""
magasin_commandes.py — rangement sur disque des commandes clients.

Une « commande » = un nom de client + N empreintes. Tout vit dans un dossier
choisi par l'utilisateur (par défaut ~/Documents/Empreintes MMD), pour que
rien ne soit perdu à la fermeture de l'app.

Arborescence d'une commande (voir PROTOCOLE_V2.md) :

    <dossier_commandes>/<id>/          id = AAAAMMJJ_HHMMSS_<slug-nom>
        commande.json
        vignette.png                   aperçu du dernier rendu
        empreintes/01_<slug-prenom>/
            mosaique.png               mosaïque brute (source de vérité)
            photo.png                  photo normalisée + recadrée (affichage)
        rendus/<forme>_<style>.svg     rendus enregistrés
        rendus/<forme>_<style>.png

La mosaïque est la SEULE source de vérité : elle est stockée en PNG niveaux
de gris 8 bits, donc rechargeable à l'identique. photo.png n'est qu'un
confort d'affichage, régénérable à volonté.

En mémoire, une commande est un dict :

    {"id", "nom", "dossier" (absolu), "cree_le", "modifie_le",
     "forme", "style",
     "empreintes": [{"nom", "mosaique" (ndarray), "crop", "completer",
                     "ajust", "_dossier", "_crop_ecrit"}]}

Les clés commençant par « _ » et la mosaïque ne sont jamais écrites dans le
JSON : elles se déduisent du disque.
"""

import datetime
import json
import os
import re
import shutil
import unicodedata
import zipfile

import cv2

import formes
import fusionner_empreinte as fus

# EMPREINTE_MMD_CONFIG permet de dérouter la configuration ailleurs
# (uniquement pour les tests automatiques : l'app n'y touche jamais).
FICHIER_CONFIG = os.environ.get("EMPREINTE_MMD_CONFIG") or os.path.join(
    os.path.expanduser("~"), ".empreinte_mmd.json")
DOSSIER_DEFAUT = os.path.join(os.path.expanduser("~"), "Documents",
                              "Empreintes MMD")
NOM_CORBEILLE = ".corbeille"
AJUST_NEUTRE = {"dx": 0.0, "dy": 0.0, "angle": 0.0}

MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
        "août", "septembre", "octobre", "novembre", "décembre"]

LIBELLE_FORME = {"simple": "ovales côte à côte", "coeur": "cœur",
                 "trefle": "trèfle", "trefle3": "trèfle à 3 feuilles",
                 "trefle4": "trèfle à 4 feuilles"}
LIBELLE_STYLE = {"photo": "photo de l'empreinte", "gabor": "Gabor plein",
                 "sans": "traits fins", "contact": "traits soudés",
                 "traits": "traits soudés"}


# --------------------------------------------------------------------------
# Configuration (~/.empreinte_mmd.json)
# --------------------------------------------------------------------------

def _lire_config():
    try:
        with open(FICHIER_CONFIG, "r", encoding="utf-8") as f:
            donnees = json.load(f)
        return donnees if isinstance(donnees, dict) else {}
    except Exception:
        return {}


def _ecrire_config(config):
    try:
        with open(FICHIER_CONFIG, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=2)
    except Exception as erreur:                       # disque en lecture seule…
        print(f"   (config non écrite : {erreur})")


def lire_dossier():
    """Dossier de stockage courant (créé s'il n'existe pas)."""
    chemin = _lire_config().get("dossier_commandes") or DOSSIER_DEFAUT
    chemin = os.path.abspath(os.path.expanduser(chemin))
    os.makedirs(chemin, exist_ok=True)
    return chemin


def ecrire_dossier(chemin):
    """Change ET persiste le dossier de stockage. Renvoie le chemin absolu."""
    chemin = os.path.abspath(os.path.expanduser(chemin.strip()))
    os.makedirs(chemin, exist_ok=True)
    config = _lire_config()
    config["dossier_commandes"] = chemin
    _ecrire_config(config)
    return chemin


# --------------------------------------------------------------------------
# Petits outils
# --------------------------------------------------------------------------

def slug(texte, defaut="sans-nom"):
    """Morceau de nom de fichier sûr : minuscules, sans accent ni espace."""
    texte = unicodedata.normalize("NFKD", str(texte or ""))
    texte = texte.encode("ascii", "ignore").decode("ascii").lower()
    texte = re.sub(r"[^a-z0-9]+", "-", texte).strip("-")
    return texte[:40] or defaut


def maintenant():
    return datetime.datetime.now().replace(microsecond=0).isoformat()


def _date_lisible(iso, avec_heure=False):
    """« 1er août 2026 » / « 1er août 2026 à 15:02 »."""
    try:
        d = datetime.datetime.fromisoformat(iso)
    except Exception:
        return iso or "date inconnue"
    jour = "1er" if d.day == 1 else str(d.day)
    texte = f"{jour} {MOIS[d.month - 1]} {d.year}"
    return f"{texte} à {d:%H:%M}" if avec_heure else texte


def _liste_francaise(mots):
    """['a','b','c'] -> 'a, b et c'."""
    mots = [m for m in mots if m]
    if not mots:
        return ""
    if len(mots) == 1:
        return mots[0]
    return ", ".join(mots[:-1]) + " et " + mots[-1]


def _proprement(cmd):
    """Copie sérialisable de la commande (sans mosaïques ni clés privées)."""
    empreintes = []
    for e in cmd["empreintes"]:
        empreintes.append({
            "nom": e.get("nom") or "",
            "dossier": e.get("_dossier") or "",
            "crop": list(e["crop"]) if e.get("crop") else None,
            "completer": bool(e.get("completer", True)),
            "ajust": dict(e.get("ajust") or AJUST_NEUTRE),
        })
    return {"id": cmd["id"], "nom": cmd["nom"],
            "cree_le": cmd.get("cree_le"), "modifie_le": cmd.get("modifie_le"),
            "forme": cmd.get("forme"), "style": cmd.get("style"),
            "empreintes": empreintes}


# --------------------------------------------------------------------------
# Création / lecture / écriture d'une commande
# --------------------------------------------------------------------------

def commande_vide(nom="Commande"):
    """Commande en mémoire pas encore posée sur le disque (id = None)."""
    return {"id": None, "nom": nom or "Commande", "dossier": None,
            "cree_le": None, "modifie_le": None,
            "forme": None, "style": None, "empreintes": []}


def creer(nom, empreintes=None, dossier_racine=None):
    """Crée le dossier de la commande TOUT DE SUITE et renvoie le dict."""
    racine = dossier_racine or lire_dossier()
    horodatage = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    identifiant = f"{horodatage}_{slug(nom, 'commande')}"
    chemin = os.path.join(racine, identifiant)
    suffixe = 2
    while os.path.exists(chemin):                     # deux commandes/seconde
        chemin = os.path.join(racine, f"{identifiant}-{suffixe}")
        suffixe += 1
    identifiant = os.path.basename(chemin)
    os.makedirs(os.path.join(chemin, "empreintes"), exist_ok=True)
    os.makedirs(os.path.join(chemin, "rendus"), exist_ok=True)
    instant = maintenant()
    cmd = {"id": identifiant, "nom": nom or "Commande", "dossier": chemin,
           "cree_le": instant, "modifie_le": instant,
           "forme": None, "style": None, "empreintes": empreintes or []}
    synchroniser(cmd)
    return cmd


def chemin_de(identifiant, dossier_racine=None):
    return os.path.join(dossier_racine or lire_dossier(), identifiant)


def ecrire_json(cmd, toucher=True):
    """Écrit commande.json. toucher=False garde la date de modification
    existante (une simple relecture n'est pas une modification)."""
    if not cmd.get("dossier"):
        return
    if toucher or not cmd.get("modifie_le"):
        cmd["modifie_le"] = maintenant()
    os.makedirs(cmd["dossier"], exist_ok=True)
    with open(os.path.join(cmd["dossier"], "commande.json"), "w",
              encoding="utf-8") as f:
        json.dump(_proprement(cmd), f, ensure_ascii=False, indent=2)


def photo_normalisee(mosaique, crop):
    """Image d'affichage d'une empreinte : le crop de l'utilisateur appliqué
    EXACTEMENT comme au moment du rendu (formes.recadrer_mosaique), puis le
    renforcement de contraste de fusionner_empreinte."""
    return fus.normaliser_affichage(formes.recadrer_mosaique(mosaique, crop))


def synchroniser(cmd, toucher=True):
    """Pose sur le disque l'état complet de la commande : un dossier par
    empreinte nommé NN_<slug-prénom> dans l'ordre de commande.json, les PNG,
    puis commande.json. Idempotent, et ne réécrit que ce qui a changé."""
    if not cmd.get("dossier"):
        return
    base = os.path.join(cmd["dossier"], "empreintes")
    os.makedirs(base, exist_ok=True)
    os.makedirs(os.path.join(cmd["dossier"], "rendus"), exist_ok=True)

    # 1. les dossiers déjà connus passent par un nom temporaire : l'ordre et
    #    les prénoms ont pu changer, on évite toute collision de renommage.
    provisoires = {}
    for i, e in enumerate(cmd["empreintes"]):
        # _dossier est relatif à la commande (« empreintes/01_louis ») :
        # ici on travaille dans empreintes/, donc seul le dernier morceau sert.
        ancien = os.path.basename(e.get("_dossier") or "")
        if ancien and os.path.isdir(os.path.join(base, ancien)):
            provisoire = f"__mouvement_{i}__"
            os.rename(os.path.join(base, ancien),
                      os.path.join(base, provisoire))
            provisoires[i] = provisoire

    # 2. ce qui reste n'appartient plus à la commande (empreinte supprimée)
    for nom in os.listdir(base):
        if nom.startswith("__mouvement_"):
            continue
        cible = os.path.join(base, nom)
        try:
            shutil.rmtree(cible) if os.path.isdir(cible) else os.remove(cible)
        except Exception as erreur:
            print(f"   (ménage {cible} : {erreur})")

    # 3. nom définitif + fichiers
    for i, e in enumerate(cmd["empreintes"]):
        final = f"{i + 1:02d}_{slug(e.get('nom'), f'empreinte-{i + 1}')}"
        chemin = os.path.join(base, final)
        if i in provisoires:
            os.rename(os.path.join(base, provisoires[i]), chemin)
        else:
            os.makedirs(chemin, exist_ok=True)
        e["_dossier"] = f"empreintes/{final}"

        mosaique = e.get("mosaique")
        fichier_mosaique = os.path.join(chemin, "mosaique.png")
        if mosaique is not None and not os.path.exists(fichier_mosaique):
            cv2.imwrite(fichier_mosaique, mosaique)
        fichier_photo = os.path.join(chemin, "photo.png")
        crop = list(e["crop"]) if e.get("crop") else None
        if mosaique is not None and (not os.path.exists(fichier_photo)
                                     or e.get("_crop_ecrit") != crop):
            cv2.imwrite(fichier_photo, photo_normalisee(mosaique, e.get("crop")))
            e["_crop_ecrit"] = crop
        e["photo"] = fichier_photo

    ecrire_json(cmd, toucher)


def lire(identifiant, dossier_racine=None):
    """Recharge une commande complète depuis le disque (mosaïques comprises).
    Lève FileNotFoundError si la commande n'existe pas."""
    chemin = chemin_de(identifiant, dossier_racine)
    fichier = os.path.join(chemin, "commande.json")
    if not os.path.exists(fichier):
        raise FileNotFoundError(f"commande introuvable : {identifiant}")
    with open(fichier, "r", encoding="utf-8") as f:
        donnees = json.load(f)

    empreintes = []
    for e in donnees.get("empreintes") or []:
        relatif = e.get("dossier") or ""
        dossier_empreinte = os.path.join(chemin, *relatif.split("/"))
        mosaique = cv2.imread(os.path.join(dossier_empreinte, "mosaique.png"),
                              cv2.IMREAD_GRAYSCALE)
        if mosaique is None:
            print(f"   (mosaïque illisible, empreinte ignorée : {relatif})")
            continue
        crop = e.get("crop")
        empreintes.append({
            "nom": e.get("nom") or "",
            "mosaique": mosaique,
            "crop": tuple(crop) if crop else None,
            "completer": bool(e.get("completer", True)),
            "ajust": dict(e.get("ajust") or AJUST_NEUTRE),
            "_dossier": relatif,
            "_crop_ecrit": list(crop) if crop else None,
            "photo": os.path.join(dossier_empreinte, "photo.png"),
        })

    cmd = {"id": donnees.get("id") or identifiant,
           "nom": donnees.get("nom") or identifiant,
           "dossier": chemin,
           "cree_le": donnees.get("cree_le"),
           "modifie_le": donnees.get("modifie_le"),
           "forme": donnees.get("forme"), "style": donnees.get("style"),
           "empreintes": empreintes}
    # recrée photo.png / rendus/ si besoin, sans changer la date : ouvrir
    # une commande n'est pas la modifier.
    synchroniser(cmd, toucher=False)
    return cmd


def lister(dossier_racine=None):
    """Résumé de toutes les commandes rangées, les plus récemment modifiées
    d'abord : [{id, nom, date, nb, forme, style, vignette}]."""
    racine = dossier_racine or lire_dossier()
    liste = []
    for nom in sorted(os.listdir(racine)):
        if nom.startswith("."):                       # .corbeille, .DS_Store…
            continue
        chemin = os.path.join(racine, nom)
        fichier = os.path.join(chemin, "commande.json")
        if not os.path.isfile(fichier):
            continue
        try:
            with open(fichier, "r", encoding="utf-8") as f:
                donnees = json.load(f)
        except Exception as erreur:
            print(f"   (commande.json illisible dans {nom} : {erreur})")
            continue
        vignette = os.path.join(chemin, "vignette.png")
        liste.append({
            "id": donnees.get("id") or nom,
            "nom": donnees.get("nom") or nom,
            "date": donnees.get("modifie_le") or donnees.get("cree_le") or "",
            "nb": len(donnees.get("empreintes") or []),
            "forme": donnees.get("forme"), "style": donnees.get("style"),
            "dossier": chemin,
            "vignette": vignette if os.path.exists(vignette) else None,
        })
    liste.sort(key=lambda c: c["date"], reverse=True)
    return liste


def supprimer(identifiant, dossier_racine=None):
    """Déplace la commande vers <dossier_commandes>/.corbeille/ (jamais de
    suppression définitive : l'utilisateur peut se tromper)."""
    racine = dossier_racine or lire_dossier()
    source = os.path.join(racine, identifiant)
    if not os.path.isdir(source):
        raise FileNotFoundError(f"commande introuvable : {identifiant}")
    corbeille = os.path.join(racine, NOM_CORBEILLE)
    os.makedirs(corbeille, exist_ok=True)
    cible = os.path.join(corbeille, identifiant)
    if os.path.exists(cible):
        cible = os.path.join(
            corbeille,
            f"{identifiant}_{datetime.datetime.now():%Y%m%d_%H%M%S}")
    shutil.move(source, cible)
    return cible


# --------------------------------------------------------------------------
# Export (zip + petit texte pour le mail)
# --------------------------------------------------------------------------

def resume(cmd):
    """Texte lisible en français, prêt à coller dans le corps d'un mail."""
    noms = [e.get("nom") or f"Empreinte {i + 1}"
            for i, e in enumerate(cmd["empreintes"])]
    nb = len(noms)
    lignes = [f"Commande « {cmd['nom']} »"]
    if cmd.get("cree_le"):
        ligne = f"Créée le {_date_lisible(cmd['cree_le'])}"
        if cmd.get("modifie_le") and cmd["modifie_le"][:10] != cmd["cree_le"][:10]:
            ligne += f", modifiée le {_date_lisible(cmd['modifie_le'], True)}"
        else:
            ligne += f", dernière modification à {cmd.get('modifie_le', '')[11:16]}"
        lignes.append(ligne)
    if nb == 0:
        lignes.append("Aucune empreinte pour l'instant.")
    elif nb == 1:
        lignes.append(f"1 empreinte : {noms[0]}.")
    else:
        lignes.append(f"{nb} empreintes : {_liste_francaise(noms)}.")
    forme, style = cmd.get("forme"), cmd.get("style")
    if forme or style:
        lignes.append(
            "Forme : {} — Style : {}.".format(
                LIBELLE_FORME.get(forme, forme or "non choisie"),
                LIBELLE_STYLE.get(style, style or "non choisi")))
    else:
        lignes.append("Forme et style pas encore choisis.")
    lignes.append("")
    lignes.append("Le dossier joint contient les mosaïques d'origine, "
                  "les photos et les rendus à graver.")
    return "\n".join(lignes)


def exporter(cmd, dossier_racine=None):
    """Zippe le dossier de la commande (sans les fichiers cachés) dans
    <dossier_commandes>/<id>.zip. Renvoie (chemin_zip, resume)."""
    if not cmd.get("dossier"):
        raise ValueError("commande pas encore enregistrée")
    synchroniser(cmd)
    racine = dossier_racine or lire_dossier()
    chemin_zip = os.path.join(racine, f"{cmd['id']}.zip")
    source = cmd["dossier"]
    with zipfile.ZipFile(chemin_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for dossier, sous_dossiers, fichiers in os.walk(source):
            sous_dossiers[:] = [d for d in sous_dossiers
                                if not d.startswith(".")]
            for fichier in sorted(fichiers):
                if fichier.startswith("."):
                    continue
                complet = os.path.join(dossier, fichier)
                interne = os.path.join(
                    cmd["id"], os.path.relpath(complet, source))
                archive.write(complet, interne)
    return chemin_zip, resume(cmd)
