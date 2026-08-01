#!/usr/bin/env python3
"""
moteur_live.py — moteur SANS fenêtre pour l'app Mac « Empreinte ».

L'app SwiftUI le lance en tâche de fond et lui parle en texte simple :
  - elle envoie des commandes sur l'entrée standard, une par ligne ;
  - le moteur répond par des lignes JSON sur la sortie standard.

Toute la vraie logique (série, décodage, fusion, complétion, SVG) est
réutilisée telle quelle depuis capture_empreinte.py et
fusionner_empreinte.py : ce fichier n'est qu'un aiguilleur.

Commandes reconnues (une par ligne) :
    PORTS                 -> liste des ports série disponibles
    CONNECT <port>        -> ouvre le port et réveille l'ESP32
    SCAN                  -> un scan, raccordé à la mosaïque en cours
    RESET                 -> repart d'une mosaïque vide
    FINAL                 -> rendu final (PNG + SVG), renvoie les chemins
    LED <couleur>         -> pilote la LED RGB de l'ESP32
    QUIT                  -> arrête le moteur

    COMMANDE <nom>        -> crée une commande client (dossier créé aussitôt)
    EMPREINTE <prénom>    -> commence à scanner une personne
    VALIDER <crop…>       -> range l'empreinte scannée (écrite sur disque)
    RECADRER <i>          -> rouvre le cadrage de l'empreinte i
    SUPPRIMER <i>         -> retire l'empreinte i (disque compris)
    APERCU <forme> <style>      -> aperçu du rendu composé
    ENREGISTRER <forme> <style> -> rendu définitif dans <commande>/rendus/

    DOSSIER [chemin]      -> lit / change le dossier de stockage
    COMMANDES             -> liste les commandes rangées sur le disque
    OUVRIR <id>           -> recharge une commande complète
    RENOMMER <nom>        -> renomme la commande courante
    RENOMMER_EMPREINTE <i> <nom>
    SUPPRIMER_COMMANDE <id>     -> vers <dossier>/.corbeille/
    AJUSTER <i> <dx> <dy> <angle> -> retouche le placement dans le lobe
    EMPREINTE_APERCU <i>  -> PNG de la photo normalisée de l'empreinte i
    EXPORTER              -> zip de la commande + résumé pour un mail

Événements renvoyés (JSON, champ "event") :
    ready, ports, connected, status, bouton, touche, scan_ok, scan_rejete,
    scan_fail, reset, final, commande, commandes, dossier, empreinte_debut,
    empreinte_validee, recadrer, ajuste, empreinte_apercu, apercu_pret,
    compose, exporte, error, bye

Tout est rangé sur le disque par magasin_commandes.py — voir PROTOCOLE_V2.md.
"""

import json
import os
import shutil
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# La sortie standard est réservée au JSON : on renvoie tous les print()
# des modules réutilisés (diagnostics) vers l'erreur standard.
_sortie_json = sys.stdout
sys.stdout = sys.stderr


def envoyer(**champs):
    _sortie_json.write(json.dumps(champs, ensure_ascii=False) + "\n")
    _sortie_json.flush()


def _surveiller_parent(parent):
    """L'app qui nous a lancés est morte (fenêtre fermée, Cmd-Q, arrêt forcé,
    plantage) : le moteur n'a plus aucune raison de vivre. Sans ce garde-fou
    il survit — la fin de l'entrée standard ne le réveille pas quand il est
    bloqué dans un appel système (ouverture d'un port série, autorisation
    macOS d'accès à un dossier). On retrouvait ainsi des moteurs orphelins,
    un par lancement, qui gardent le capteur occupé pour l'app suivante.
    La surveillance démarre AVANT les imports lourds : c'est justement
    pendant ceux-là que le blocage peut arriver."""
    while True:
        time.sleep(1.0)
        if os.getppid() != parent:
            port = globals().get("sp")
            try:
                if port is not None:
                    port.close()
            except Exception:
                pass
            os._exit(0)


