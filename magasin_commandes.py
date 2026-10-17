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
            poses/pose_01.png …        captures brutes acceptées (si connues)
        rendus/<forme>_<style>.svg     rendus enregistrés
        rendus/<forme>_<style>.png

    <dossier_commandes>/Exports/<Nom client>/      export lisible (dézippé)
    <dossier_commandes>/Exports/<Nom client>.zip   le même, prêt pour un mail

La mosaïque est la SEULE source de vérité : elle est stockée en PNG niveaux
de gris 8 bits, donc rechargeable à l'identique. photo.png n'est qu'un
confort d'affichage, régénérable à volonté. Les poses brutes ne servent qu'à
re-fusionner plus tard avec de meilleurs algorithmes.

En mémoire, une commande est un dict :

    {"id", "nom", "dossier" (absolu), "cree_le", "modifie_le",
     "forme", "style",
     "empreintes": [{"nom", "mosaique" (ndarray), "crop", "completer",
                     "ajust", "poses" (liste d'ndarray, en attente
                     d'écriture), "_dossier", "_crop_ecrit"}]}

Les clés commençant par « _ », la mosaïque et les poses ne sont jamais
écrites dans le JSON : elles se déduisent du disque.
"""

import datetime
import json
import os
import re
import shutil
import tempfile
import unicodedata
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

import cv2
import numpy as np

import formes
import fusionner_empreinte as fus

# EMPREINTE_MMD_CONFIG permet de dérouter la configuration ailleurs
# (uniquement pour les tests automatiques : l'app n'y touche jamais).
FICHIER_CONFIG = os.environ.get("EMPREINTE_MMD_CONFIG") or os.path.join(
    os.path.expanduser("~"), ".empreinte_mmd.json")
DOSSIER_DEFAUT = os.path.join(os.path.expanduser("~"), "Documents",
                              "Empreintes MMD")
NOM_CORBEILLE = ".corbeille"
NOM_EXPORTS = "Exports"           # <dossier_commandes>/Exports/ : jamais listé
AJUST_NEUTRE = {"dx": 0.0, "dy": 0.0, "angle": 0.0}

MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
        "août", "septembre", "octobre", "novembre", "décembre"]

# Style quand l'utilisateur n'en a encore choisi aucun : le même que l'app
# (Moteur.swift : `style = "contact"`) et que formes.nom_style(None).
STYLE_DEFAUT = "contact"

# Les styles tels que l'app les présente (Moteur.styles) : le nom nomme les
# fichiers exportés, l'aide explique le style dans le récapitulatif.
# Clés = noms canoniques de formes.nom_style (« traits » -> « contact »…).
STYLES = {
    "gabor": ("Gabor", "crêtes épaisses et séparées, vallées visibles"),
    "sans": ("Traits", "traits fins, aucun trait ne touche son voisin"),
    "contact": ("Traits soudés", "traits fins, les bifurcations se rejoignent"),
    "photo": ("Photo", "la vraie photo de l'empreinte, découpée"),
}

# Les formes telles que l'app les présente (Moteur.formesDisponibles).
# Clés = noms canoniques de formes.nom_forme (« trefle3 » -> « trefle »).
FORMES = {"simple": "Simple", "separees": "Séparées", "coeur": "Cœur",
          "trefle": "Trèfle", "ovale_lr": "Ovale coupé",
          "tete_beche": "Tête-bêche"}
# Ce qu'est la forme, dit en toutes lettres (récapitulatif, mail).
LIBELLE_FORME = {"simple": "empreintes séparées",
                 "separees": "empreintes séparées",
                 "coeur": "cœur", "trefle": "trèfle",
                 "ovale_lr": "ovale coupé (gauche / droite)",
                 "tete_beche": "ovale tête-bêche"}
# Formes qui donnent UN rendu assemblé. « separees » (et l'ancien « simple »,
# que l'app traite comme « separees ») : une médaille par empreinte, donc
# seulement les empreintes seules.
FORMES_ASSEMBLEES = ("coeur", "trefle", "ovale_lr", "tete_beche")
PHRASE_SEPAREES = "Empreintes séparées : une médaille par empreinte."


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

        # poses brutes de la session de scan : écrites une fois, puis
        # libérées de la mémoire (le dossier les garde, il suit les renommages)
        if e.get("poses") and ecrire_poses(chemin, e["poses"]):
            e.pop("poses", None)

    ecrire_json(cmd, toucher)


def ecrire_poses(dossier_empreinte, poses):
    """Écrit les captures brutes acceptées dans <empreinte>/poses/pose_01.png,
    pose_02.png… (PNG sans perte : rechargeables à l'identique pour une
    future re-fusion). Renvoie True si tout est écrit."""
    dossier = os.path.join(dossier_empreinte, "poses")
    try:
        os.makedirs(dossier, exist_ok=True)
        for ancien in os.listdir(dossier):            # jamais de mélange
            if ancien.startswith("pose_") and ancien.endswith(".png"):
                os.remove(os.path.join(dossier, ancien))
        numero = 0
        for pose in poses:
            if pose is None:
                continue
            image = np.asarray(pose)
            if image.dtype != np.uint8:
                image = np.clip(image, 0, 255).astype(np.uint8)
            numero += 1
            if not cv2.imwrite(os.path.join(dossier, f"pose_{numero:02d}.png"),
                               image):
                raise IOError(f"pose {numero} non écrite")
        return True
    except Exception as erreur:
        print(f"   (poses brutes non écrites dans {dossier} : {erreur})")
        return False


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
        if nom.startswith(".") or nom == NOM_EXPORTS:  # .corbeille, Exports/…
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
# Export : un dossier lisible au nom du client + le même en zip pour un mail
# --------------------------------------------------------------------------

# « / » et « : » sont interdits sur Mac ; \ * ? " < > | le sont sur Windows :
# le zip part par mail, on ne sait pas sur quel ordinateur il sera ouvert.
_CARACTERES_INTERDITS = re.compile(r'[/\\:*?"<>|\x00-\x1f\x7f]')
_NOMS_RESERVES_WINDOWS = ({"CON", "PRN", "AUX", "NUL"}
                          | {f"COM{i}" for i in range(1, 10)}
                          | {f"LPT{i}" for i in range(1, 10)})
TIRET = " – "                     # « Louis – photo.png »
NOM_RECAPITULATIF = "Récapitulatif.txt"


def nom_lisible(texte, defaut="Sans nom"):
    """Nom de fichier ou de dossier LISIBLE : accents, espaces et majuscules
    gardés (contrairement à slug), seuls les caractères interdits sont
    retirés. Jamais vide, jamais caché (pas de point en tête)."""
    texte = unicodedata.normalize("NFC", str(texte or ""))
    texte = _CARACTERES_INTERDITS.sub(" ", texte)
    texte = " ".join(texte.split())                   # un seul espace
    texte = texte.lstrip(". ")[:80].rstrip(". ")      # « .x » serait caché
    if texte.split(".")[0].upper() in _NOMS_RESERVES_WINDOWS:
        texte += "_"
    return texte or defaut


def _unique(nom, pris):
    """« Louis », puis « Louis (2) », « Louis (3) »… La comparaison ignore la
    casse : le disque du Mac ne distingue pas « louis » de « Louis »."""
    candidat, numero = nom, 2
    while candidat.casefold() in pris:
        candidat = f"{nom} ({numero})"
        numero += 1
    pris.add(candidat.casefold())
    return candidat


def libelle_style(style):
    """« Traits soudés », « Gabor »… — le nom affiché par l'app."""
    cle = formes.nom_style(style or STYLE_DEFAUT)
    return STYLES.get(cle, (cle.capitalize(), ""))[0]


def libelle_forme(forme, nb):
    """« Cœur », « Trèfle 3 », « Simple »… — comme les boutons de l'app."""
    cle = formes.nom_forme(forme)
    libelle = FORMES.get(cle, cle.capitalize())
    if cle == "trefle" and nb in (3, 4):
        libelle += f" {nb}"
    return libelle


def forme_compatible(forme, nb):
    """La forme choisie accueille-t-elle nb empreintes ? L'app ne propose le
    cœur, l'ovale coupé et le tête-bêche qu'à 2 et le trèfle qu'à 3 ou 4 :
    une empreinte ajoutée ou retirée après coup rend le choix caduc (le rendu
    en perdrait une)."""
    if not forme or nb < 1:
        return False
    cle = formes.nom_forme(forme)
    if cle in ("coeur", "ovale_lr", "tete_beche"):
        return nb == 2
    if cle == "trefle":
        return nb in (3, 4)
    return True                       # separees / simple : tout nombre


def forme_assemblee(forme):
    """La forme donne-t-elle un rendu final ASSEMBLÉ ? Non pour « separees »,
    « simple » ou pas de forme : une médaille par empreinte."""
    return bool(forme) and formes.nom_forme(forme) in FORMES_ASSEMBLEES


def rendu_final_possible(forme, nb):
    """Un rendu assemblé est-il à produire pour cette forme et nb empreintes ?"""
    return forme_assemblee(forme) and forme_compatible(forme, nb)


def _ecrire_png(chemin, image):
    """cv2.imwrite sans souci d'accents dans le chemin (on encode en mémoire
    puis Python écrit le fichier)."""
    ok, tampon = cv2.imencode(".png", image)
    if not ok:
        raise IOError(f"PNG non encodé : {os.path.basename(chemin)}")
    with open(chemin, "wb") as f:
        f.write(tampon.tobytes())


def rendre(mosaiques, forme, style, chemin_svg, chemin_png, crops=None,
           completions=None, ajusts=None):
    """SVG (vectoriel, à graver) + PNG (pour regarder) par formes.composer,
    exactement comme APERCU / ENREGISTRER. composer() pose des fichiers de
    diagnostic à côté du PNG : on travaille dans un dossier temporaire et on
    ne garde que les deux fichiers demandés."""
    with tempfile.TemporaryDirectory(prefix="empreinte_rendu_") as tmp:
        svg = os.path.join(tmp, "rendu.svg")
        png = os.path.join(tmp, "rendu.png")
        formes.composer(mosaiques, forme, style, svg, apercu_png=png,
                        crops=crops, completions=completions, ajusts=ajusts)
        shutil.move(svg, chemin_svg)
        shutil.move(png, chemin_png)


def rendre_empreinte(empreinte, style, chemin_svg, chemin_png):
    """UNE empreinte seule dans un style : l'ovale « simple » à un seul lobe
    (ce que l'app montre pour une commande d'une empreinte), avec le
    cadrage et la complétion de l'empreinte. Son « ajust » n'est pas
    appliqué : il règle la place dans un lobe de cœur ou de trèfle, il ne
    concerne pas l'empreinte seule."""
    rendre([empreinte["mosaique"]], "simple", style, chemin_svg, chemin_png,
           crops=[empreinte.get("crop")],
           completions=[empreinte.get("completer", True)])


def _ajust_neutre(ajust):
    ajust = ajust or {}
    return all(abs(float(ajust.get(k, 0.0) or 0.0)) < 1e-4
               for k in ("dx", "dy", "angle"))


def _style_photo(style):
    return formes.nom_style(style or STYLE_DEFAUT) == "photo"


def role_svg(style):
    """Ce qu'est un SVG exporté, dit simplement (récapitulatif)."""
    if _style_photo(style):
        return "la photo découpée, dans un SVG (pas de tracé vectoriel)"
    return "à graver (vectoriel)"


def _ligne_forme_style(cmd):
    """« Forme : Cœur — Style : Traits soudés. » (avec les cas particuliers ;
    empreintes séparées : « Empreintes séparées : une médaille par
    empreinte. » puis « Style : … » à la ligne)."""
    nb = len(cmd["empreintes"])
    forme, style = cmd.get("forme"), cmd.get("style")
    if not forme_assemblee(forme):
        texte = f"{PHRASE_SEPAREES}\nStyle : {libelle_style(style)}"
        if not style:
            texte += " (style par défaut de l'app, aucun n'a encore été choisi)"
        return texte + "."
    cle = formes.nom_forme(forme)
    if cle in ("ovale_lr", "tete_beche"):          # « Ovale coupé (gauche / droite) »
        nom_forme = LIBELLE_FORME[cle][:1].upper() + LIBELLE_FORME[cle][1:]
    else:                                          # « Cœur », « Trèfle 3 »
        nom_forme = libelle_forme(forme, nb)
    texte = f"Forme : {nom_forme}"
    if nb and not forme_compatible(forme, nb):
        texte += (f" (ne convient pas à {nb} empreinte{'s' * (nb > 1)} : "
                  "rendu final à refaire dans l'app)")
    texte += f" — Style : {libelle_style(style)}"
    if not style:
        texte += " (style par défaut de l'app, aucun n'a encore été choisi)"
    return texte + "."


def resume(cmd):
    """Texte lisible en français, prêt à coller dans le corps d'un mail."""
    noms = [e.get("nom") or f"Empreinte {i + 1}"
            for i, e in enumerate(cmd["empreintes"])]
    nb = len(noms)
    lignes = [f"Commande « {cmd['nom']} »"]
    if cmd.get("cree_le"):
        modifie = cmd.get("modifie_le") or ""
        ligne = f"Créée le {_date_lisible(cmd['cree_le'])}"
        if modifie and modifie[:10] != cmd["cree_le"][:10]:
            ligne += f", modifiée le {_date_lisible(modifie, True)}"
        elif modifie[11:16]:
            ligne += f", dernière modification à {modifie[11:16]}"
        lignes.append(ligne)
    if nb == 0:
        lignes.append("Aucune empreinte pour l'instant.")
    elif nb == 1:
        lignes.append(f"1 empreinte : {noms[0]}.")
    else:
        lignes.append(f"{nb} empreintes : {_liste_francaise(noms)}.")
    lignes.append(_ligne_forme_style(cmd))
    lignes.append("")
    if nb == 0:
        lignes.append("Le dossier joint ne contient que le récapitulatif.")
    else:
        if _style_photo(cmd.get("style")):
            contenu = ("Le dossier joint contient, pour chaque empreinte, sa "
                       "photo et son rendu « Photo » (SVG et PNG)")
        else:
            contenu = ("Le dossier joint contient, pour chaque empreinte, sa "
                       f"photo et son tracé « {libelle_style(cmd.get('style'))} »"
                       " (SVG vectoriel prêt à graver, PNG pour regarder)")
        if rendu_final_possible(cmd.get("forme"), nb):
            contenu += ", ainsi que le rendu final assemblé"
        lignes.append(contenu + ".")
    return "\n".join(lignes)


def recapitulatif(cmd, nom, compose, empreintes, avertissements):
    """Contenu de Récapitulatif.txt : le résumé du mail, puis le détail des
    fichiers. compose = nom (sans extension) du rendu final ou None ;
    empreintes = [(prénom affiché, dossier, [(fichier, rôle)], completer)]."""
    style = cmd.get("style")
    lignes = [resume(cmd), "", "─" * 60,
              f"Exporté le {_date_lisible(maintenant(), True)}.", ""]
    if compose:
        lignes.append(f"Rendu final ({libelle_forme(cmd.get('forme'), len(empreintes))}, "
                      f"{libelle_style(style)}) :")
        lignes.append(f"    {compose}.svg    {role_svg(style)}")
        lignes.append(f"    {compose}.png    pour regarder")
        lignes.append("")
    if empreintes:
        lignes.append("Empreintes :")
    for numero, (prenom, dossier, fichiers, completer) in enumerate(empreintes, 1):
        lignes.append(f"  {numero}. {prenom} — dossier « {dossier} »")
        largeur = max((len(f) for f, _ in fichiers), default=0)
        for fichier, role in fichiers:
            lignes.append(f"       {fichier.ljust(largeur)}    {role}")
        lignes.append("       zones manquantes complétées : "
                      + ("oui" if completer else "non"))
    if empreintes:
        lignes.append("")
    aide = STYLES.get(formes.nom_style(style or STYLE_DEFAUT), ("", ""))[1]
    if aide:
        lignes.append(f"Style « {libelle_style(style)} » : {aide}.")
    if not style:
        lignes.append("Aucun style n'avait encore été choisi : c'est le style "
                      "par défaut de l'app qui a été exporté.")
    if _style_photo(style):
        lignes.append("Les fichiers .svg contiennent la photo elle-même, pas "
                      "un tracé vectoriel. Les .png ne servent qu'à regarder.")
    else:
        lignes.append("Les fichiers .svg sont vectoriels : ce sont eux qu'il "
                      "faut graver. Les .png ne servent qu'à regarder.")
    if avertissements:
        lignes += ["", "Attention :"] + [f"  - {a}" for a in avertissements]
    lignes += ["", f"Client : {nom} — référence de la commande : {cmd['id']}"]
    return "\n".join(lignes) + "\n"


def _zipper(base, nom, relatifs, chemin_zip):
    """Zip de la LISTE de fichiers produits (jamais un parcours du disque :
    pas de .DS_Store ni de fichier égaré), sous un dossier racine <nom>/."""
    horodatage = datetime.datetime.now().timetuple()[:6]

    def dossier(interne):
        info = zipfile.ZipInfo(interne, horodatage)
        info.external_attr = (0o40755 << 16) | 0x10     # dossier Unix + DOS
        archive.writestr(info, b"")

    with zipfile.ZipFile(chemin_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        dossier(f"{nom}/")
        vus = set()
        for relatif in relatifs:
            parent = os.path.dirname(relatif)
            if parent and parent not in vus:
                dossier(f"{nom}/{parent}/")
                vus.add(parent)
            archive.write(os.path.join(base, relatif), f"{nom}/{relatif}")


# Tracés calculés en parallèle pendant l'export : l'essentiel du calcul se
# passe dans OpenCV (filter2D), qui relâche le GIL. Mesuré : deux rendus
# côte à côte vont ~1,6 fois plus vite que l'un après l'autre. On reste à 2
# pour ne pas étouffer un petit Mac.
TRAVAILLEURS_EXPORT = 2


def exporter(cmd, dossier_racine=None, rendu_compose=None, progres=None):
    """Prépare l'envoi d'une commande, prêt à joindre à un mail :

        <dossier_commandes>/Exports/<Nom client>/
            Récapitulatif.txt
            <Nom client> – <Forme> <Style>.svg / .png   (si forme choisie)
            <Prénom>/
                <Prénom> – photo.png                    (photo recadrée)
                <Prénom> – <Style>.svg / .png           (l'empreinte seule)
        <dossier_commandes>/Exports/<Nom client>.zip    (ce même dossier)

    Noms lisibles (accents gardés, / et : retirés, homonymes « Louis (2) »).
    Ni mosaïque, ni pose brute, ni fichier caché : seulement ce qui sert au
    client ou à la gravure. Un nouvel export remplace l'ancien du même
    client. Sans style choisi, c'est STYLE_DEFAUT (le défaut de l'app).

    dossier_racine : où ranger Exports/ (défaut : le dossier_commandes qui
        contient la commande).
    rendu_compose : {"svg", "png"} déjà calculés pour la forme et le style
        de la commande (cache d'aperçus du moteur) ; sinon recalculé.
    progres(etape, total, texte) : etape = numéro de l'étape EN COURS
        (1..total), c.-à-d. étapes terminées + 1. Une étape = le tracé d'une
        empreinte, le rendu final (s'il y en a un), le zip.

    Renvoie {dossier, zip, resume, nom, fichiers (chemins absolus), forme,
    style, style_defaut, avertissements}."""
    if not cmd.get("dossier"):
        raise ValueError("commande pas encore enregistrée")
    synchroniser(cmd, toucher=False)          # exporter n'est pas modifier
    racine = dossier_racine or os.path.dirname(os.path.abspath(cmd["dossier"]))
    exports = os.path.join(racine, NOM_EXPORTS)
    os.makedirs(exports, exist_ok=True)

    empreintes = cmd["empreintes"]
    nb = len(empreintes)
    style = formes.nom_style(cmd.get("style") or STYLE_DEFAUT)
    nom_style = libelle_style(style)
    # « Louis – Photo.png » écraserait « Louis – photo.png » (le Mac ignore
    # la casse) : le tracé du style photo prend un nom à lui.
    nom_style_fichier = ("Photo découpée" if nom_style.casefold() == "photo"
                         else nom_style)
    forme = cmd.get("forme")
    avertissements = []
    if forme_assemblee(forme) and nb and not forme_compatible(forme, nb):
        avertissements.append(
            f"la forme « {libelle_forme(forme, nb)} » ne convient pas à {nb} "
            f"empreinte{'s' * (nb > 1)} : pas de rendu final, à refaire dans "
            "l'app.")

    nom = nom_lisible(cmd.get("nom"), "Commande")
    # separees / simple / pas de forme : seulement les empreintes seules
    compose = (nom_lisible(f"{nom}{TIRET}{libelle_forme(forme, nb)} {nom_style}")
               if rendu_final_possible(forme, nb) else None)
    total = nb + (1 if compose else 0) + 1
    fait = [0]

    def avancer(texte, terminee=True):
        """etape transmise = étape EN COURS = étapes terminées + 1 (1..total) :
        fraction accomplie = (etape − 1) / total."""
        if terminee:
            fait[0] += 1
        if progres is not None:
            try:
                progres(min(fait[0] + 1, total), total, texte)
            except Exception:
                pass                          # l'affichage ne bloque jamais

    avancer("Préparation de l'export…", terminee=False)

    # tout se prépare dans un chantier caché : un export raté ne détruit pas
    # le précédent, qui n'est remplacé qu'à la toute fin
    chantier = tempfile.mkdtemp(prefix=".export-", dir=exports)
    try:
        base = os.path.join(chantier, nom)
        os.makedirs(base)
        pris = {NOM_RECAPITULATIF.casefold()}
        if compose:
            pris |= {(compose + ext).casefold() for ext in (".svg", ".png")}

        # 1. un dossier et une photo par empreinte (rapide)
        fiches = []
        for i, e in enumerate(empreintes):
            prenom = _unique(nom_lisible(e.get("nom"), f"Empreinte {i + 1}"),
                             pris)
            os.makedirs(os.path.join(base, prenom))
            fiche = {"nom": e.get("nom") or f"Empreinte {i + 1}",
                     "prenom": prenom, "photo": None, "trace": None,
                     "completer": bool(e.get("completer", True))}
            photo = f"{prenom}{TIRET}photo.png"
            if e.get("mosaique") is not None:
                _ecrire_png(os.path.join(base, prenom, photo),
                            photo_normalisee(e["mosaique"], e.get("crop")))
                fiche["photo"] = photo
            elif e.get("photo") and os.path.isfile(e["photo"]):
                shutil.copyfile(e["photo"], os.path.join(base, prenom, photo))
                fiche["photo"] = photo
            fiches.append(fiche)

        # 2. le rendu final : copié de l'aperçu du moteur s'il est à jour,
        #    sinon recalculé
        svg_c = os.path.join(base, f"{compose}.svg") if compose else None
        png_c = os.path.join(base, f"{compose}.png") if compose else None
        deja = rendu_compose or {}
        compose_en_cache = bool(compose) and all(
            deja.get(k) and os.path.isfile(deja[k]) for k in ("svg", "png"))
        compose_ok = False
        if compose_en_cache:
            shutil.copyfile(deja["svg"], svg_c)
            shutil.copyfile(deja["png"], png_c)
            compose_ok = True
            avancer(f"Rendu final {libelle_forme(forme, nb)} prêt")

        # 3. les tracés (et le rendu final à recalculer), en parallèle
        with ThreadPoolExecutor(max_workers=TRAVAILLEURS_EXPORT) as atelier:
            travaux = {}
            if compose and not compose_en_cache:
                # le plus long (une complétion par lobe) : lancé en premier
                travaux[atelier.submit(
                    rendre, [e.get("mosaique") for e in empreintes], forme,
                    style, svg_c, png_c,
                    crops=[e.get("crop") for e in empreintes],
                    completions=[e.get("completer", True) for e in empreintes],
                    ajusts=[e.get("ajust") for e in empreintes])] = None
            for i, (e, fiche) in enumerate(zip(empreintes, fiches)):
                prenom = fiche["prenom"]
                if e.get("mosaique") is None:
                    avertissements.append(
                        f"{prenom} : mosaïque introuvable, pas de tracé.")
                    avancer(f"{prenom} : pas de tracé")
                    continue
                svg = f"{prenom}{TIRET}{nom_style_fichier}.svg"
                png = f"{prenom}{TIRET}{nom_style_fichier}.png"
                fiche["_trace"] = (svg, png)
                travaux[atelier.submit(
                    rendre_empreinte, e, style,
                    os.path.join(base, prenom, svg),
                    os.path.join(base, prenom, png))] = i
            for futur in as_completed(travaux):
                i = travaux[futur]
                quoi = ("le rendu final" if i is None
                        else f"le tracé de {fiches[i]['prenom']}")
                try:
                    futur.result()
                except Exception as erreur:
                    print(f"   (export, {quoi} : {erreur})")
                    avertissements.append(f"{quoi} est impossible ({erreur}).")
                    avancer(f"Échec : {quoi}")
                    continue
                if i is None:
                    compose_ok = True
                    avancer(f"Rendu final {libelle_forme(forme, nb)} prêt")
                else:
                    fiches[i]["trace"] = fiches[i]["_trace"]
                    avancer(f"{fiches[i]['prenom']} : tracé {nom_style} prêt")

        if compose and not compose_ok:
            compose = None                    # rien de faux dans le zip

        # 4. récapitulatif, puis la liste EXACTE de ce qui part dans le zip
        details = []
        relatifs = [NOM_RECAPITULATIF]
        if compose:
            relatifs += [f"{compose}.svg", f"{compose}.png"]
        for fiche in fiches:
            fichiers = []
            if fiche["photo"]:
                fichiers.append((fiche["photo"], "photo de l'empreinte, recadrée"))
            if fiche["trace"]:
                fichiers += [(fiche["trace"][0], role_svg(style)),
                             (fiche["trace"][1], "pour regarder")]
            relatifs += [f"{fiche['prenom']}/{f}" for f, _ in fichiers]
            details.append((fiche["nom"], fiche["prenom"], fichiers,
                            fiche["completer"]))
        with open(os.path.join(base, NOM_RECAPITULATIF), "w",
                  encoding="utf-8-sig", newline="\r\n") as f:
            f.write(recapitulatif(cmd, nom, compose, details, avertissements))

        avancer("Création du zip…", terminee=False)
        zip_provisoire = os.path.join(chantier, "export.zip")
        _zipper(base, nom, relatifs, zip_provisoire)

        # 5. mise en place : l'ancien export part dans le chantier (jeté avec)
        dossier_final = os.path.join(exports, nom)
        zip_final = os.path.join(exports, nom + ".zip")
        if os.path.lexists(dossier_final):
            os.rename(dossier_final, os.path.join(chantier, "ancien"))
        os.rename(base, dossier_final)
        os.replace(zip_provisoire, zip_final)
    finally:
        shutil.rmtree(chantier, ignore_errors=True)

    return {"dossier": dossier_final, "zip": zip_final,
            "resume": resume(cmd), "nom": nom,
            "fichiers": [os.path.join(dossier_final, *r.split("/"))
                         for r in relatifs],
            "forme": forme if compose else None, "style": style,
            "style_defaut": not cmd.get("style"),
            "avertissements": avertissements}