threading.Thread(target=_surveiller_parent, args=(os.getppid(),),
                 daemon=True).start()

try:
    import numpy as np
    import capture_empreinte as cap
    import fusionner_empreinte as fus
    import formes as frm
    import magasin_commandes as mag
except Exception as erreur:                       # dépendances manquantes
    envoyer(event="error", fatal=True, raison=(
        f"Modules Python manquants ({erreur}). Lance une fois :\n"
        "  pip3 install pyserial numpy opencv-python scipy scikit-image "
        "fingerprint-enhancer"))
    sys.exit(1)

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    serial = None


sp = None
session = fus.SessionFusion()
APERCU = os.path.join(cap.DOSSIER_PHOTOS, "_apercu_live.png")

# Commande en cours (voir magasin_commandes.commande_vide) : un nom, un
# dossier sur le disque, et une liste d'empreintes {nom, mosaïque, crop,
# completer, ajust}. Tant qu'aucun dossier n'a été créé, id vaut None.
commande = mag.commande_vide()
personne = ""                                     # prénom en cours de scan
edition_index = None                              # empreinte en cours de re-cadrage
DOSSIER_APERCUS = os.path.join(cap.DOSSIER_PHOTOS, "_apercus")
os.makedirs(DOSSIER_APERCUS, exist_ok=True)
apercus = {}                                      # "forme|style" -> {svg, png}


def _vider_apercus():
    apercus.clear()


def _migration_douce():
    """L'ancien dossier commandes/ du projet ne sert plus à rien : les SVG
    déjà produits y restent tels quels, on ne migre rien et surtout on ne
    plante pas si le dossier est absent ou illisible."""
    ancien = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "commandes")
    try:
        if os.path.isdir(ancien):
            vieux = [f for f in os.listdir(ancien) if f.lower().endswith(".svg")]
            if vieux:
                print(f"   ({len(vieux)} ancien(s) SVG dans {ancien} : ignorés)")
    except Exception as erreur:
        print(f"   (ancien dossier commandes/ ignoré : {erreur})")


# --- bouton physique + LEDs de l'ESP32 -----------------------------------
verrou_serie = threading.Lock()      # un seul lecteur du port à la fois
ecoute_bouton = threading.Event()    # actif = on guette le bouton (hors scan)


def led(mot):
    """Change la couleur de la LED RGB de l'ESP32 (purement décoratif)."""
    if sp is None:
        return
    try:
        with verrou_serie:
            sp.write(f"LED {mot}\n".encode("ascii"))
    except Exception:
        pass


def _ecouteur_bouton():
    """Guette l'appui sur le bouton quand aucun scan n'est en cours."""
    while True:
        if sp is None or not ecoute_bouton.is_set():
            time.sleep(0.1)
            continue
        ligne = ""
        try:
            with verrou_serie:
                if not ecoute_bouton.is_set():
                    continue
                ligne = sp.readline().decode("ascii", errors="ignore").strip()
        except Exception:
            time.sleep(0.2)
            continue
        if ligne.startswith("<BOUTON>"):
            envoyer(event="bouton")
        elif ligne.startswith("<TOUCHE>"):
            envoyer(event="touche")      # doigt posé : scan immédiat


def _nom_fichier(texte):
    """Nom de fichier sûr à partir d'un nom libre."""
    garde = "".join(c if c.isalnum() or c in " -_" else "_" for c in texte)
    return "_".join(garde.split()).strip("_") or "commande"


def mosaique_session(sess):
    """Mosaïque niveaux de gris (recadrée) de la session, ou None."""
    if sess.nb_posees == 0:
        return None
    import cv2
    return cv2.medianBlur(sess._recadrer(sess.image_actuelle()), 3)


def ports_disponibles():
    ports = []
    if serial is not None:
        for p in serial.tools.list_ports.comports():
            typique = any(m in p.device for m in
                          ("usbserial", "SLAB", "wchusbserial", "usbmodem"))
            ports.append({"device": p.device,
                          "nom": p.description or p.device,
                          "typique": typique})
    # les plus probables (ESP32) d'abord
    ports.sort(key=lambda x: not x["typique"])
    return ports


def connecter(port):
    global sp
    if serial is None:
        envoyer(event="error", raison="pyserial n'est pas installé")
        return
    if not port:
        auto = cap.trouver_port()
        if not auto:
            envoyer(event="error", raison="Aucun ESP32 trouvé. Branche-le en USB.")
            return
        port = auto
    if sp is not None:
        try:
            sp.close()
        except Exception:
            pass
    try:
        sp = serial.Serial(port, cap.BAUD, timeout=1)
    except Exception as erreur:
        envoyer(event="error", raison=f"Port {port} inaccessible : {erreur}")
        return
    # redémarre la carte puis récupère ses messages de démarrage
    try:
        sp.dtr = False
        sp.rts = True
        time.sleep(0.1)
        sp.rts = False
    except Exception:
        pass
    messages = []
    debut = time.time()
    capteur_ok = None
    while time.time() - debut < 10:            # le boot + test capteur prend du temps
        ligne = sp.readline().decode("ascii", errors="ignore").strip()
        if ligne.startswith("#"):
            txt = ligne[1:].strip()
            messages.append(txt)
            if "detecte" in txt.lower():
                capteur_ok = True
                break                          # inutile d'attendre plus
            if "introuvable" in txt.lower():
                capteur_ok = False
                break
    ecoute_bouton.set()                      # on guette le bouton physique
    led("PRET" if capteur_ok else "MUET")
    envoyer(event="connected", port=port, messages=messages,
            capteur=capteur_ok)


def faire_scan():
    if sp is None:
        envoyer(event="scan_fail", raison="Pas encore connecté au capteur.")
        return
    envoyer(event="status", texte="Scan en cours — garde le doigt bien appuyé")
    ecoute_bouton.clear()                    # le scan lit le port tout seul
    with verrou_serie:
        resultat = cap.lancer_scan(sp)
    if resultat is None:
        ecoute_bouton.set()
        envoyer(event="scan_fail",
                raison="Scan raté — repose le doigt bien à plat et réessaie.")
        return
    pixels, largeur, hauteur = resultat
    brute = np.frombuffer(bytes(pixels), np.uint8).reshape(hauteur, largeur)
    envoyer(event="status", texte="Raccordement à la mosaïque…")
    led("TRAVAIL")                           # violet : le Mac calcule
    try:
        raccordee = session.ajouter(brute)
    except Exception as erreur:
        led("ERREUR")
        ecoute_bouton.set()
        envoyer(event="scan_fail", raison=f"Erreur pendant le raccord : {erreur}")
        return
    led("OK" if raccordee else "ERREUR")
    ecoute_bouton.set()
    if raccordee:
        try:
            session.apercu(APERCU)
        except Exception as erreur:
            envoyer(event="error", raison=f"aperçu : {erreur}")
        envoyer(event="scan_ok", apercu=APERCU, poses=session.nb_posees,
                horodatage=int(time.time() * 1000))
    else:
        envoyer(event="scan_rejete", poses=session.nb_posees,
                raison="Pas raccordé — repose le doigt en recouvrant "
                       "la zone déjà scannée.")


def reinitialiser():
    global session
    session = fus.SessionFusion()
    try:
        if os.path.exists(APERCU):
            os.remove(APERCU)
    except Exception:
        pass
    envoyer(event="reset")


def rendu_final():
    if session.nb_posees == 0:
        envoyer(event="scan_fail", raison="Aucune pose à enregistrer.")
        return
    envoyer(event="status", texte="Rendu final aux filtres de Gabor… (~1 min)")
    try:
        chemin = fus.finaliser_et_enregistrer(session)
    except Exception as erreur:
        envoyer(event="error", raison=f"Rendu final : {erreur}")
        return
    svg = None
    if chemin:
        candidat = os.path.splitext(chemin)[0] + ".svg"
        if os.path.exists(candidat):
            svg = candidat
    envoyer(event="final", png=chemin, svg=svg, poses=session.nb_posees)


# --- commande client : mémoire <-> disque --------------------------------

def _assurer_dossier():
    """Pose la commande courante sur le disque si ce n'est pas déjà fait
    (cas d'une app qui valide une empreinte sans avoir créé de commande).
    Renvoie True si un dossier existe désormais."""
    global commande
    if commande.get("id"):
        return True
    avant = commande
    try:
        commande = mag.creer(avant["nom"], avant["empreintes"])
    except Exception as erreur:
        envoyer(event="error", raison=f"Dossier de la commande : {erreur}")
        return False
    # ce qui avait déjà été choisi en mémoire ne doit pas être perdu
    commande["forme"] = avant.get("forme")
    commande["style"] = avant.get("style")
    return True


def _persister(complet=True):
    """Écrit la commande sur le disque. complet=False -> commande.json seul
    (aucune image n'a changé). Ne fait rien tant qu'il n'y a pas de dossier."""
    if not commande.get("id"):
        return
    try:
        if complet:
            mag.synchroniser(commande)
        else:
            mag.ecrire_json(commande)
    except Exception as erreur:
        envoyer(event="error", raison=f"Enregistrement sur disque : {erreur}")


def _empreintes_json():
    """Description des empreintes pour l'événement `commande`."""
    liste = []
    for e in commande["empreintes"]:
        liste.append({"nom": e.get("nom") or "",
                      "crop": list(e["crop"]) if e.get("crop") else None,
                      "completer": bool(e.get("completer", True)),
                      "ajust": dict(e.get("ajust") or mag.AJUST_NEUTRE),
                      "dossier": e.get("_dossier"),
                      "photo": e.get("photo")})
    return liste


def envoyer_commande():
    """Événement `commande` : l'état complet de la commande courante."""
    envoyer(event="commande", id=commande.get("id"), nom=commande["nom"],
            dossier=commande.get("dossier"),
            forme=commande.get("forme"), style=commande.get("style"),
            cree_le=commande.get("cree_le"),
            modifie_le=commande.get("modifie_le"),
            noms=[e.get("nom") or "" for e in commande["empreintes"]],
            empreintes=_empreintes_json())


def envoyer_liste():
    """Événement `commandes` : tout ce qui est rangé sur le disque."""
    try:
        envoyer(event="commandes", liste=mag.lister(),
                dossier=mag.lire_dossier())
    except Exception as erreur:
        envoyer(event="error", raison=f"Liste des commandes : {erreur}")


def envoyer_validee():
    # `empreintes` (état complet) en plus de `noms` : après une SUPPRIMER au
    # milieu, les index glissent et l'app doit relire crop/completer/ajust —
    # les reprendre position par position les décalerait d'un cran.
    envoyer(event="empreinte_validee",
            noms=[e.get("nom") or "" for e in commande["empreintes"]],
            total=len(commande["empreintes"]),
            photos=[e.get("photo") for e in commande["empreintes"]],
            empreintes=_empreintes_json())


def dossier_stockage(argument):
    """DOSSIER [chemin] : lit ou change le dossier de rangement."""
    argument = (argument or "").strip()
    try:
        chemin = mag.ecrire_dossier(argument) if argument else mag.lire_dossier()
    except Exception as erreur:
        envoyer(event="error", raison=f"Dossier de stockage : {erreur}")
        return
    envoyer(event="dossier", chemin=chemin)
    if argument:
        envoyer_liste()


def nouvelle_commande(nom):
    """COMMANDE <nom> : nouvelle commande, dossier créé immédiatement."""
    global commande, personne, session, edition_index
    personne = ""
    edition_index = None
    session = fus.SessionFusion()
    _vider_apercus()
    try:
        commande = mag.creer(nom or "Commande")
    except Exception as erreur:
        commande = mag.commande_vide(nom)
        envoyer(event="error", raison=f"Dossier de la commande : {erreur}")
    envoyer_commande()


def ouvrir_commande(identifiant):
    """OUVRIR <id> : recharge une commande (mosaïques relues des PNG)."""
    global commande, personne, session, edition_index
    identifiant = (identifiant or "").strip()
    if not identifiant:
        envoyer(event="error", raison="usage : OUVRIR <id>")
        return
    try:
        rechargee = mag.lire(identifiant)
    except Exception as erreur:
        envoyer(event="error", raison=f"Ouverture : {erreur}")
        return
    commande = rechargee
    personne = ""
    edition_index = None
    session = fus.SessionFusion()
    _vider_apercus()
    envoyer_commande()


def renommer_commande(nom):
    """RENOMMER <nom> : le dossier garde son id, seul le json change."""
    nom = (nom or "").strip()
    if not nom:
        envoyer(event="error", raison="usage : RENOMMER <nom>")
        return
    commande["nom"] = nom
    _persister(complet=False)
    envoyer_commande()


def renommer_empreinte(argument):
    """RENOMMER_EMPREINTE <i> <nom> : le dossier NN_<slug> suit le prénom.
    L'image ne change pas : inutile de vider le cache d'aperçus."""
    morceaux = (argument or "").split(" ", 1)
    if len(morceaux) < 2 or not morceaux[1].strip():
        envoyer(event="error", raison="usage : RENOMMER_EMPREINTE <i> <nom>")
        return
    try:
        i = int(morceaux[0])
        commande["empreintes"][i]["nom"] = morceaux[1].strip()
    except (ValueError, IndexError):
        envoyer(event="error", raison="index d'empreinte invalide")
        return
    _persister()
    envoyer_commande()


def supprimer_commande(identifiant):
    """SUPPRIMER_COMMANDE <id> : direction .corbeille/ (jamais d'effacement)."""
    global commande
    identifiant = (identifiant or "").strip()
    try:
        mag.supprimer(identifiant)
    except Exception as erreur:
        envoyer(event="error", raison=f"Suppression : {erreur}")
        return
    if commande.get("id") == identifiant:             # c'était celle ouverte
        commande = mag.commande_vide()
        _vider_apercus()
        envoyer_commande()
    envoyer_liste()


def ajuster_empreinte(argument):
    """AJUSTER <i> <dx> <dy> <angle> : retouche le placement de l'empreinte
    dans son lobe (dx/dy en fraction du rayon de lobe, angle en degrés)."""
    morceaux = (argument or "").split()
    if len(morceaux) < 4:
        envoyer(event="error",
                raison="usage : AJUSTER <i> <dx> <dy> <angle>")
        return
    try:
        i = int(morceaux[0])
        ajust = {"dx": float(morceaux[1]), "dy": float(morceaux[2]),
                 "angle": float(morceaux[3])}
        commande["empreintes"][i]["ajust"] = ajust
    except (ValueError, IndexError):
        envoyer(event="error", raison="AJUSTER : index ou valeurs invalides")
        return
    _vider_apercus()                    # le rendu n'est plus à jour
    _persister(complet=False)
    envoyer(event="ajuste", index=i, ajust=ajust)


def apercu_empreinte(index):
    """EMPREINTE_APERCU <i> : photo normalisée + recadrée dans un PNG frais."""
    try:
        i = int(index)
        e = commande["empreintes"][i]
    except (ValueError, IndexError):
        envoyer(event="error", raison="index d'empreinte invalide")
        return
    import cv2
    horodatage = int(time.time() * 1000)
    prefixe = f"empreinte_{i}_"
    try:                                            # ménage des PNG précédents
        for fichier in os.listdir(DOSSIER_APERCUS):
            if fichier.startswith(prefixe):
                os.remove(os.path.join(DOSSIER_APERCUS, fichier))
    except Exception:
        pass
    png = os.path.join(DOSSIER_APERCUS, f"{prefixe}{horodatage}.png")
    try:
        cv2.imwrite(png, mag.photo_normalisee(e["mosaique"], e.get("crop")))
    except Exception as erreur:
        envoyer(event="error", raison=f"Aperçu d'empreinte : {erreur}")
        return
    envoyer(event="empreinte_apercu", index=i, png=png,
            personne=e.get("nom") or "", horodatage=horodatage)


def exporter_commande():
    """EXPORTER : zip du dossier + petit texte à coller dans un mail."""
    if not _assurer_dossier():
        return
    try:
        chemin_zip, texte = mag.exporter(commande)
    except Exception as erreur:
        envoyer(event="error", raison=f"Export : {erreur}")
        return
    envoyer(event="exporte", dossier=commande["dossier"], zip=chemin_zip,
            resume=texte, nom=commande["nom"], id=commande["id"])


def nouvelle_empreinte(nom):
    """Commence à scanner une nouvelle personne (remet la mosaïque à zéro)."""
    global personne, session, edition_index
    edition_index = None
    personne = nom or f"Empreinte {len(commande['empreintes']) + 1}"
    session = fus.SessionFusion()
    try:
        if os.path.exists(APERCU):
            os.remove(APERCU)
    except Exception:
        pass
    envoyer(event="empreinte_debut", personne=personne)


def valider_empreinte(argument=""):
    """Enregistre l'empreinte scannée (mosaïque + cadrage) dans la commande,
    ou met à jour le cadrage d'une empreinte en cours de re-cadrage.
    argument : "<cx> <cy> <hw> <hh> <completer>" (fractions + 0/1), optionnel."""
    global session, edition_index
    crop, completer = None, True
    parties = argument.split()
    if len(parties) >= 4:
        try:
            crop = tuple(float(x) for x in parties[:4])
        except ValueError:
            crop = None
    if len(parties) >= 5:
        completer = parties[4].lower() not in ("0", "false", "non", "off")

    if edition_index is not None:                 # re-cadrage d'une empreinte
        try:
            commande["empreintes"][edition_index]["crop"] = crop
            commande["empreintes"][edition_index]["completer"] = completer
        except IndexError:
            pass
        edition_index = None
        _vider_apercus()
        _persister()                              # photo.png suit le cadrage
        envoyer_validee()
        return

    mosaique = mosaique_session(session)
    if mosaique is None:
        envoyer(event="scan_fail", raison="Aucune pose pour cette empreinte.")
        return
    session = fus.SessionFusion()
    ajouter_empreinte(personne, mosaique, crop, completer)


def ajouter_empreinte(nom, mosaique, crop=None, completer=True):
    """Range une empreinte terminée dans la commande, et sur le disque."""
    commande["empreintes"].append({
        "nom": nom or f"Empreinte {len(commande['empreintes']) + 1}",
        "mosaique": mosaique, "crop": crop, "completer": completer,
        "ajust": dict(mag.AJUST_NEUTRE)})
    _vider_apercus()
    if _assurer_dossier():
        _persister()
    envoyer_validee()


def recadrer_empreinte(index):
    """Rouvre le cadrage d'une empreinte déjà enregistrée."""
    global edition_index
    try:
        i = int(index)
        e = commande["empreintes"][i]
    except (ValueError, IndexError):
        envoyer(event="error", raison="index d'empreinte invalide")
        return
    edition_index = i
    import cv2
    cv2.imwrite(APERCU, fus.normaliser_affichage(e["mosaique"]))
    crop = e.get("crop") or (0.5, 0.5, 0.5, 0.5)
    envoyer(event="recadrer", apercu=APERCU, personne=e["nom"],
            crop=list(crop), completer=e.get("completer", True),
            horodatage=int(time.time() * 1000))


def supprimer_empreinte(index):
    try:
        i = int(index)
        commande["empreintes"].pop(i)
    except (ValueError, IndexError):
        envoyer(event="error", raison="index d'empreinte invalide")
        return
    _vider_apercus()
    _persister()                    # le disque suit : dossiers renumérotés
    envoyer_validee()


def _generer_apercu(forme, style):
    """Génère (ou récupère du cache) le SVG + PNG d'aperçu pour forme/style."""
    cle = f"{forme}|{style}"
    if cle in apercus:
        return apercus[cle]
    empreintes = commande["empreintes"]
    mosaiques = [e["mosaique"] for e in empreintes]
    crops = [e.get("crop") for e in empreintes]
    completions = [e.get("completer", True) for e in empreintes]
    ajusts = [e.get("ajust") for e in empreintes]
    svg = os.path.join(DOSSIER_APERCUS, f"apercu_{forme}_{style}.svg")
    png = os.path.join(DOSSIER_APERCUS, f"apercu_{forme}_{style}.png")
    frm.composer(mosaiques, forme, style, svg, apercu_png=png,
                 crops=crops, completions=completions, ajusts=ajusts)
    apercus[cle] = {"svg": svg, "png": png}
    return apercus[cle]


def _majer_vignette(png):
    """Copie le dernier rendu en vignette.png dans le dossier de la commande."""
    if not commande.get("dossier"):
        return
    try:
        shutil.copyfile(png, os.path.join(commande["dossier"], "vignette.png"))
    except Exception as erreur:
        print(f"   (vignette non écrite : {erreur})")


def apercu_compose(argument):
    """APERCU <forme> <style> : génère un aperçu (PNG) — mis en cache."""
    parties = argument.split()
    if len(parties) < 2:
        envoyer(event="error", raison="usage : APERCU <forme> <style>")
        return
    forme, style = parties[0].lower(), parties[1].lower()
    if not commande["empreintes"]:
        envoyer(event="scan_fail", raison="Aucune empreinte dans la commande.")
        return
    deja = f"{forme}|{style}" in apercus
    if not deja:
        envoyer(event="status", texte=f"Génération de l'aperçu {forme} / {style}…")
        led("TRAVAIL")
    try:
        res = _generer_apercu(forme, style)
    except Exception as erreur:
        led("ERREUR")
        envoyer(event="error", raison=f"Aperçu : {erreur}")
        return
    if not deja:
        led("OK")
    # la forme et le style choisis font partie de la commande : on les garde
    commande["forme"], commande["style"] = forme, style
    if _assurer_dossier():
        _majer_vignette(res["png"])
        _persister(complet=False)
    envoyer(event="apercu_pret", png=res["png"], forme=forme, style=style,
            cache=deja, horodatage=int(time.time() * 1000))


def enregistrer_compose(argument):
    """ENREGISTRER <forme> <style> : rendu définitif dans <commande>/rendus/."""
    parties = argument.split()
    if len(parties) < 2:
        envoyer(event="error", raison="usage : ENREGISTRER <forme> <style>")
        return
    forme, style = parties[0].lower(), parties[1].lower()
    if not commande["empreintes"]:
        envoyer(event="scan_fail", raison="Aucune empreinte dans la commande.")
        return
    if not _assurer_dossier():
        return
    try:
        res = _generer_apercu(forme, style)
        dossier_rendus = os.path.join(commande["dossier"], "rendus")
        os.makedirs(dossier_rendus, exist_ok=True)
        base = f"{_nom_fichier(forme)}_{_nom_fichier(style)}"
        final = os.path.join(dossier_rendus, base + ".svg")
        final_png = os.path.join(dossier_rendus, base + ".png")
        shutil.copyfile(res["svg"], final)
        shutil.copyfile(res["png"], final_png)
    except Exception as erreur:
        led("ERREUR")
        envoyer(event="error", raison=f"Enregistrement : {erreur}")
        return
    led("OK")
    commande["forme"], commande["style"] = forme, style
    _majer_vignette(res["png"])
    _persister(complet=False)
    envoyer(event="compose", svg=final, png=final_png,
            dossier=commande["dossier"], forme=forme, style=style,
            nom=commande["nom"], id=commande["id"])


def injecter_empreinte(chemin):
    """_INJECTER <chemin.png> — commande de TEST, non documentée pour l'app.

    Charge un PNG niveaux de gris comme si une empreinte venait d'être
    scannée et validée (le prénom devient le nom du fichier). Sert à faire
    tourner tout le moteur sans capteur ni ESP32."""
    chemin = os.path.abspath(os.path.expanduser((chemin or "").strip()))
    import cv2
    mosaique = cv2.imread(chemin, cv2.IMREAD_GRAYSCALE)
    if mosaique is None:
        envoyer(event="error", raison=f"image illisible : {chemin}")
        return
    ajouter_empreinte(os.path.splitext(os.path.basename(chemin))[0], mosaique)


def boucle():
    threading.Thread(target=_ecouteur_bouton, daemon=True).start()
    _migration_douce()
    try:
        dossier_stock = mag.lire_dossier()            # créé s'il n'existe pas
    except Exception as erreur:
        dossier_stock = None
        print(f"   (dossier de stockage indisponible : {erreur})")
    envoyer(event="ready", ports=ports_disponibles(), dossier=cap.DOSSIER_PHOTOS,
            dossier_commandes=dossier_stock)
    for ligne in sys.stdin:
        texte = ligne.strip()
        if not texte:
            continue
        morceaux = texte.split(" ", 1)
        verbe = morceaux[0].upper()
        argument = morceaux[1].strip() if len(morceaux) > 1 else ""
        try:
            if verbe == "PORTS":
                envoyer(event="ports", ports=ports_disponibles())
            elif verbe == "CONNECT":
                connecter(argument)
            elif verbe == "SCAN":
                faire_scan()
            elif verbe == "RESET":
                reinitialiser()
            elif verbe == "FINAL":
                rendu_final()
            elif verbe == "COMMANDE":
                nouvelle_commande(argument)
            elif verbe == "EMPREINTE":
                nouvelle_empreinte(argument)
            elif verbe == "VALIDER":
                valider_empreinte(argument)
            elif verbe == "SUPPRIMER":
                supprimer_empreinte(argument)
            elif verbe == "RECADRER":
                recadrer_empreinte(argument)
            elif verbe == "LED":                  # l'app pilote les couleurs
                led(argument.upper() or "PRET")
            elif verbe == "APERCU":
                apercu_compose(argument)
            elif verbe == "ENREGISTRER":
                enregistrer_compose(argument)
            elif verbe == "DOSSIER":
                dossier_stockage(argument)
            elif verbe == "COMMANDES":
                envoyer_liste()
            elif verbe == "OUVRIR":
                ouvrir_commande(argument)
            elif verbe == "RENOMMER":
                renommer_commande(argument)
            elif verbe == "RENOMMER_EMPREINTE":
                renommer_empreinte(argument)
            elif verbe == "SUPPRIMER_COMMANDE":
                supprimer_commande(argument)
            elif verbe == "AJUSTER":
                ajuster_empreinte(argument)
            elif verbe == "EMPREINTE_APERCU":
                apercu_empreinte(argument)
            elif verbe == "EXPORTER":
                exporter_commande()
            elif verbe == "_INJECTER":            # test sans capteur
                injecter_empreinte(argument)
            elif verbe == "QUIT":
                break
            else:
                envoyer(event="error", raison=f"commande inconnue : {verbe}")
        except Exception as erreur:
            envoyer(event="error", raison=str(erreur))
    if sp is not None:
        try:
            sp.close()
        except Exception:
            pass
    envoyer(event="bye")


if __name__ == "__main__":
    try:
        boucle()
    except KeyboardInterrupt:
        pass
