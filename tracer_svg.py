#!/usr/bin/env python3
"""
tracer_svg.py — transforme l'image de crêtes (sortie Gabor : crêtes noires
sur fond blanc) en dessin vectoriel SVG, comme un relevé tracé à la main :
des traits continus et lisses qui suivent les lignes de l'empreinte, et
aucun trait n'en touche un autre.

Logique :
  1. squelette des crêtes (lignes de 1 pixel d'épaisseur), ébarbé de ses
     petites barbes parasites ;
  2. à chaque carrefour, les deux branches qui se prolongent le mieux sont
     appariées : une crête traverse la bifurcation d'un SEUL trait, la
     branche latérale reste un trait séparé qui vient s'y attacher ;
  3. les crêtes cassées sont pontées : deux bouts libres qui se font face
     (alignés, décalage latéral faible, écart jusqu'à ~2 périodes) sont
     reliés par un raccord de Hermite — une courbe, jamais un coude ;
  4. les micro-traits sont d'abord rattrapés (pontage large, absorption des
     doublons), et seulement ce qui reste vraiment isolé est supprimé ;
  5. lissage, raccourcissement des bouts (les traits ne se touchent pas),
     export en courbes de Bézier.

Utilisation :
    python3 tracer_svg.py photos/xxx_cretes.png [sortie.svg]
"""

import os
import sys

import cv2
import numpy as np

# --- TOUT EST À L'ÉCHELLE DE L'INTERLIGNE ----------------------------------
# Une empreinte de BÉBÉ a des crêtes environ deux fois plus serrées que celle
# d'un adulte (interligne ~8-12 px là où l'adulte est à ~20-24 px sur le même
# canevas). Une tolérance exprimée en PIXELS ABSOLUS vaut alors le double en
# proportion et détruit le tracé : 6 px d'écart mini, c'est 0,29 interligne
# chez l'adulte mais 0,75 interligne chez le bébé — le mode « sans contact »
# mangerait presque tout. Chaque réglage ci-dessous est donc donné en
# PÉRIODES de crête ; la valeur en pixels qui l'accompagne n'est plus qu'un
# PLANCHER anti-bruit (le capteur, lui, ne devient pas plus fin), jamais une
# valeur de travail. Les valeurs sont calées pour redonner EXACTEMENT les
# anciennes tolérances sur l'interligne adulte médian (21 px).
PAS_PERIODES = 0.15       # espacement des points le long d'un trait, en
PAS_PLANCHER = 1.0        # périodes, borné en px. 3 px fixes, c'était un demi
PAS_ECHANTILLON = 3.0     # interligne sur des crêtes fines : le trait ne
                          # pouvait plus suivre la courbe du cœur, et les
                          # reculs de ecarter_bouts se faisaient par bonds
                          # d'un demi interligne. Le PLAFOND reste 3 px : le
                          # capteur ne devient pas plus fin quand les crêtes
                          # sont plus grosses, échantillonner plus large ne
                          # ferait que couper les virages.
PONT_PLANCHER = 8.0       # plancher px de la portée de pontage. 18 px fixes
                          # valaient 3 interlignes sur une empreinte de bébé :
                          # le pont enjambait deux crêtes.
DIST_RACCORD = 18.0       # portée de recoudre() seul (px) — voir recoudre()
ANGLE_RACCORD = 40.0      # désalignement maxi pour recoudre (degrés) : un
                          # angle, donc sans dimension, il reste absolu
LONGUEUR_PLANCHER = 10.0  # plancher px du « trop court pour être une crête » ;
                          # la vraie mesure est LONGUEUR_MINI_PERIODES. Les
                          # 22 px fixes d'avant valaient 2,75 interlignes sur
                          # des crêtes fines : de vraies crêtes étaient jetées.
ROGNAGE_PERIODES = 0.12   # raccourcissement de chaque extrémité, en périodes,
ROGNAGE_PLANCHER = 1.2    # borné en px. 0,12 × 21 = 2,5 px : la valeur
ROGNAGE_BOUTS = 2.5       # historique de l'adulte, gardée comme PLAFOND — ce
                          # rognage n'est qu'un blanc de courtoisie au bout du
                          # trait, l'agrandir sur de grosses crêtes ne
                          # servirait qu'à raccourcir le dessin.
LARGEUR_PERIODES = 0.125  # épaisseur du trait SVG, en périodes, avec ce
LARGEUR_PLANCHER = 1.2    # plancher px (en dessous, plus rien à graver).
LARGEUR_TRAIT = 2.6       # 0,125 × 21 = 2,6 px : l'épaisseur historique, qui
                          # reste celle de repli quand l'interligne est
                          # inconnu. Un trait épais sur des crêtes fines fait
                          # fusionner deux crêtes voisines à la gravure —
                          # c'est le défaut que l'on veut éviter.
COURBURE_RAYON = 220.0    # ° par période : au-delà = demi-tour en épingle.
                          # La courbure d'un cœur d'empreinte est en 1/rayon
                          # et le rayon suit l'interligne : sur des crêtes
                          # deux fois plus serrées la courbure DOUBLE. Un
                          # seuil fixe en °/px découpait le cœur d'un bébé en
                          # confettis. 220/21 = 10,5 °/px chez l'adulte.
COURBURE_MAX = 11.0       # (valeur historique adulte, gardée pour référence)
AUTORISER_CONTACT = True   # True = les bifurcations se touchent (comme le Gabor)

# Gouttes / spirales : un trait qui revient se coller à lui-même.
PINCE_PERIODES = 0.75     # deux points du trait plus proches que ça (en
DIST_PINCE = 14.0         # périodes) = pincement ; DIST_PINCE reste un
                          # PLAFOND px (une grande empreinte n'a pas besoin
                          # d'un détecteur de goutte de 25 px de portée)
PINCE_PLANCHER = 3.0      # ...et ce plancher px évite de couper sur du bruit
SEPARATION_PERIODES = 2.5 # ...s'ils sont éloignés d'au moins ça LE LONG du
SEPARATION_PLANCHER = 10.0  # trait (en périodes), avec ce plancher px
SEPARATION_MINI = 24.0    # (valeur historique, défaut de defaire_gouttes)
# Prolongement doux des bouts, sans jamais toucher un voisin.
EXT_PERIODES = 0.35       # allongement maxi d'un bout, en périodes, borné en
EXT_PLANCHER = 2.0        # px. 7 px, la valeur historique, reste le PLAFOND :
EXT_MAX = 7.0             # ce prolongement ne fait que refermer visuellement
                          # une coupure ; l'allonger encore sur de grosses
                          # crêtes ne gagne rien et lui laisse le temps de
                          # s'enrouler (le trait finissait par se croiser).
ECART_PERIODES = 0.30     # DISTANCE MINI ENTRE DEUX TRAITS, en périodes —
ECART_PLANCHER = 2.0      # c'est la promesse du mode « sans contact » — avec
ECART_MINI = 6.0          # ce plancher px (sous 2 px deux traits sont dans le
                          # même pixel quel que soit l'interligne). 6 px, la
                          # valeur historique, valait 0,29 interligne chez
                          # l'adulte (d'où 0,30) mais 0,75 chez le bébé : le
                          # mode « sans contact » lui mangeait tout le dessin.
                          # Elle reste le repli quand l'interligne est inconnu.
EXT_VIRAGE = 30.0         # virage maxi d'un prolongement (°) : il suit la
                          # courbure des crêtes, mais ne s'enroule pas

# --- Continuité des crêtes (traversée des carrefours, pontage des coupures) ---
# Tout ce qui suit est exprimé en PÉRIODE de crête (interligne mesuré sur
# l'image) : le tracé s'adapte tout seul à la taille de l'empreinte.
ANGLE_JONCTION = 48.0     # écart maxi à la ligne droite pour traverser un carrefour (°)
ANGLE_PONT = 40.0         # désalignement maxi pour ponter une coupure (°)
PONT_PORTEE = 2.0         # portée du pontage, en périodes de crête
PONT_DECALAGE = 0.58      # décalage latéral maxi d'un pont, en périodes.
                          # Attention : ce décalage vaut écart × sin(angle),
                          # il BRIDE donc l'angle dès que la coupure est large
                          # (à 2 périodes d'écart il ne laisse plus que 17°).
                          # Nettement en deçà d'un interligne : le bout
                          # d'arrivée reste dans le couloir de la crête de
                          # départ, jamais sur la crête voisine.
MARGE_VOISINE = 0.12      # un pont ne doit pas frôler un autre trait de plus
                          # près que ça (en périodes) : deux crêtes ne se
                          # croisent jamais
TANGENTE_LONGUE = 1.35    # 2e base de mesure de la direction d'un bout, en
                          # périodes : le squelette se termine souvent par un
                          # petit crochet qui fausse la tangente courte de
                          # plusieurs dizaines de degrés (voir ponter_coupures)
SOUDURE_BIFURCATION = 0.52  # portée de la soudure des Y (mode contact), en
SOUDURE_MINI = 3.0          # périodes, bornée en pixels : 11 px fixes
SOUDURE_MAXI = 15.0         # laissaient un trou visible sur une grande
                            # empreinte et suffisaient à sauter sur la crête
                            # voisine sur une petite. Le plancher est passé de
                            # 6 à 3 px : 6 px valaient 0,75 interligne sur des
                            # crêtes de bébé — la soudure allait chercher la
                            # crête d'à côté au lieu de la branche du Y.
# --- Champ d'orientation : c'est LUI qui fait foi ---------------------------
# La tangente terminale d'une crête coupée est bruitée (le squelette finit
# souvent par un petit crochet). L'orientation locale des crêtes, mesurée sur
# l'IMAGE par un tenseur de structure, est robuste : c'est elle qui décide si
# un pont prolonge la crête ou saute sur la voisine.
CHAMP_LISSAGE = 0.55      # lissage du tenseur de structure, en périodes
CHAMP_PORTEE = 1.2        # longueur de lecture du champ à un bout, en périodes
COHERENCE_MINI = 0.22     # en deçà, le champ n'est pas fiable : on s'en passe
ANGLE_CHAMP = 56.0        # écart maxi entre un pont et l'orientation locale
                          # des crêtes (°). Un pont plus oblique que ça ne
                          # prolonge pas une crête : il en rejoint une autre.
# --- Coupure rectiligne (couture de mosaïque) : appariement ORDONNÉ ---------
COUTURE_MINI = 5          # nb mini de ponts alignés pour parler de coupure
COUTURE_BANDE = 0.55      # demi-largeur de la bande de coupure, en périodes
COUTURE_ETENDUE = 3.0     # longueur mini d'une coupure, en périodes
COUTURE_PARALLELE = 45.0  # dispersion angulaire maxi des ponts d'une coupure
COUTURE_SAUT = 0.55       # coût d'un bout laissé sans partenaire (le coût
                          # d'un pont est normalisé entre 0 et 1 : deux sauts
                          # coûtent plus qu'un pont, l'appariement complet est
                          # donc préféré — chaque crête reprend la sienne)
COUTURE_LARGE = 1.7       # dans une coupure REPÉRÉE, le décalage latéral
                          # admis est élargi de ce facteur : le déplacement y
                          # est connu (il est commun à toute la famille), on
                          # n'a plus besoin du garde-fou aveugle
COUTURE_TOLERANCE = 0.45  # écart maxi (en périodes) entre un pont et le
                          # déplacement commun de sa coupure : au-delà, ce
                          # pont ne vise pas la crête que désigne la couture
COUTURE_VOTE = 0.22       # finesse du vote qui mesure ce déplacement, en
                          # périodes. Doit rester FIN : les deux réponses
                          # possibles (sa crête / la voisine) ne sont
                          # distantes que d'un interligne, un vote trop large
                          # trouverait son maximum ENTRE les deux et les
                          # mélangerait — c'est précisément le décalage d'un
                          # cran qu'on veut interdire.
COUTURE_ACCORD = 1.2      # poids du désaccord d'un pont avec le déplacement
                          # DOMINANT de sa coupure (en périodes d'écart). Une
                          # couture décale toutes les crêtes de la MÊME
                          # quantité : un pont qui s'en écarte vise la voisine
SOUDURE_LATERALE = 0.28   # décalage latéral maxi d'une soudure de Y, en
                          # périodes : au-delà on souderait sur la crête
                          # d'à côté (une coupure n'est pas une bifurcation)
RATTRAPAGE_PORTEE = 2.4   # portée du 2e pontage, réservé aux traits courts
RATTRAPAGE_ANGLE = 52.0   # désalignement maxi de ce 2e pontage (°)
BARBE_MAXI = 0.55         # barbe du squelette à retirer, en périodes
DOUBLON_ECART = 0.38      # un court trait entièrement à cette distance (en
                          # périodes) d'un autre est un doublon : absorbé
LONGUEUR_MINI_PERIODES = 2.0  # aucun trait final plus court que ça (en périodes)
PORTEE_TANGENTE = 0.55    # longueur de mesure d'une tangente, en périodes
PORTEE_PLANCHER = 4.0     # ...avec ce plancher px : en deçà de 4 px on ne lit
                          # plus une direction mais le crénelage du squelette.
                          # 7 px valaient plus d'un interligne sur des crêtes
                          # de bébé : la tangente d'un bout y moyennait tout un
                          # virage de crête au lieu de sa direction locale.
PERIODE_DEFAUT = 14.0     # période de repli si la mesure échoue (px)
ANNEAU_MINI = 24          # nb mini de cases du spectre dans un anneau pour
                          # qu'il compte (voir periode_cretes) : en dessous on
                          # ne mesure plus les crêtes mais la forme du doigt


def longueur(points):
    if len(points) < 2:
        return 0.0
    return float(np.linalg.norm(np.diff(points, axis=0), axis=1).sum())


# --- Réglages dérivés de l'interligne --------------------------------------
# Un seul endroit où l'on passe des « périodes » aux pixels : le tracé d'une
# empreinte de bébé est alors exactement celui d'un adulte, à l'échelle près.

def largeur_trait_pour(periode):
    """Épaisseur du trait SVG (px) pour cet interligne. Le trait garde la même
    proportion de l'interligne à toutes les tailles : lisible et gravable sur
    une crête d'adulte comme sur une crête de bébé, sans jamais que deux
    crêtes voisines se rejoignent sous l'épaisseur du trait."""
    return float(max(LARGEUR_PLANCHER, LARGEUR_PERIODES * float(periode)))


def ecart_mini_pour(periode):
    """Distance mini garantie entre deux traits différents (px). C'est la
    promesse du mode « sans contact » ; en périodes elle ne bouge pas."""
    return float(max(ECART_PLANCHER, ECART_PERIODES * float(periode)))


def pas_pour(periode):
    """Espacement des points le long d'un trait (px). Tout ce qui se compte en
    POINTS (fenêtre de lissage, fondu de soudure, base de _bout) devient ainsi
    proportionnel à l'interligne sans autre réglage — jusqu'au plafond de
    3 px, au-delà duquel on n'échantillonne pas plus large (voir
    PAS_ECHANTILLON)."""
    return float(np.clip(PAS_PERIODES * float(periode),
                         PAS_PLANCHER, PAS_ECHANTILLON))


DIRS_8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1),
          (0, 1), (1, -1), (1, 0), (1, 1)]


def _graphe_squelette(squelette):
    """Voisinage 8-connexe du squelette : {pixel (y, x) -> [voisins]}."""
    pixels = set(zip(*np.nonzero(squelette)))       # ensembles de (y, x)
    voisins = {}
    for p in pixels:
        y, x = p
        voisins[p] = [(y + dy, x + dx) for dy, dx in DIRS_8
                      if (y + dy, x + dx) in pixels]
    return pixels, voisins


def _clusters_noeuds(pixels, voisins):
    """Un carrefour du squelette fait souvent 2 ou 3 pixels collés : on les
    regroupe en UN seul carrefour. Sans ça, les branches sont séparées par
    des arêtes parasites de 1 px et la crête ne peut pas traverser proprement.
    Retourne {pixel -> n° de carrefour} et {n° -> centre (x, y)}."""
    noeuds = [p for p in pixels if len(voisins[p]) != 2]
    ensemble = set(noeuds)
    ident, centres = {}, {}
    for depart in noeuds:
        if depart in ident:
            continue
        k = len(centres)
        ident[depart] = k
        pile, membres = [depart], []
        while pile:
            q = pile.pop()
            membres.append(q)
            for r in voisins[q]:
                if r in ensemble and r not in ident:
                    ident[r] = k
                    pile.append(r)
        centres[k] = (float(np.mean([m[1] for m in membres])),
                      float(np.mean([m[0] for m in membres])))   # (x, y)
    return ident, centres


def _suivre_aretes(pixels, voisins, ident):
    """Découpe le squelette en branches reliant deux carrefours (`ident`).
    Retourne [(chaine de pixels, n° carrefour de départ, n° d'arrivée)] ;
    un n° vaut None pour une boucle fermée (aucun carrefour)."""
    chemins = []
    faites = set()                                  # arêtes dirigées déjà tracées
    for n in ident:
        for v in voisins[n]:
            if ident.get(v) == ident[n]:            # arête interne au carrefour
                continue
            if (n, v) in faites:
                continue
            faites.add((n, v))
            chaine = [n]
            prec, cur = n, v
            while True:
                chaine.append(cur)
                if cur in ident:                    # autre carrefour atteint
                    faites.add((cur, prec))         # marque le sens inverse
                    break
                suites = [q for q in voisins[cur] if q != prec]
                if not suites:
                    break
                prec, cur = cur, min(
                    suites, key=lambda q: (q[0] - cur[0]) ** 2 + (q[1] - cur[1]) ** 2)
            chemins.append((chaine, ident[n], ident.get(chaine[-1])))

    # boucles fermées : composantes sans aucun nœud (que des pixels degré 2)
    restants = (set(pixels) - set(ident)
                - {p for ch, _, _ in chemins for p in ch})
    while restants:
        depart = next(iter(restants))
        chaine = [depart]
        restants.discard(depart)
        prec, cur = None, depart
        while True:
            vs = [q for q in voisins[cur] if q in restants and q != prec]
            if not vs:
                break
            prec, cur = cur, vs[0]
            chaine.append(cur)
            restants.discard(cur)
        chemins.append((chaine, None, None))

    return chemins


def _longueur_chaine(chaine):
    """Longueur en pixels d'une chaîne de pixels (les diagonales comptent)."""
    total = 0.0
    for (y0, x0), (y1, x1) in zip(chaine, chaine[1:]):
        total += 1.4142135623730951 if (y0 != y1 and x0 != x1) else 1.0
    return total


def ebarber(squelette, longueur_max):
    """Retire les « barbes » du squelette : minuscules branches mortes
    greffées sur un carrefour, produites par la squelettisation d'une crête
    un peu bosselée. Elles n'existent pas sur la vraie empreinte et coupent
    les crêtes en tronçons. Une vraie fin de crête (branche longue) reste."""
    if longueur_max <= 0:
        return squelette
    sq = np.asarray(squelette).copy()
    for _ in range(3):
        pixels, voisins = _graphe_squelette(sq)
        if not pixels:
            break
        ident, _ = _clusters_noeuds(pixels, voisins)
        aretes = _suivre_aretes(pixels, voisins, ident)
        branches = {}                               # branches par carrefour
        for _chaine, a, b in aretes:
            for k in (a, b):
                if k is not None:
                    branches[k] = branches.get(k, 0) + 1
        a_retirer = set()
        for chaine, a, b in aretes:
            if a is None or b is None or a == b:
                continue
            da, db = branches.get(a, 0), branches.get(b, 0)
            # une barbe : un cul-de-sac greffé sur un carrefour
            if not (min(da, db) == 1 and max(da, db) >= 3):
                continue
            if _longueur_chaine(chaine) > longueur_max:
                continue
            impasse = a if da == 1 else b
            # on garde le carrefour, on n'efface que la barbe elle-même
            a_retirer.update(p for p in chaine
                             if ident.get(p, impasse) == impasse)
        if not a_retirer:
            break
        for y, x in a_retirer:
            sq[y, x] = False
    return sq


def extraire_lignes_avec_noeuds(squelette):
    """Comme extraire_lignes, mais renvoie aussi, pour chaque ligne, le couple
    (nœud de départ, nœud d'arrivée) — l'identité des carrefours, nécessaire
    pour faire traverser une crête d'un seul trait."""
    pixels, voisins = _graphe_squelette(squelette)
    ident, centres = _clusters_noeuds(pixels, voisins)
    lignes, extremites = [], []
    for chaine, a, b in _suivre_aretes(pixels, voisins, ident):
        points = [(x, y) for y, x in chaine]
        if a is not None:                          # les branches d'un même
            points.insert(0, centres[a])           # carrefour partagent son
        if b is not None:                          # centre : les Y se touchent
            points.append(centres[b])
        arr = np.array(points, np.float64)
        if len(arr) > 1:                           # retire les doublons collés
            garde = np.concatenate(
                [[True], np.abs(np.diff(arr, axis=0)).sum(1) > 1e-9])
            arr = arr[garde]
        if len(arr) < 2:
            continue
        lignes.append(arr)
        extremites.append((a, b))
    return lignes, extremites


def extraire_lignes(squelette):
    """Suit les arêtes du squelette entre nœuds (extrémités et carrefours).
    Les arêtes qui aboutissent à un même carrefour PARTAGENT ce point : les
    bifurcations se touchent, comme sur les vraies crêtes (sortie Gabor).
    Retourne des tableaux de points (x, y)."""
    return extraire_lignes_avec_noeuds(squelette)[0]


def periode_cretes(cretes, defaut=PERIODE_DEFAUT):
    """Interligne moyen des crêtes (px), lu sur le pic du PROFIL RADIAL du
    spectre : une moyenne par longueur d'onde, donc insensible à un pixel de
    bruit isolé. Mesuré sur la seule zone qui porte des crêtes."""
    masque = np.asarray(cretes) < 128
    if int(masque.sum()) < 500:
        return defaut
    lignes, colonnes = np.where(masque)
    f = masque[lignes.min():lignes.max() + 1,
               colonnes.min():colonnes.max() + 1].astype(np.float32)
    if min(f.shape) < 48:
        return defaut
    f = f * 2.0 - 1.0
    f -= f.mean()
    f *= np.outer(np.hanning(f.shape[0]),
                  np.hanning(f.shape[1])).astype(np.float32)
    spectre = np.abs(np.fft.rfft2(f)) ** 2
    fy = np.fft.fftfreq(f.shape[0])[:, None]
    fx = np.fft.rfftfreq(f.shape[1])[None, :]
    rayon = np.sqrt(fx * fx + fy * fy)

    # la fenêtre descend jusqu'à 4 px : une empreinte de bébé prise de près
    # peut vraiment avoir un interligne de 5-6 px, et le plancher à 6 px
    # d'avant lui attribuait une période trop grande — toutes les tolérances
    # partaient alors du double de la bonne valeur.
    ondes = np.arange(4, 41, dtype=np.float32)
    energie = np.zeros_like(ondes)
    for i, onde in enumerate(ondes):
        anneau = (rayon > 1.0 / (onde + 0.5)) & (rayon <= 1.0 / (onde - 0.5))
        # UN ANNEAU TROP MINCE NE MESURE PLUS RIEN. Aux grandes longueurs
        # d'onde l'anneau ne contient qu'une poignée de cases du spectre, et
        # ces cases-là portent la FORME de l'empreinte (l'ovale du doigt), pas
        # ses crêtes : leur moyenne écrase le vrai pic. Sur une empreinte
        # petite ou fine — un bébé, précisément — l'interligne mesuré partait
        # alors à 32 px au lieu de 11, et TOUTES les tolérances avec lui.
        if int(anneau.sum()) >= ANNEAU_MINI:
            energie[i] = float(spectre[anneau].mean())
    if not energie.any():
        return defaut
    energie = cv2.GaussianBlur(energie.reshape(-1, 1), (1, 5), 0).ravel()
    return float(np.clip(ondes[int(np.argmax(energie))], 4.0, 34.0))


def champ_orientation(cretes, periode=None):
    """CHAMP D'ORIENTATION des crêtes, mesuré sur l'IMAGE par un tenseur de
    structure (même principe que completer_empreinte). Retourne
    (ex, ey, cohérence) : la direction UNITAIRE des crêtes en chaque pixel
    (sans signe : une direction, pas un sens) et la confiance à lui accorder.

    C'est la référence du tracé : la tangente terminale d'une crête coupée
    est bruitée (crochet du squelette) et peut se tromper de plusieurs
    dizaines de degrés ; le champ, lui, moyenne tout le voisinage et voit la
    vraie direction de la famille de crêtes."""
    img = np.asarray(cretes)
    if img.ndim != 2 or img.size == 0:
        return None
    if periode is None:
        periode = periode_cretes(img)
    sigma = float(max(2.5, CHAMP_LISSAGE * periode))
    bande = (255.0 - img.astype(np.float32)) / 255.0
    gx = cv2.Sobel(bande, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(bande, cv2.CV_32F, 0, 1, ksize=3)
    jxx = cv2.GaussianBlur(gx * gx, (0, 0), sigma)
    jyy = cv2.GaussianBlur(gy * gy, (0, 0), sigma)
    jxy = cv2.GaussianBlur(gx * gy, (0, 0), sigma)
    c2, s2 = jxx - jyy, 2.0 * jxy                 # angle double du gradient
    magnitude = np.sqrt(c2 * c2 + s2 * s2) + 1e-9
    coherence = (magnitude / (jxx + jyy + 1e-9)).astype(np.float32)
    theta = 0.5 * np.arctan2(-s2 / magnitude, -c2 / magnitude)   # +90°
    return (np.cos(theta).astype(np.float32),
            np.sin(theta).astype(np.float32), coherence)


def _lire_champ(champ, points):
    """Direction des crêtes et cohérence aux points (x, y) donnés."""
    ex, ey, coh = champ
    h, w = coh.shape
    p = np.asarray(points, np.float64).reshape(-1, 2)
    xi = np.clip(np.round(p[:, 0]).astype(np.int64), 0, w - 1)
    yi = np.clip(np.round(p[:, 1]).astype(np.int64), 0, h - 1)
    return (np.stack([ex[yi, xi], ey[yi, xi]], 1).astype(np.float64),
            coh[yi, xi].astype(np.float64))


def _moyenne_directions(dirs, poids, groupes=None, nb=None):
    """Moyenne de directions NON ORIENTÉES (angle double) : deux vecteurs
    opposés comptent pour la même direction. `groupes` permet de moyenner
    plusieurs paquets d'un coup. Retourne (directions, concentration 0-1)."""
    c = dirs[:, 0] ** 2 - dirs[:, 1] ** 2
    s = 2.0 * dirs[:, 0] * dirs[:, 1]
    if groupes is None:
        C, S, W = float((c * poids).sum()), float((s * poids).sum()), \
            float(poids.sum())
        n = np.hypot(C, S)
        if n < 1e-9 or W < 1e-9:
            return np.zeros((1, 2)), np.zeros(1)
        a = 0.5 * np.arctan2(S / n, C / n)
        return (np.array([[np.cos(a), np.sin(a)]]), np.array([n / W]))
    nb = int(nb if nb is not None else (groupes.max() + 1))
    C = np.bincount(groupes, c * poids, minlength=nb)
    S = np.bincount(groupes, s * poids, minlength=nb)
    W = np.bincount(groupes, poids, minlength=nb)
    n = np.hypot(C, S)
    bon = (n > 1e-9) & (W > 1e-9)
    a = 0.5 * np.arctan2(np.where(bon, S / np.where(n > 0, n, 1), 0.0),
                         np.where(bon, C / np.where(n > 0, n, 1), 0.0))
    e = np.stack([np.cos(a), np.sin(a)], 1)
    e[~bon] = 0.0
    return e, np.where(bon, n / np.where(W > 0, W, 1), 0.0)


def _champ_aux_bouts(champ, lignes, ports, portee, pas=None):
    """Direction des CRÊTES à chaque bout de trait, lue sur le champ le long
    du dernier `portee` de la ligne (jamais sur la seule tangente terminale).
    `ports` : liste de (indice de ligne, 0 = début / 1 = fin).
    Retourne (directions unitaires SORTANTES, fiabilité 0-1, ancres) —
    l'ancre est le point du CORPS de la crête d'où part la mesure, en deçà du
    crochet terminal : c'est de là qu'on sait où passe vraiment la crête."""
    nb = len(ports)
    if not nb or champ is None:
        return np.zeros((nb, 2)), np.zeros(nb), np.zeros((nb, 2))
    # `portee` est une longueur, `pas` l'espacement réel des points : le
    # nombre de points à lire s'en déduit (et suit donc l'interligne).
    m = max(2, int(portee / max(pas or PAS_ECHANTILLON, 0.5)) + 2)
    pts, grp = [], []
    chordes, ancres = np.zeros((nb, 2)), np.zeros((nb, 2))
    for k, (i, p) in enumerate(ports):
        l = lignes[i]
        bout = l[:m] if p == 0 else l[-m:][::-1]   # du bout vers l'intérieur
        pts.append(bout)
        grp.append(np.full(len(bout), k))
        chordes[k] = bout[0] - bout[-1]            # sens sortant
        ancres[k] = bout[-1]                       # point du corps de la crête
    pts = np.vstack(pts)
    grp = np.concatenate(grp)
    dirs, coh = _lire_champ(champ, pts)
    e, conc = _moyenne_directions(dirs, coh, grp, nb)
    fiable = conc * np.bincount(grp, coh, minlength=nb) / \
        np.maximum(np.bincount(grp, minlength=nb), 1)
    # oriente vers l'extérieur (le champ n'a pas de sens, la corde si)
    signe = np.sign((e * chordes).sum(1))
    signe[signe == 0] = 1.0
    return e * signe[:, None], fiable, ancres


def reechantillonner(points, pas=PAS_ECHANTILLON):
    ecarts = np.linalg.norm(np.diff(points, axis=0), axis=1)
    abscisse = np.concatenate([[0.0], np.cumsum(ecarts)])
    total = abscisse[-1]
    if total < 1e-6:
        return points
    cibles = np.linspace(0.0, total, max(int(total / pas) + 1, 2))
    return np.column_stack([np.interp(cibles, abscisse, points[:, i])
                            for i in (0, 1)])


def lisser(points, fenetre=5, passes=2):
    if len(points) <= fenetre:
        return points
    noyau = np.ones(fenetre) / fenetre
    marge = fenetre // 2
    p = points
    for _ in range(passes):
        etendu = np.vstack([p[1:marge + 1][::-1], p, p[-marge - 1:-1][::-1]])
        p = np.column_stack([np.convolve(etendu[:, i], noyau, "valid")
                             for i in (0, 1)])
    return p


def _bout(points, fin):
    """Position et direction sortante d'une extrémité d'un trait."""
    if fin:
        pos, ref = points[-1], points[max(0, len(points) - 6)]
    else:
        pos, ref = points[0], points[min(len(points) - 1, 5)]
    direction = pos - ref
    n = float(np.linalg.norm(direction))
    return pos, (direction / n if n > 1e-9 else direction)


def _angle(u, v):
    return float(np.degrees(np.arccos(np.clip(np.dot(u, v), -1.0, 1.0))))


def _tangente_locale(points, port, portee):
    """Direction SORTANTE à l'extrémité `port` d'une polyligne
    (port 0 = début, port 1 = fin), moyennée sur `portee` px de longueur
    d'arc : une tangente stable, insensible au crénelage du squelette."""
    p = np.asarray(points, np.float64)
    if len(p) < 2:
        return np.zeros(2)
    if port:
        p = p[::-1]
    pas = np.linalg.norm(np.diff(p, axis=0), axis=1)
    arc = np.concatenate([[0.0], np.cumsum(pas)])
    k = int(np.searchsorted(arc, min(float(portee), arc[-1])))
    k = max(1, min(k, len(p) - 1))
    v = p[0] - p[max(1, (k + 1) // 2):k + 1]
    n = np.linalg.norm(v, axis=1)
    v = v[n > 1e-9] / n[n > 1e-9][:, None]
    if not len(v):
        return np.zeros(2)
    m = v.mean(0)
    nm = float(np.linalg.norm(m))
    return m / nm if nm > 1e-9 else np.zeros(2)


def _melanger(principal, secondaire, poids=0.65):
    """Direction dominée par `principal` (le champ) mais tirée vers
    `secondaire` (la polyligne) : le cap est celui des crêtes, la continuité
    reste celle du trait."""
    if principal is None or not np.any(principal):
        return secondaire
    if secondaire is None or not np.any(secondaire):
        return principal
    v = poids * np.asarray(principal) + (1.0 - poids) * np.asarray(secondaire)
    n = float(np.linalg.norm(v))
    return v / n if n > 1e-9 else np.asarray(principal)


def _hermite(p0, t0, p1, t1, pas=1.5):
    """Points intermédiaires d'un raccord de Hermite entre p0 (direction de
    marche sortante t0) et p1 (direction de marche entrante t1). Le raccord
    est tangent aux deux traits : la soudure est une courbe, pas un coude."""
    d = float(np.linalg.norm(np.asarray(p1) - np.asarray(p0)))
    if d < 1e-6:
        return np.empty((0, 2))
    nb = int(max(2, min(60, d / pas)))
    m0, m1 = np.asarray(t0) * d * 0.6, np.asarray(t1) * d * 0.6
    s = np.linspace(0.0, 1.0, nb + 2)[1:-1][:, None]
    return ((2 * s ** 3 - 3 * s ** 2 + 1) * np.asarray(p0)
            + (s ** 3 - 2 * s ** 2 + s) * m0
            + (-2 * s ** 3 + 3 * s ** 2) * np.asarray(p1)
            + (s ** 3 - s ** 2) * m1)


def adoucir_soudure(points, k, rayon):
    """Remplace le voisinage de l'indice k par un raccord de Hermite : la
    soudure de deux tronçons devient une courbe fluide, jamais un angle."""
    n = len(points)
    if rayon <= 0 or n < 7 or k < 2 or k > n - 3:
        return points
    pas = np.linalg.norm(np.diff(points, axis=0), axis=1)
    arc = np.concatenate([[0.0], np.cumsum(pas)])
    ia = int(np.searchsorted(arc, arc[k] - rayon))
    ib = int(np.searchsorted(arc, arc[k] + rayon))
    ia = max(1, min(ia, k - 1))
    ib = min(n - 2, max(ib, k + 1))
    if ib - ia < 2:
        return points
    t0 = _tangente_locale(points[:ia + 1], 1, rayon)
    t1 = -_tangente_locale(points[ib:], 0, rayon)
    if not (np.any(t0) and np.any(t1)):
        return points
    milieu = _hermite(points[ia], t0, points[ib], t1)
    return np.vstack([points[:ia + 1], milieu, points[ib:]])


def _assembler(lignes, partenaire, portee, ponter=False, rayon_soudure=0.0,
               directions=None):
    """Recolle les polylignes selon l'appariement `partenaire`
    ({(i, port) : (j, port)}, symétrique) en suivant les chaînes de bout en
    bout, puis adoucit chaque soudure. Une crête ressort d'un seul tenant.
    `directions` : {(i, port) -> direction sortante} lue sur le champ
    d'orientation. Le raccord part alors dans le sens des CRÊTES et non dans
    celui du petit crochet terminal du squelette."""
    nb = len(lignes)
    vus = [False] * nb
    # on part des traits qui ont un bout libre ; les boucles fermées ensuite
    ordre = [i for i in range(nb)
             if (i, 0) not in partenaire or (i, 1) not in partenaire]
    ordre += list(range(nb))

    sorties = []
    for depart in ordre:
        if vus[depart]:
            continue
        porte = 0 if (depart, 0) not in partenaire else \
            (1 if (depart, 1) not in partenaire else 0)
        morceaux, soudures, total = [], [], 0
        i, p = depart, porte
        precedent_port = None
        while True:
            vus[i] = True
            seg = lignes[i] if p == 0 else lignes[i][::-1]
            if total:
                precedent = morceaux[-1][-1]
                if float(np.linalg.norm(seg[0] - precedent)) < 1e-6:
                    seg = seg[1:]                     # carrefour partagé
                elif ponter and len(seg) >= 2:
                    t0 = _tangente_locale(morceaux[-1], 1, portee)
                    t1 = -_tangente_locale(seg, 0, portee)
                    if directions is not None:
                        # le champ donne le cap, la polyligne garde la
                        # continuité : sans ce mélange le raccord repart en
                        # biais du trait qu'il prolonge et son ventre peut
                        # frôler le voisin.
                        t0 = _melanger(directions.get(precedent_port), t0)
                        t1 = -_melanger(directions.get((i, p)), -t1)
                    if np.any(t0) and np.any(t1):
                        pont = _hermite(precedent, t0, seg[0], t1)
                        if len(pont):
                            morceaux.append(pont)
                            total += len(pont)
                if len(seg):
                    soudures.append(total - 1)
            if len(seg):
                morceaux.append(seg)
                total += len(seg)
            precedent_port = (i, 1 - p)
            suivant = partenaire.get((i, 1 - p))
            if suivant is None or vus[suivant[0]]:
                break
            i, p = suivant
        if not morceaux:
            continue
        points = np.vstack(morceaux)
        if rayon_soudure > 0 and soudures:
            pas = np.linalg.norm(np.diff(points, axis=0), axis=1)
            arc = np.concatenate([[0.0], np.cumsum(pas)])
            precedente = np.inf
            # de la fin vers le début : les indices d'avant restent valides
            for k in sorted(set(soudures), reverse=True):
                if 0 <= k < len(arc) and precedente - arc[k] > 2.2 * rayon_soudure:
                    points = adoucir_soudure(points, k, rayon_soudure)
                    precedente = arc[k]
        sorties.append(points)
    return sorties


def _paires_proches(positions, rayon):
    """Couples d'indices distants de moins de `rayon` (tableau M x 2)."""
    if len(positions) < 2:
        return np.empty((0, 2), np.int64)
    try:
        from scipy.spatial import cKDTree
        return np.asarray(cKDTree(positions).query_pairs(
            rayon, output_type="ndarray"), np.int64).reshape(-1, 2)
    except Exception:
        paires = []
        for a in range(len(positions)):
            d = np.linalg.norm(positions[a + 1:] - positions[a], axis=1)
            paires += [(a, a + 1 + int(b)) for b in np.nonzero(d <= rayon)[0]]
        return np.asarray(paires, np.int64).reshape(-1, 2)


def apparier_jonctions(lignes, extremites, portee, angle_max=ANGLE_JONCTION,
                       rayon_soudure=None, paires_max=1):
    """CONTINUITÉ AUX CARREFOURS. À chaque carrefour du squelette, apparie
    les deux branches dont les tangentes se prolongent le plus naturellement
    (écart à la ligne droite < angle_max) et les fusionne en UNE polyligne :
    la crête traverse la bifurcation d'un seul trait. La branche latérale,
    non appariée, reste un trait séparé qui vient s'y attacher.
    paires_max=1 : UNE seule crête traverse un carrefour donné — c'est le
    modèle d'une bifurcation, et ça évite de faire se croiser deux traits."""
    if rayon_soudure is None:
        rayon_soudure = portee
    par_noeud = {}
    for i, (a, b) in enumerate(extremites):
        if a is not None:
            par_noeud.setdefault(a, []).append((i, 0))
        if b is not None:
            par_noeud.setdefault(b, []).append((i, 1))

    cache = {}

    def tangente(port):
        if port not in cache:
            cache[port] = _tangente_locale(lignes[port[0]], port[1], portee)
        return cache[port]

    partenaire = {}
    for ports in par_noeud.values():
        if len(ports) < 2:
            continue
        candidats = []
        for m in range(len(ports)):
            for n in range(m + 1, len(ports)):
                pm, pn = ports[m], ports[n]
                if pm[0] == pn[0]:                 # même trait : pas de boucle
                    continue
                tm, tn = tangente(pm), tangente(pn)
                if not (np.any(tm) and np.any(tn)):
                    continue
                ecart = _angle(tm, -tn)            # 0° = parfaitement aligné
                if ecart <= angle_max:
                    candidats.append((ecart, pm, pn))
        candidats.sort(key=lambda c: c[0])
        pris, faites = set(), 0
        for _, pm, pn in candidats:
            if faites >= paires_max:
                break
            if pm in pris or pn in pris:
                continue
            if pm in partenaire or pn in partenaire:
                continue
            pris.update((pm, pn))
            partenaire[pm] = pn
            partenaire[pn] = pm
            faites += 1
    return _assembler(lignes, partenaire, portee, rayon_soudure=rayon_soudure)


def _croise(p, q, r, s):
    """Les segments [p,q] et [r,s] se coupent-ils franchement ?"""
    d1, d2, w = q - p, s - r, r - p
    den = d1[0] * d2[1] - d1[1] * d2[0]
    if abs(den) < 1e-12:
        return False
    t1 = (w[0] * d2[1] - w[1] * d2[0]) / den
    t2 = (w[0] * d1[1] - w[1] * d1[0]) / den
    return 0.0 < t1 < 1.0 and 0.0 < t2 < 1.0


def _croise_lot(p, q, P, Q):
    """Le segment [p, q] coupe-t-il l'un des segments [P_i, Q_i] ?
    Sert à garantir que DEUX PONTS NE SE CROISENT JAMAIS : _voie_libre ne
    voit que les traits déjà tracés, pas les ponts posés dans la même passe."""
    if not len(P):
        return False
    P, Q = np.asarray(P, np.float64), np.asarray(Q, np.float64)
    d1 = np.asarray(q, np.float64) - np.asarray(p, np.float64)
    d2 = Q - P
    w = P - np.asarray(p, np.float64)
    den = d1[0] * d2[:, 1] - d1[1] * d2[:, 0]
    ok = np.abs(den) > 1e-12
    den = np.where(ok, den, 1.0)
    t1 = (w[:, 0] * d2[:, 1] - w[:, 1] * d2[:, 0]) / den
    t2 = (w[:, 0] * d1[1] - w[:, 1] * d1[0]) / den
    return bool(np.any(ok & (t1 > 0) & (t1 < 1) & (t2 > 0) & (t2 < 1)))


def _groupes_alignes(milieux, bande, mini, max_groupes=6):
    """Paquets de points posés sur une MÊME DROITE (accumulateur de Hough).
    Une coupure de mosaïque est rectiligne : les milieux des ponts qui la
    franchissent sont tous alignés. Retourne une liste d'index."""
    resultat = []
    libres = np.arange(len(milieux))
    thetas = np.radians(np.arange(0.0, 180.0, 2.0))
    cs, sn = np.cos(thetas), np.sin(thetas)
    for _ in range(max_groupes):
        if len(libres) < mini:
            break
        pts = milieux[libres]
        rho = np.outer(cs, pts[:, 0]) + np.outer(sn, pts[:, 1])
        cases = np.floor((rho - rho.min()) / bande).astype(np.int64)
        nb = int(cases.max()) + 2
        meilleur = (0, 0, 0)
        for t in range(len(thetas)):
            compte = np.bincount(cases[t], minlength=nb)
            joint = compte[:-1] + compte[1:]      # deux cases voisines
            j = int(np.argmax(joint))
            if joint[j] > meilleur[0]:
                meilleur = (int(joint[j]), t, j)
        if meilleur[0] < mini:
            break
        _, t, j = meilleur
        membres = np.nonzero((cases[t] == j) | (cases[t] == j + 1))[0]
        resultat.append(libres[membres])
        libres = np.delete(libres, membres)
    return resultat


def _droite_ajustee(points):
    """Droite des moindres carrés totaux : (point moyen, direction)."""
    m = points.mean(0)
    _, vecteurs = np.linalg.eigh(np.cov((points - m).T) + 1e-12 * np.eye(2))
    return m, vecteurs[:, -1]


def _appariement_ordonne(cout, saut=COUTURE_SAUT):
    """APPARIEMENT ORDONNÉ de deux suites (programmation dynamique, comme un
    alignement de séquences). cout[i, j] = coût d'apparier A[i] avec B[j]
    (np.inf = impossible), `saut` = coût d'un bout laissé sans partenaire.

    Le résultat est MONOTONE : si A[i] va avec B[j], alors A[i+1] ne peut
    aller qu'avec un B[j'] avec j' > j. Aucun croisement, et surtout aucun
    décalage d'un cran possible : le long d'une coupure rectiligne, les
    crêtes gardent leur ordre, donc chacune retrouve SA continuation."""
    na, nb = cout.shape
    D = np.empty((na + 1, nb + 1))
    D[0] = np.arange(nb + 1) * saut
    D[:, 0] = np.arange(na + 1) * saut
    choix = np.zeros((na + 1, nb + 1), np.int8)
    choix[0, 1:] = 2
    choix[1:, 0] = 1
    for i in range(1, na + 1):
        ligne_prec, ligne = D[i - 1], D[i]
        cout_i = cout[i - 1]
        for j in range(1, nb + 1):
            meilleur, c = ligne_prec[j] + saut, 1        # A[i-1] sans partenaire
            v = ligne[j - 1] + saut                      # B[j-1] sans partenaire
            if v < meilleur:
                meilleur, c = v, 2
            v = ligne_prec[j - 1] + cout_i[j - 1]
            if v < meilleur:
                meilleur, c = v, 3
            ligne[j], choix[i, j] = meilleur, c
    couples, i, j = [], na, nb
    while i > 0 or j > 0:
        c = choix[i, j]
        if c == 3:
            couples.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif c == 1:
            i -= 1
        else:
            j -= 1
    couples.reverse()
    return couples, float(D[na, nb])


def _voie_libre(depart, arrivee, arbre, nuage, ids, exclus, marge):
    """Le pont depart -> arrivee coupe-t-il un autre trait ? Deux crêtes ne se
    croisent jamais : un pont qui traverse un voisin est refusé. On tolère les
    voisins des deux bouts (bifurcations), mais pas au milieu du pont."""
    if arbre is None:
        return True
    d = float(np.linalg.norm(arrivee - depart))
    milieu = (depart + arrivee) / 2.0
    # voisinage BORNÉ (96 points au plus) : sur une image bruitée, le nuage
    # peut être énorme et ce test doit rester rapide.
    distances, proches = arbre.query(milieu, k=int(min(96, len(ids))),
                                     distance_upper_bound=d / 2.0
                                     + max(marge, 2.0))
    for dd, j in zip(np.atleast_1d(distances), np.atleast_1d(proches)):
        if not np.isfinite(dd) or j >= len(ids):
            break
        if ids[j] in exclus:
            continue
        for k in (j - 1, j + 1):
            if 0 <= k < len(ids) and ids[k] == ids[j]:
                a, b = (nuage[j], nuage[k]) if k > j else (nuage[k], nuage[j])
                if _croise(depart, arrivee, a, b):
                    return False
    if marge > 0:                                  # ...ni frôler de trop près
        s = np.linspace(0.3, 0.7, max(3, int(d / 3.0)))[:, None]
        sondes = depart + s * (arrivee - depart)
        distances, indices = arbre.query(sondes, k=min(8, len(ids)))
        distances = np.asarray(distances).reshape(len(sondes), -1)
        indices = np.asarray(indices).reshape(len(sondes), -1)
        for dd, ii in zip(distances, indices):
            for x, j in zip(dd, ii):
                if ids[j] in exclus:
                    continue
                if x < marge:
                    return False
                break
    return True


def _traces_sur_droite(ancres, directions, centre, u, normale):
    """Où chaque crête COUPE la droite : on repart d'un point de son corps
    (l'ancre, en deçà du crochet terminal) et on prolonge dans la direction du
    champ jusqu'à la droite. C'est la position de la CRÊTE sur la coupure, et
    non celle de son bout — deux bouts crochus l'un vers l'autre ne peuvent
    plus faire croire à un décalage nul."""
    denom = directions @ normale
    ecart = (ancres - centre) @ normale
    sur = np.abs(denom) > 0.25
    t = np.where(sur, -ecart / np.where(sur, denom, 1.0), 0.0)
    trace = ancres + t[:, None] * directions
    return (trace - centre) @ u


def _paires_de_coupure(retenus, elargis, a, b, positions, ancres, directions,
                       cout, periode, mini=COUTURE_MINI):
    """COUPURE RECTILIGNE = TRAITEMENT COLLECTIF. Repère les couples de bouts
    dont les milieux sont alignés sur une même droite : c'est la signature
    d'une couture de mosaïque, qui tranche d'un coup toute une famille de
    crêtes parallèles. Deux propriétés en découlent, et ce sont elles qui
    tuent le décalage d'un cran :

      1. le long de la droite les crêtes ont un ORDRE, donc leurs
         continuations sont appariées DANS LE MÊME ORDRE (programmation
         dynamique : appariement monotone, aucun croisement possible) ;
      2. une couture décale TOUTE la famille du même déplacement. On le
         cherche par vote (le décalage qui met le plus de crêtes d'accord),
         puis on écarte les ponts qui s'en éloignent : celui qui vise la crête
         d'à côté s'en éloigne d'un interligne entier.

    `retenus` : candidats francs (ils servent à repérer la coupure et à
    mesurer son déplacement). `elargis` : mêmes candidats, décalage latéral
    desserré — utilisables seulement ici, où le déplacement est connu.
    Retourne (candidats choisis du plus franc au moins franc, bouts
    VERROUILLÉS, coupures repérées). Les bouts verrouillés sont ceux d'une
    coupure : leur sort est réglé collectivement ; celui que l'appariement
    ordonné a laissé sans partenaire doit le rester et se prolonger tout
    droit — surtout pas être rattrapé au coup par coup par le voisin d'à côté,
    ce qui ramènerait le décalage. Chaque coupure repérée est décrite par
    (point, direction, normale, déplacement, début, fin) : elle continue
    d'imposer son déplacement aux passes suivantes."""
    if len(retenus) < mini or periode <= 0:
        return [], set(), []
    milieux = (positions[a[retenus]] + positions[b[retenus]]) / 2.0
    if elargis is None or not len(elargis):
        elargis = retenus
    milieux_l = (positions[a[elargis]] + positions[b[elargis]]) / 2.0
    choisis, verrouilles, reperees = {}, set(), []
    for groupe in _groupes_alignes(milieux, COUTURE_BANDE * periode, mini):
        if len(groupe) < mini:
            continue
        sous = retenus[groupe]
        centre, u = _droite_ajustee(milieux[groupe])
        normale = np.array([-u[1], u[0]])
        le_long = (milieux[groupe] - centre) @ u
        if float(le_long.max() - le_long.min()) < COUTURE_ETENDUE * periode:
            continue                       # trop court pour être une coupure
        # ...et les ponts d'une même coupure sont ~parallèles (même décalage)
        vg = positions[b[sous]] - positions[a[sous]]
        ng = np.linalg.norm(vg, axis=1)
        vg = vg[ng > 1e-9] / ng[ng > 1e-9][:, None]
        if len(vg) < mini:
            continue
        moyenne, _ = _moyenne_directions(vg, np.ones(len(vg)))
        ecart = np.degrees(np.arccos(np.clip(np.abs(vg @ moyenne[0]), 0, 1)))
        if float(np.median(ecart)) > COUTURE_PARALLELE:
            continue                       # ponts dispersés : pas une coupure

        # les deux lèvres de la coupure, chacune ordonnée le long de la droite
        cotes = np.sign((positions - centre) @ normale)
        dans = np.abs((milieux_l - centre) @ normale) <= COUTURE_BANDE * periode
        bande = elargis[dans & (cotes[a[elargis]] * cotes[b[elargis]] < 0)]
        if len(bande) < mini:
            continue
        impliques = np.unique(np.concatenate([a[bande], b[bande]]))
        gauche = impliques[cotes[impliques] < 0]
        droite = impliques[cotes[impliques] > 0]
        if len(gauche) < 2 or len(droite) < 2:
            continue
        gauche = gauche[np.argsort((positions[gauche] - centre) @ u)]
        droite = droite[np.argsort((positions[droite] - centre) @ u)]
        rang_g = {int(p): i for i, p in enumerate(gauche)}
        rang_d = {int(p): j for j, p in enumerate(droite)}

        # position de chaque crête SUR la coupure (corps de la crête + champ)
        lat = _traces_sur_droite(ancres, directions, centre, u, normale)

        def oriente(k):
            """(rang à gauche, rang à droite, décalage gauche -> droite)."""
            ia, ib = int(a[k]), int(b[k])
            if ia in rang_g and ib in rang_d:
                return rang_g[ia], rang_d[ib], float(lat[ib] - lat[ia])
            if ib in rang_g and ia in rang_d:
                return rang_g[ib], rang_d[ia], float(lat[ia] - lat[ib])
            return None
        trios = [(int(k), oriente(k)) for k in bande]
        trios = [(k, t) for k, t in trios if t is not None]
        if len(trios) < mini:
            continue

        # DÉPLACEMENT COMMUN. Une couture décale TOUTE la famille de la même
        # quantité. On la cherche par VOTE, et seuls les ponts FRANCS votent :
        # eux ne peuvent pas atteindre la crête voisine (décalage latéral
        # bridé), leur consensus désigne donc le vrai déplacement. Les ponts
        # élargis, qui atteignent aussi la voisine, voteraient pour les deux
        # réponses à la fois — ils ne servent qu'à compléter l'appariement une
        # fois le déplacement connu.
        francs = [oriente(k) for k in sous]
        francs = [f for f in francs if f is not None]
        if len(francs) < mini:
            continue
        proj_vote = np.array([f[2] for f in francs])
        cotes_vote = np.array([f[0] for f in francs])
        proj = np.array([t[2] for _, t in trios])
        tolerance = COUTURE_TOLERANCE * periode
        sigma = max(COUTURE_VOTE * periode, 1.0)
        essais = np.arange(proj_vote.min(), proj_vote.max() + 1e-9,
                           0.1 * periode)
        if not len(essais):
            essais = np.array([float(np.median(proj_vote))])
        # une crête = une voix (son meilleur pont) : une crête qui offre
        # plusieurs candidats ne pèse pas plus lourd que ses voisines.
        voix = np.empty(len(essais))
        for m, h in enumerate(essais):
            poids = np.exp(-0.5 * ((proj_vote - h) / sigma) ** 2)
            par_crete = np.zeros(len(gauche))
            np.maximum.at(par_crete, cotes_vote, poids)
            voix[m] = par_crete.sum()
        meilleur = None
        for m in np.argsort(-voix):
            h = float(essais[m])
            accord = np.abs(proj_vote - h) <= tolerance
            if not accord.any():
                continue
            nb_voix = float(voix[m])
            if meilleur is not None and nb_voix < 0.9 * meilleur[0]:
                break                    # nettement moins de crêtes d'accord
            h = float(np.median(proj_vote[accord]))       # affinage
            matrice = np.full((len(gauche), len(droite)), np.inf)
            origine = {}
            for (k, (i, j, dk)), ok in zip(trios, np.abs(proj - h) <= tolerance):
                if not ok:               # ce pont vise une AUTRE crête que
                    continue             # celle que désigne le déplacement
                c = float(cout[k]) + COUTURE_ACCORD * abs(dk - h) / periode
                if c < matrice[i, j]:
                    matrice[i, j] = c
                    origine[(i, j)] = k
            if not origine:
                continue
            couples, total = _appariement_ordonne(matrice)
            if meilleur is None or (nb_voix, -total) > (meilleur[0],
                                                        -meilleur[1]):
                meilleur = (nb_voix, total, couples, origine, matrice, h)
        if meilleur is None:
            continue
        _, _, couples, origine, matrice, h = meilleur
        verrouilles.update(int(p) for p in impliques)
        etendue = (positions[impliques] - centre) @ u
        reperees.append((centre, u, normale, h,
                         float(etendue.min()) - periode,
                         float(etendue.max()) + periode))
        for i, j in couples:
            k = origine.get((i, j))
            if k is not None:
                choisis[k] = float(matrice[i, j])
    return sorted(choisis, key=choisis.get), verrouilles, reperees


def ponter_coupures(lignes, dist_max=DIST_RACCORD, angle_max=ANGLE_RACCORD,
                    decalage_max=None, portee=12.0, seuil_court=None,
                    passes=6, marge_voisine=0.0, portee_longue=None,
                    champ=None, periode=None, angle_champ=ANGLE_CHAMP,
                    coupures=None, pas=None):
    """PONTAGE DES COUPURES. Deux bouts libres qui se font face — orientations
    alignées, faible décalage latéral, écart inférieur à dist_max — sont les
    deux morceaux d'UNE crête cassée : on les relie par un raccord de Hermite
    (courbe tangente, sans coude). C'est une reconstruction de la crête, pas
    un contact entre deux crêtes différentes : autorisé même sans contact.
    Le décalage latéral maxi (bien moins d'un interligne) interdit de sauter
    par erreur sur la crête voisine, et marge_voisine interdit qu'un pont
    vienne frôler ou couper un autre trait. seuil_court : n'agit que si l'un
    des deux traits est plus court que ça (rattrapage des micro-traits).

    ATTENTION en réglant : `decalage_max` vaut écart × sin(angle). C'est lui,
    et non `angle_max`, qui commande dès que la coupure dépasse ~2/3 de
    période — les deux doivent être desserrés ensemble.

    `portee_longue` : la direction de chaque bout est mesurée à DEUX échelles.
    Le squelette se termine souvent par un petit crochet ; sur une base courte
    il fait dévier la tangente de plusieurs dizaines de degrés et la coupure,
    pourtant évidente à l'œil, est refusée. La mesure longue, elle, voit la
    crête. Le couple est retenu si l'UNE des deux mesures le juge aligné : les
    deux subissent exactement les mêmes garde-fous (angle, décalage, voie
    libre), on ne fait qu'écarter une tangente manifestement bruitée.

    `champ` : CHAMP D'ORIENTATION des crêtes (voir champ_orientation). C'est
    l'arbitre. Les deux tangentes terminales peuvent très bien se tromper
    ENSEMBLE — c'est ce qui arrive le long d'une couture de mosaïque, où les
    bouts finissent tous en crochet : le décalage latéral mesuré sur ces
    tangentes paraît alors petit alors que le pont saute sur la crête d'à
    côté. Mesuré sur le champ, il redevient ce qu'il est : presque un
    interligne, donc refusé. Le champ sert à trois choses :
      - mesurer le décalage latéral d'un pont (au lieu de la tangente) ;
      - refuser un pont trop oblique par rapport aux crêtes (angle_champ) ;
      - donner leur direction de départ aux raccords de Hermite.

    `coupures` : liste (modifiable) des coupures rectilignes déjà repérées.
    Une fois repérée, une coupure impose son déplacement à TOUT pont qui la
    franchit, dans cette passe comme dans les suivantes — sinon les quelques
    bouts que l'appariement ordonné a laissés libres se feraient rattraper au
    coup par coup à la passe d'après, et le décalage d'un cran reviendrait."""
    lignes = [np.asarray(l, np.float64) for l in lignes if len(l) >= 2]
    if portee_longue is None:
        portee_longue = 2.4 * portee
    if periode is None:
        periode = max(dist_max / 2.0, 6.0)
    if coupures is None:
        coupures = []
    for _ in range(max(1, passes)):
        arbre = ids = nuage = None              # nuage de tous les traits, pour
        if len(lignes) > 1:                     # vérifier qu'un pont passe
            try:
                from scipy.spatial import cKDTree
                ids = np.concatenate([np.full(len(l), k)
                                      for k, l in enumerate(lignes)])
                nuage = np.vstack(lignes)
                arbre = cKDTree(nuage)
            except Exception:
                arbre = ids = nuage = None
        ports = []
        for i, l in enumerate(lignes):
            for p in (0, 1):
                ports.append((i, p, l[0] if p == 0 else l[-1],
                              _tangente_locale(l, p, portee),
                              _tangente_locale(l, p, portee_longue)))
        if len(ports) < 2:
            break
        longueurs = np.array([longueur(l) for l in lignes])
        traits = np.array([q[0] for q in ports])
        positions = np.array([q[2] for q in ports])
        tangentes = np.array([q[3] for q in ports])
        tangentes_longues = np.array([q[4] for q in ports])
        # direction des CRÊTES à chaque bout, lue sur le champ d'orientation
        if champ is not None:
            dirs_champ, fiab_champ, ancres_champ = _champ_aux_bouts(
                champ, lignes, [(q[0], q[1]) for q in ports],
                CHAMP_PORTEE * periode, pas=pas)
        else:
            dirs_champ = np.zeros((len(ports), 2))
            fiab_champ = np.zeros(len(ports))
            ancres_champ = np.array([q[2] for q in ports])

        paires = _paires_proches(positions, dist_max)
        if not len(paires):
            break
        # tous les tests géométriques d'un coup (une empreinte bruitée peut
        # produire des dizaines de milliers de couples : pas de boucle Python)
        a, b = paires[:, 0], paires[:, 1]
        v = positions[b] - positions[a]
        d = np.linalg.norm(v, axis=1)
        bon = (traits[a] != traits[b]) & (d > 1e-9) & (d <= dist_max)
        if seuil_court is not None:
            bon &= ((longueurs[traits[a]] < seuil_court)
                    | (longueurs[traits[b]] < seuil_court))
        sur = np.maximum(d, 1e-9)[:, None]
        u = v / sur

        # orientation locale des crêtes le long du pont : moyenne (en angle
        # double, pondérée par la confiance) des directions lues aux deux
        # bouts. Un bout douteux ne pèse presque rien : il suffit que l'UN des
        # deux soit net pour que la direction de la crête soit connue.
        fiable = (np.maximum(fiab_champ[a], fiab_champ[b]) > COHERENCE_MINI)
        rang = np.arange(len(a))
        crete, _ = _moyenne_directions(
            np.vstack([dirs_champ[a], dirs_champ[b]]),
            np.concatenate([fiab_champ[a], fiab_champ[b]]),
            np.concatenate([rang, rang]), len(a))
        fiable &= np.any(crete != 0, axis=1)
        lat_champ = np.abs(crete[:, 0] * v[:, 1] - crete[:, 1] * v[:, 0])
        ang_champ = np.degrees(np.arctan2(
            lat_champ, np.maximum(np.abs((crete * v).sum(1)), 1e-9)))
        # les deux bouts se font-ils face DANS LE SENS DES CRÊTES ? (le sens
        # sortant est donné par la ligne elle-même, pas par sa tangente
        # terminale : un crochet de quelques pixels ne peut pas l'inverser)
        face = (((dirs_champ[a] * v).sum(1) > 0)
                & ((dirs_champ[b] * v).sum(1) < 0))

        def juger(ta, tb):
            """Ces deux bouts se font-ils face, vus par ce jeu de tangentes ?"""
            ang_a = np.degrees(np.arccos(np.clip((ta * u).sum(1), -1, 1)))
            ang_b = np.degrees(np.arccos(np.clip((tb * -u).sum(1), -1, 1)))
            oppose = np.degrees(np.arccos(np.clip((ta * -tb).sum(1), -1, 1)))
            ok = np.any(ta != 0, axis=1) & np.any(tb != 0, axis=1)
            ok &= (ang_a <= angle_max) & (ang_b <= angle_max)
            ok &= oppose <= angle_max * 1.3    # les deux bouts se font face
            if decalage_max is not None:
                lateral = np.maximum(
                    np.abs(ta[:, 0] * v[:, 1] - ta[:, 1] * v[:, 0]),
                    np.abs(tb[:, 0] * v[:, 1] - tb[:, 1] * v[:, 0]))
                ok &= lateral <= decalage_max   # crête voisine : on refuse
            return ok, ang_a, ang_b

        # tangente courte, puis longue : il suffit qu'une des deux mesures
        # juge les bouts alignés (un bout crochu fausse la courte).
        ok_court, angle_a, angle_b = juger(tangentes[a], tangentes[b])
        ok_long, angle_la, angle_lb = juger(tangentes_longues[a],
                                            tangentes_longues[b])
        # LE CHAMP FAIT FOI. Là où il est net, c'est lui seul qui juge : un
        # pont doit rester dans le couloir de SA crête (décalage latéral) et
        # aller dans le sens des crêtes (angle). Les tangentes terminales, à
        # cet endroit précis, peuvent se tromper ENSEMBLE — le long d'une
        # couture elles finissent toutes en crochet et rendent crédible un
        # saut en diagonale vers la crête voisine.
        ok_champ = fiable & face & (ang_champ <= angle_champ)
        large = bon & np.where(fiable, ok_champ, ok_court | ok_long)
        if decalage_max is not None:
            large &= np.where(fiable, lat_champ, 0.0) \
                <= decalage_max * COUTURE_LARGE
            ok_champ &= lat_champ <= decalage_max
        bon &= np.where(fiable, ok_champ, ok_court | ok_long)
        # une coupure déjà repérée impose son déplacement à tout pont qui la
        # franchit : sur une couture, toutes les crêtes se décalent pareil.
        for centre_c, u_c, n_c, h_c, t0_c, t1_c in coupures:
            lat_c = _traces_sur_droite(ancres_champ, dirs_champ,
                                       centre_c, u_c, n_c)
            ca = (positions[a] - centre_c) @ n_c
            cb = (positions[b] - centre_c) @ n_c
            milieu_c = (positions[a] + positions[b]) / 2.0 - centre_c
            franchit = ((ca * cb < 0)
                        & (np.abs(milieu_c @ n_c) <= COUTURE_BANDE * periode)
                        & (milieu_c @ u_c >= t0_c) & (milieu_c @ u_c <= t1_c))
            recale = (lat_c[b] - lat_c[a]) * np.sign(cb)
            bon &= ~franchit | (np.abs(recale - h_c)
                                <= COUTURE_TOLERANCE * periode)
        angle_a = np.where(ok_court, angle_a, angle_la)   # la mesure retenue
        angle_b = np.where(ok_court, angle_b, angle_lb)
        retenus = np.nonzero(bon)[0]
        if not len(retenus):
            break
        cout = (0.4 * d / dist_max
                + 0.4 * (angle_a + angle_b) / (2 * angle_max)
                + 0.2 * np.where(fiable, ang_champ / max(angle_champ, 1.0), 0.5))
        retenus = retenus[np.argsort(cout[retenus])]   # les plus francs d'abord

        racine = list(range(len(lignes)))

        def trouver(x):
            while racine[x] != x:
                racine[x] = racine[racine[x]]
                x = racine[x]
            return x

        # au plus un pont par bout de trait ; et jamais deux ponts qui se
        # croisent (`_voie_libre` ne voit que les traits DÉJÀ tracés).
        pris, partenaire = set(), {}
        ponts_p, ponts_q = [], []

        def accepter(k):
            ka, kb = int(a[k]), int(b[k])
            pa_ = (ports[ka][0], ports[ka][1])
            pb_ = (ports[kb][0], ports[kb][1])
            if pa_ in pris or pb_ in pris:
                return False
            ra, rb = trouver(pa_[0]), trouver(pb_[0])
            if ra == rb:                       # refermerait une boucle
                return False
            if _croise_lot(positions[ka], positions[kb], ponts_p, ponts_q):
                return False                   # deux ponts ne se croisent pas
            if not _voie_libre(positions[ka], positions[kb], arbre, nuage, ids,
                               (pa_[0], pb_[0]), marge_voisine):
                return False                   # le pont couperait un trait
            racine[ra] = rb
            pris.update((pa_, pb_))
            partenaire[pa_] = pb_
            partenaire[pb_] = pa_
            ponts_p.append(positions[ka])
            ponts_q.append(positions[kb])
            return True

        # 1. les COUPURES RECTILIGNES d'abord, appariées dans l'ordre (en bloc)
        prioritaires, verrouilles, reperees = (
            _paires_de_coupure(retenus, np.nonzero(large)[0], a, b, positions,
                               ancres_champ, dirs_champ, cout, periode)
            if champ is not None else ([], set(), []))
        coupures.extend(reperees)
        for k in prioritaires:
            accepter(k)
        # 2. le reste au coup par coup, du couple le plus franc au moins franc.
        # `essais_max` est un garde-fou : sur une image qui n'est pas une
        # empreinte (bruit), on n'insiste pas.
        deja = set(prioritaires)
        essais, essais_max = 0, 4 * len(ports) + 200
        for k in retenus:
            if essais > essais_max:
                break
            if int(k) in deja:
                continue
            ka, kb = int(a[k]), int(b[k])
            if ka in verrouilles or kb in verrouilles:
                continue               # bout d'une coupure : déjà tranché
            if (ports[ka][0], ports[ka][1]) in pris \
                    or (ports[kb][0], ports[kb][1]) in pris:
                continue
            essais += 1
            accepter(k)
        if not partenaire:
            break
        directions = None
        if champ is not None:                  # raccords lancés dans le sens
            directions = {                     # des crêtes, pas du crochet
                (ports[k][0], ports[k][1]): dirs_champ[k]
                for k in range(len(ports))
                if fiab_champ[k] > COHERENCE_MINI and np.any(dirs_champ[k])}
        lignes = _assembler(lignes, partenaire, portee, ponter=True,
                            directions=directions)
    return lignes


def recoudre(lignes, periode=None):
    """Fusionne les traits dont les bouts sont proches ET dans le
    prolongement l'un de l'autre (coupures et carrefours traversés).
    `periode` : interligne des crêtes — la portée du recollement le suit
    (PONT_PORTEE périodes). Sans interligne connu, on retombe sur la valeur
    historique DIST_RACCORD."""
    dist = DIST_RACCORD if periode is None \
        else max(PONT_PLANCHER, PONT_PORTEE * float(periode))
    return ponter_coupures(lignes, dist, ANGLE_RACCORD, periode=periode)


def absorber_doublons(lignes, ecart, seuil_court):
    """Supprime un trait court entièrement collé le long d'un autre trait :
    doublon ou reste de barbe laissé par la squelettisation. Il n'apporte
    rien au dessin et ne fait qu'ajouter du bruit."""
    if len(lignes) < 2:
        return lignes
    try:
        from scipy.spatial import cKDTree
    except Exception:
        return lignes
    ids = np.concatenate([np.full(len(l), k) for k, l in enumerate(lignes)])
    nuage = np.vstack(lignes)
    arbre = cKDTree(nuage)
    k = int(min(24, len(nuage)))
    gardes = []
    for i, l in enumerate(lignes):
        if longueur(l) >= seuil_court:
            gardes.append(l)
            continue
        d, idx = arbre.query(np.asarray(l), k=k)
        d = np.asarray(d).reshape(len(l), -1)
        idx = np.asarray(idx).reshape(len(l), -1)
        proche = np.where(ids[idx] != i, d, np.inf).min(axis=1)
        if np.isfinite(proche).all() and float(proche.max()) <= ecart:
            continue                                # absorbé par son voisin
        gardes.append(l)
    return gardes


def couper_epingles(points, courbure_max=COURBURE_MAX):
    """Coupe un trait là où il fait un demi-tour serré (épingle à cheveux).
    Les grandes courbes douces (cœur de l'empreinte) restent entières :
    seule une courbure soutenue au-delà de `courbure_max` °/px coupe.

    Ce seuil DÉPEND DE L'INTERLIGNE (voir COURBURE_RAYON). Le cœur d'une
    empreinte tourne sur un rayon de l'ordre de l'interligne : sur des crêtes
    deux fois plus serrées, la même boucle a une courbure deux fois plus
    forte. Un seuil fixe en °/px hachait le cœur d'un bébé en confettis."""
    if len(points) < 5:
        return [points]
    segments = np.diff(points, axis=0)
    longueurs = np.linalg.norm(segments, axis=1) + 1e-9
    caps = np.degrees(np.arctan2(segments[:, 1], segments[:, 0]))
    virages = (np.diff(caps) + 180.0) % 360.0 - 180.0
    taux = np.abs(virages) / ((longueurs[:-1] + longueurs[1:]) / 2.0)

    morceaux = []
    debut, i = 0, 0
    while i < len(taux):
        if taux[i] > courbure_max:
            morceaux.append(points[debut:i + 1])
            fin = i
            while fin < len(taux) and taux[fin] > courbure_max * 0.6:
                fin += 1              # saute toute la zone du virage
            debut = fin + 1
            i = debut
        else:
            i += 1
    morceaux.append(points[debut:])
    return [m for m in morceaux if len(m) >= 2]


def defaire_gouttes(points, pince=DIST_PINCE, separation=SEPARATION_MINI):
    """Coupe un trait qui revient sur lui-même — goutte, crochet ou spirale.
    Signature : deux points éloignés LE LONG du trait mais spatialement
    collés (le trait se pince). Les vraies grandes arches de l'empreinte
    gardent leurs bras à un interligne d'écart : elles ne se pincent pas.
    `pince` / `separation` sont calés sur l'interligne mesuré : un long trait
    qui contourne le cœur et revient à un interligne de lui-même n'est PAS
    une goutte et doit rester entier."""
    if len(points) < 8:
        return [points]
    ecarts = np.linalg.norm(np.diff(points, axis=0), axis=1)
    s = np.concatenate([[0.0], np.cumsum(ecarts)])
    diff = points[:, None, :] - points[None, :, :]
    dist = np.sqrt((diff ** 2).sum(-1))
    dist[np.abs(s[:, None] - s[None, :]) < separation] = np.inf
    i, j = np.unravel_index(int(np.argmin(dist)), dist.shape)
    if dist[i, j] >= pince:
        return [points]
    a, b = (i, j) if i < j else (j, i)
    morceaux = []
    for m in (points[:a + 1], points[b:]):        # on retire le pont pincé
        if len(m) >= 8:
            morceaux.extend(defaire_gouttes(m, pince, separation))  # spirales
        elif len(m) >= 2:
            morceaux.append(m)
    return morceaux


def prolonger_bouts(lignes, champ=None, ecart=ECART_MINI, ext_max=EXT_MAX,
                    pas=None):
    """Allonge doucement chaque extrémité libre dans le prolongement du
    trait, mais s'arrête net avant de s'approcher d'un autre trait :
    les traits se rejoignent visuellement sans jamais se toucher.
    Faute de partenaire, une crête coupée se PROLONGE TOUT DROIT : si le
    champ d'orientation est donné, l'allongement suit les crêtes pas à pas
    (jamais le petit crochet terminal du squelette, qui partirait de biais).

    L'allongement se fait en 7 pas quel que soit l'interligne : CHAQUE point
    ajouté est vérifié, pas seulement le dernier — un prolongement ne peut
    donc pas venir longer une crête voisine. Attention toutefois : le nuage
    de référence est celui d'AVANT les prolongements ; deux bouts allongés
    l'un vers l'autre ne se voient pas. C'est ecarter_corps qui rattrape."""
    if len(lignes) < 2:
        return lignes
    ext_max = float(max(ext_max, 1.0))
    ext_pas = ext_max / 7.0                    # 7 pas, à toutes les échelles
    ids = np.concatenate([np.full(len(l), k) for k, l in enumerate(lignes)])
    nuage = np.vstack(lignes)
    try:
        from scipy.spatial import cKDTree
        arbre = cKDTree(nuage)

        def distance_autre(pt, self_id):
            d, idx = arbre.query(pt, k=8)
            for dd, ii in zip(np.atleast_1d(d), np.atleast_1d(idx)):
                if ids[ii] != self_id:
                    return float(dd)
            return np.inf
    except Exception:
        def distance_autre(pt, self_id):
            d = np.linalg.norm(nuage - pt, axis=1)
            d[ids == self_id] = np.inf
            return float(d.min())

    caps = fiab_caps = None
    if champ is not None:                      # tous les bouts d'un coup
        caps, fiab_caps, _ = _champ_aux_bouts(
            champ, lignes, [(k, p) for k in range(len(lignes)) for p in (0, 1)],
            max(ext_max, 3.0 * ext_pas), pas=pas)

    sorties = []
    for k, l in enumerate(lignes):
        for fin in (True, False):
            pos, tangente = _bout(l, fin)
            if not np.isfinite(tangente).all():
                continue
            if caps is not None:               # le champ redresse le crochet
                q = 2 * k + (1 if fin else 0)
                if fiab_caps[q] > COHERENCE_MINI and np.any(caps[q]):
                    tangente = caps[q]
            ajout, p, depart = [], pos.copy(), tangente.copy()
            for _ in range(7):
                cand = p + tangente * ext_pas
                if distance_autre(cand, k) < ecart:
                    break
                ajout.append(cand)
                p = cand
                if champ is not None:          # suit la courbure des crêtes
                    e, f = _lire_champ(champ, cand)
                    if f[0] > COHERENCE_MINI:
                        suite = e[0] * (1.0 if float(e[0] @ tangente) >= 0
                                        else -1.0)
                        suite = suite / (np.linalg.norm(suite) + 1e-9)
                        # un prolongement PROLONGE : il ne s'enroule pas.
                        if _angle(suite, depart) > EXT_VIRAGE:
                            break
                        tangente = suite
            if ajout:
                l = np.vstack([l, ajout]) if fin \
                    else np.vstack([ajout[::-1], l])
        sorties.append(l)
    return sorties


def _masque_forme(cretes, periode=None):
    """Zone pleine occupée par l'empreinte (bord de l'ovale compris) : on
    ferme les crêtes en une silhouette pleine, on bouche les trous internes
    et on garde le plus gros bloc. Sert à ne rien tracer hors du bord.
    La fermeture doit combler le plus gros TROU de la carte de crêtes. Ces
    trous viennent de la prise (doigt sec, bulle), pas de l'interligne : 25 px
    restent donc un PLANCHER absolu — on ne referme jamais moins qu'avant, et
    trop fermer ne fait qu'arrondir la silhouette (sans risque), tandis que
    trop peu la troue et jette la moitié du tracé. Sur une empreinte à grosses
    crêtes (interligne > 21 px) il faut en revanche fermer plus large."""
    ridges = ((cretes < 128) * 255).astype(np.uint8)
    if periode is None:
        periode = periode_cretes(cretes)
    cote = int(max(25, round(1.2 * float(periode)))) | 1       # impair
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (cote, cote))
    plein = cv2.morphologyEx(ridges, cv2.MORPH_CLOSE, noyau)
    inverse = cv2.bitwise_not(plein)
    tampon = np.zeros((plein.shape[0] + 2, plein.shape[1] + 2), np.uint8)
    cv2.floodFill(inverse, tampon, (0, 0), 0)
    plein = cv2.bitwise_or(plein, inverse)
    nb, etiquettes, stats, _ = cv2.connectedComponentsWithStats(plein)
    if nb > 1:
        grande = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        plein = np.where(etiquettes == grande, 255, 0).astype(np.uint8)
    # rétrécit un peu : les traits s'arrêtent juste avant le bord net
    marge = int(max(3, round(0.25 * float(periode)))) | 1      # impair
    return cv2.erode(plein,
                     cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                               (marge, marge)))


def clipper(lignes, masque):
    """Ne garde que les portions de trait à l'intérieur du masque (bord net)."""
    h, w = masque.shape
    resultat = []
    for l in lignes:
        courant = []
        for p in l:
            x, y = int(round(p[0])), int(round(p[1]))
            if 0 <= x < w and 0 <= y < h and masque[y, x] > 0:
                courant.append(p)
            else:
                if len(courant) >= 2:
                    resultat.append(np.array(courant))
                courant = []
        if len(courant) >= 2:
            resultat.append(np.array(courant))
    return resultat


def _accord_coupures(depart, arrivee, coupures, tolerance):
    """Ce raccord franchit-il une coupure repérée ? Et si oui, le fait-il avec
    le déplacement de cette coupure ? Sinon il vise la crête d'à côté."""
    for centre_c, u_c, n_c, h_c, t0_c, t1_c in coupures or ():
        ca = float((depart - centre_c) @ n_c)
        cb = float((arrivee - centre_c) @ n_c)
        if ca * cb >= 0:
            continue                       # ne franchit pas cette coupure
        milieu_c = (depart + arrivee) / 2.0 - centre_c
        if not (t0_c <= float(milieu_c @ u_c) <= t1_c):
            continue
        recale = float((arrivee - depart) @ u_c) * (1.0 if cb > 0 else -1.0)
        if abs(recale - h_c) > tolerance:
            return False
    return True


def souder_bifurcations(lignes, seuil=11.0, angle_max=58.0, fondu=4,
                        champ=None, lateral_max=None, coupures=None,
                        tolerance=None, pas=None):
    """Recolle chaque bout libre sur la crête voisine SI ce bout se dirige
    vers elle (bifurcation / crête qui en rejoint une autre), pas s'il la
    longe (crêtes parallèles) : les Y se touchent comme sur le Gabor, sans
    relier par erreur deux crêtes côte à côte.
    Le déplacement est FONDU sur les derniers points : la branche s'incurve
    doucement vers la crête au lieu de casser d'un coup (soudure lisse).

    UNE COUPURE N'EST PAS UNE BIFURCATION. Le long d'une couture de mosaïque
    tous les bouts sont libres et voisins : sans garde-fou, chacun se souderait
    sur la crête d'à côté et sèmerait de faux Y tout au long de la coupure.
    `champ` (orientation des crêtes) + `lateral_max` l'interdisent : une vraie
    bifurcation se voit dans les crêtes — la branche rejoint sa crête presque
    dans son axe, elle ne saute pas de travers sur la voisine."""
    if len(lignes) < 2:
        return lignes
    lignes = [l.copy() for l in lignes]
    ids = np.concatenate([np.full(len(l), k) for k, l in enumerate(lignes)])
    nuage = np.vstack(lignes)
    try:
        from scipy.spatial import cKDTree
        arbre = cKDTree(nuage)
    except Exception:
        return lignes
    for k, l in enumerate(lignes):
        for fin in (True, False):
            pos, tangente = _bout(lignes[k], fin)
            if not np.isfinite(tangente).all():
                continue
            e_crete = None
            soude = False
            if champ is not None and lateral_max:
                e, f, _ = _champ_aux_bouts(champ, [lignes[k]],
                                           [(0, 1 if fin else 0)], 2.0 * seuil,
                                           pas=pas)
                if f[0] > COHERENCE_MINI and np.any(e[0]):
                    e_crete = e[0]
            d, idx = arbre.query(pos, k=14)
            for dd, ii in zip(np.atleast_1d(d), np.atleast_1d(idx)):
                if ids[ii] == k:
                    continue
                if dd > seuil:
                    break
                vers = nuage[ii] - pos
                if e_crete is not None:
                    # écart de la soudure à l'axe de la crête : au-delà, la
                    # cible est la crête d'à côté (coupure), pas une bifurcation
                    if abs(float(e_crete[0] * vers[1] - e_crete[1] * vers[0])) \
                            > lateral_max:
                        continue
                n = float(np.linalg.norm(vers))
                if n >= 1e-6 and _angle(tangente, vers / n) > angle_max:
                    continue
                # une COUPURE n'est pas une bifurcation : la franchir de
                # travers reviendrait à souder sur la crête voisine
                if coupures and not _accord_coupures(pos, nuage[ii], coupures,
                                                     tolerance or seuil):
                    continue
                # fondu : 0 loin du bout, 1 sur le bout lui-même
                m = int(min(max(1, fondu), len(lignes[k])))
                # ...et la soudure ne doit couper aucun autre trait : c'est
                # toute la queue déplacée (le fondu) qui balaie, pas seulement
                # le bout
                base = lignes[k][-m] if fin else lignes[k][m - 1]
                if n >= 1e-6 and not (
                        _voie_libre(pos, nuage[ii], arbre, nuage, ids,
                                    (k, int(ids[ii])), 0.0)
                        and _voie_libre(base, nuage[ii], arbre, nuage, ids,
                                        (k, int(ids[ii])), 0.0)):
                    continue
                poids = (np.arange(1, m + 1) / float(m))[:, None] ** 2
                if fin:
                    lignes[k][-m:] += vers * poids
                    lignes[k][-1] = nuage[ii]
                else:
                    lignes[k][:m] += vers * poids[::-1]
                    lignes[k][0] = nuage[ii]
                soude = True
                break
            if soude:                      # le nuage a bougé : on le refait
                nuage = np.vstack(lignes)
                arbre = cKDTree(nuage)
    return lignes


def _distance_aux_autres(lignes, k=40):
    """Pour CHAQUE point de chaque trait : distance au trait DIFFÉRENT le plus
    proche, et son numéro. Une seule requête pour tout le nuage.
    Retourne (identifiants, distances, voisins) alignés sur np.vstack(lignes)."""
    from scipy.spatial import cKDTree
    ids = np.concatenate([np.full(len(l), i) for i, l in enumerate(lignes)])
    nuage = np.vstack(lignes)
    d, idx = cKDTree(nuage).query(nuage, k=int(min(k, len(nuage))))
    d = np.atleast_2d(d)
    idx = np.atleast_2d(idx)
    autre = ids[idx] != ids[:, None]
    trouve = autre.any(axis=1)
    rang = np.argmax(autre, axis=1)             # 1er voisin d'un AUTRE trait
    ligne = np.arange(len(nuage))
    dist = np.where(trouve, d[ligne, rang], np.inf)
    voisin = np.where(trouve, ids[idx[ligne, rang]], -1)
    return ids, dist, voisin


def ecarter_corps(lignes, ecart=ECART_MINI, longueur_mini=0.0, passes=8):
    """AUCUN TRAIT N'EN TOUCHE UN AUTRE — SUR TOUTE SA LONGUEUR.

    ecarter_bouts ne regarde que les deux EXTRÉMITÉS de chaque trait : c'était
    la seule garde du mode « sans contact ». Tant que le tracé sortait en
    petits morceaux, ça suffisait — un frôlement tombait presque toujours sur
    un bout, qu'il reculait jusqu'à `ecart`. Depuis que les crêtes cassées
    sont recousues, un même trait traverse la zone serrée en plein milieu :
    le frôlement est à des dizaines de pixels du moindre bout et la garde ne
    le voit plus. Deux axes à 2,3 px l'un de l'autre, pour un trait de 2,6 px
    de large, c'est deux crêtes fusionnées à la gravure.

    On OUVRE donc le trait là où il frôle : le tronçon fautif est retiré, et
    la crête reprend juste après. À chaque frôlement on n'ouvre qu'UN des deux
    traits — celui qui perd le moins (le calcul compte le tronçon retiré plus
    les moignons devenus trop courts) : couper les deux enlèverait deux fois
    trop de dessin. Un frôlement près d'un bout revient donc naturellement à
    un simple raccourcissement, un frôlement en plein milieu à une coupure."""
    lignes = [np.asarray(l, np.float64) for l in lignes if len(l) >= 2]
    if ecart <= 0:
        return lignes
    for _ in range(max(1, passes)):
        if len(lignes) < 2:
            break
        try:
            ids, dist, voisin = _distance_aux_autres(lignes)
        except Exception:
            break
        if not np.any(dist < ecart):
            break
        # 1. tous les tronçons fautifs, avec ce que coûterait de les ouvrir
        propositions, debut = [], 0
        for k, l in enumerate(lignes):
            n = len(l)
            en_faute = dist[debut:debut + n] < ecart
            voisins_k = voisin[debut:debut + n]
            debut += n
            if not en_faute.any():
                continue
            arc = np.concatenate(
                [[0.0], np.cumsum(np.linalg.norm(np.diff(l, axis=0), axis=1))])
            bords = np.nonzero(np.diff(np.concatenate(
                [[0], en_faute.astype(np.int8), [0]])))[0]
            for i0, i1 in zip(bords[::2], bords[1::2] - 1):
                gauche, droite = arc[i0], arc[-1] - arc[i1]
                perte = (arc[i1] - arc[i0]
                         + (gauche if gauche < longueur_mini else 0.0)
                         + (droite if droite < longueur_mini else 0.0))
                vs = voisins_k[i0:i1 + 1]
                vs = vs[vs >= 0]
                if not len(vs):
                    continue
                dominant = int(np.bincount(vs).argmax())
                propositions.append((float(perte), k, int(i0), int(i1),
                                     dominant))
        if not propositions:
            break
        # 2. du moins coûteux au plus coûteux, un seul côté par frôlement
        propositions.sort(key=lambda p: (p[0], p[1], p[2]))
        ouvertures, regles = {}, set()
        for perte, k, i0, i1, j in propositions:
            couple = (min(k, j), max(k, j))
            if couple in regles:
                continue                       # l'autre côté est déjà ouvert
            regles.add(couple)
            ouvertures.setdefault(k, []).append((i0, i1))
        # 3. découpe effective
        sorties = []
        for k, l in enumerate(lignes):
            trous = sorted(ouvertures.get(k, []))
            if not trous:
                sorties.append(l)
                continue
            precedent = 0
            for i0, i1 in trous:
                if i0 - precedent >= 2:
                    sorties.append(l[precedent:i0])
                precedent = i1 + 1
            if len(l) - precedent >= 2:
                sorties.append(l[precedent:])
        lignes = [m for m in sorties
                  if len(m) >= 2 and longueur(m) >= longueur_mini]
    return lignes


def ecarter_bouts(lignes, ecart=ECART_MINI):
    """Garantie finale « aucun trait n'en touche un autre » : tant qu'une
    extrémité passe sous l'écart mini d'un autre trait, on la recule d'un
    point. Rattrape aussi deux prolongements qui se rejoindraient.
    Ne voit QUE les extrémités : un frôlement en plein milieu d'un trait lui
    échappe complètement — c'est ecarter_corps qui s'en charge, et les deux
    vont ensemble."""
    lignes = [l.copy() for l in lignes]
    try:
        from scipy.spatial import cKDTree
    except Exception:
        cKDTree = None
    for _ in range(30):
        ids = np.concatenate([np.full(len(l), k) for k, l in enumerate(lignes)])
        nuage = np.vstack(lignes)
        arbre = cKDTree(nuage) if cKDTree is not None else None
        change = False
        for k, l in enumerate(lignes):
            if len(l) < 4:
                continue
            for fin in (True, False):
                pt = l[-1] if fin else l[0]
                if arbre is not None:
                    d, idx = arbre.query(pt, k=10)
                    near = next((float(dd) for dd, ii in zip(d, idx)
                                 if ids[ii] != k), np.inf)
                else:
                    dd = np.linalg.norm(nuage - pt, axis=1)
                    dd[ids == k] = np.inf
                    near = float(dd.min())
                if near < ecart:
                    lignes[k] = l = l[:-1] if fin else l[1:]
                    change = True
        if not change:
            break
    return [l for l in lignes if len(l) >= 2]


def rogner(points, marge=ROGNAGE_BOUTS):
    ecarts = np.linalg.norm(np.diff(points, axis=0), axis=1)
    abscisse = np.concatenate([[0.0], np.cumsum(ecarts)])
    total = abscisse[-1]
    if total <= 2 * marge + 2:
        return None
    garde = points[(abscisse >= marge) & (abscisse <= total - marge)]
    return garde if len(garde) >= 2 else None


def chemin_bezier(points):
    """Convertit un trait en courbe de Bézier lisse (Catmull-Rom)."""
    p = points
    n = len(p)
    if n == 2:
        return (f"M {p[0][0]:.1f} {p[0][1]:.1f} "
                f"L {p[1][0]:.1f} {p[1][1]:.1f}")
    morceaux = [f"M {p[0][0]:.1f} {p[0][1]:.1f}"]
    for i in range(n - 1):
        p0 = p[i - 1] if i > 0 else p[i]
        p1, p2 = p[i], p[i + 1]
        p3 = p[i + 2] if i + 2 < n else p2
        c1 = p1 + (p2 - p0) / 6.0
        c2 = p2 - (p3 - p1) / 6.0
        morceaux.append(f"C {c1[0]:.1f} {c1[1]:.1f} "
                        f"{c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}")
    return " ".join(morceaux)


def calculer_traits(cretes, masque_clip=None, contact=None):
    """Image de crêtes (uint8, crêtes sombres) -> liste de traits (tableaux
    de points x,y), prêts à dessiner. Ne touche pas au disque.
    masque_clip : forme à ne pas dépasser (par défaut la silhouette).
    contact : True = bifurcations soudées ; False = aucun contact ;
              None = valeur par défaut AUTORISER_CONTACT.
    Toutes les tolérances sont calées sur l'interligne des crêtes mesuré sur
    l'image : le tracé s'adapte à la taille de l'empreinte, et aucun trait
    final ne fait moins de 2 interlignes — un trait de crête est long."""
    if contact is None:
        contact = AUTORISER_CONTACT
    from skimage.morphology import skeletonize

    periode = periode_cretes(cretes)              # interligne mesuré (px)
    # TOUTES les tolérances se déduisent de cet interligne : le tracé d'une
    # empreinte de bébé est celui d'un adulte, à l'échelle près.
    portee = max(PORTEE_PLANCHER,                 # base de mesure des tangentes
                 PORTEE_TANGENTE * periode)
    seuil = max(LONGUEUR_PLANCHER, LONGUEUR_MINI_PERIODES * periode)
    pas = pas_pour(periode)                       # espacement des points
    ecart = ecart_mini_pour(periode)              # « sans contact » garanti
    portee_pont = max(PONT_PLANCHER, PONT_PORTEE * periode)
    courbure = COURBURE_RAYON / max(periode, 1.0)  # °/px (voir COURBURE_RAYON)
    champ = champ_orientation(cretes, periode)    # l'arbitre du pontage
    coupures = []                                 # coutures repérées (partagées)

    squelette = skeletonize(cretes < 128)
    squelette = ebarber(squelette, BARBE_MAXI * periode)   # plus de barbes

    # 1. une crête traverse ses carrefours d'un seul trait
    lignes, extremites = extraire_lignes_avec_noeuds(squelette)
    lignes = apparier_jonctions(lignes, extremites, portee)

    # un fragment plus court qu'un tiers d'interligne n'est pas une crête
    lignes = [lisser(reechantillonner(l, pas), passes=1)
              for l in lignes if longueur(l) >= max(2.0, 0.3 * periode)]

    # 2. les crêtes cassées sont pontées (reconstruction, pas un contact)
    lignes = ponter_coupures(lignes, dist_max=portee_pont,
                             angle_max=ANGLE_PONT,
                             decalage_max=PONT_DECALAGE * periode,
                             portee=portee,
                             portee_longue=TANGENTE_LONGUE * periode,
                             marge_voisine=MARGE_VOISINE * periode,
                             champ=champ, periode=periode, coupures=coupures,
                             pas=pas)

    morceaux = []
    for l in lignes:
        l = lisser(reechantillonner(l, pas), passes=2)
        # jamais de demi-tour serré ; le seuil suit l'interligne
        for coupe in couper_epingles(l, courbure):
            morceaux += defaire_gouttes(          # ni goutte ni spirale
                coupe,
                pince=float(np.clip(PINCE_PERIODES * periode,
                                    PINCE_PLANCHER, DIST_PINCE)),
                separation=max(SEPARATION_PLANCHER,
                               SEPARATION_PERIODES * periode))
    morceaux = [m for m in morceaux if longueur(m) >= max(2.0, 0.2 * periode)]

    # 3. micro-traits : on essaie de les recoller AVANT de les jeter
    morceaux = ponter_coupures(morceaux,
                               dist_max=max(PONT_PLANCHER,
                                            RATTRAPAGE_PORTEE * periode),
                               angle_max=RATTRAPAGE_ANGLE,
                               decalage_max=0.6 * periode,
                               portee=portee,
                               portee_longue=TANGENTE_LONGUE * periode,
                               seuil_court=seuil, passes=3,
                               marge_voisine=MARGE_VOISINE * periode,
                               champ=champ, periode=periode,
                               coupures=coupures, pas=pas)
    morceaux = absorber_doublons(morceaux, DOUBLON_ECART * periode, seuil)

    finales = []
    rognage = float(np.clip(ROGNAGE_PERIODES * periode,
                            ROGNAGE_PLANCHER, ROGNAGE_BOUTS))
    for morceau in morceaux:
        if longueur(morceau) < 0.7 * seuil:       # vraiment isolé et minuscule
            continue
        if not contact:
            morceau = rogner(morceau, rognage)    # rétrécit pour ne pas toucher
        if morceau is not None:
            finales.append(morceau)

    # faute de partenaire, un bout se prolonge TOUT DROIT (jamais de crochet)
    finales = prolonger_bouts(finales, champ=champ, ecart=ecart,
                              ext_max=float(np.clip(EXT_PERIODES * periode,
                                                    EXT_PLANCHER, EXT_MAX)),
                              pas=pas)
    if masque_clip is None:
        masque_clip = _masque_forme(cretes, periode)
    finales = clipper(finales, masque_clip)       # bord net
    # DERNIER contrôle d'épingle. couper_epingles ne passait qu'AVANT le
    # rattrapage des micro-traits : les raccords de ce 2e pontage et les
    # prolongements, posés après, n'étaient contrôlés par personne — un
    # crochet du squelette recollé là ressortait en demi-tour dans le dessin
    # final. Le seuil est le même qu'au premier passage : ce filet de
    # sécurité ne peut pas couper une courbe que l'on avait déjà acceptée.
    finales = [m for l in finales for m in couper_epingles(l, courbure)]
    finales = [l for l in finales if longueur(l) >= seuil]
    if contact:
        # portée de soudure calée sur l'interligne (voir SOUDURE_BIFURCATION)
        finales = souder_bifurcations(            # les Y se touchent (Gabor)
            finales, seuil=float(np.clip(SOUDURE_BIFURCATION * periode,
                                         SOUDURE_MINI, SOUDURE_MAXI)),
            champ=champ, lateral_max=SOUDURE_LATERALE * periode,
            coupures=coupures, tolerance=COUTURE_TOLERANCE * periode, pas=pas)
    else:
        # deux gardes complémentaires, et il faut les DEUX : ecarter_corps
        # ouvre les frôlements en plein milieu d'un trait (que ecarter_bouts
        # ne peut pas voir), ecarter_bouts finit le travail aux extrémités —
        # y compris sur les bouts que ecarter_corps vient de créer.
        finales = ecarter_corps(finales, ecart, seuil)
        finales = ecarter_bouts(finales, ecart)
    return [l for l in finales if longueur(l) >= seuil]


def entete_svg(w, h, fond="white"):
    balises = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
               f'width="{w}" height="{h}">']
    if fond:
        balises.append(f'<rect width="100%" height="100%" fill="{fond}"/>')
    return balises


def groupe_traits(finales, largeur_trait=LARGEUR_TRAIT, couleur="black"):
    """Bloc <g> de traits (courbes de Bézier lisses)."""
    lignes = [f'<g fill="none" stroke="{couleur}" stroke-width="{largeur_trait}" '
              'stroke-linecap="round" stroke-linejoin="round">']
    lignes += [f'<path d="{chemin_bezier(l)}"/>' for l in finales]
    lignes.append("</g>")
    return lignes


def ecrire_svg(finales, w, h, chemin_svg, largeur_trait=LARGEUR_TRAIT,
               fond="white"):
    """Écrit une liste de traits en fichier SVG. Retourne leur nombre."""
    morceaux = entete_svg(w, h, fond)
    morceaux += groupe_traits(finales, largeur_trait)
    morceaux.append("</svg>")
    with open(chemin_svg, "w") as f:
        f.write("\n".join(morceaux))
    return len(finales)


def chemin_bezier_ferme(points):
    """Contour fermé lissé (Catmull-Rom qui boucle) pour une forme pleine."""
    p = points
    n = len(p)
    if n < 3:
        return chemin_bezier(points)
    morceaux = [f"M {p[0][0]:.1f} {p[0][1]:.1f}"]
    for i in range(n):
        p0, p1, p2, p3 = p[(i - 1) % n], p[i], p[(i + 1) % n], p[(i + 2) % n]
        c1 = p1 + (p2 - p0) / 6.0
        c2 = p2 - (p3 - p1) / 6.0
        morceaux.append(f"C {c1[0]:.1f} {c1[1]:.1f} "
                        f"{c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}")
    morceaux.append("Z")
    return " ".join(morceaux)


def contours_remplis(cretes, masque_clip=None, echelle=2, aire_min=None):
    """Style « Gabor plein » vectorisé : crêtes -> contours pleins lissés
    (fini les pixels en escalier). Retourne une liste de contours (x, y).
    `aire_min=None` : la plus petite tache gardée vaut 0,1 interligne² —
    45 px² fixes, c'était un dixième de crête chez l'adulte mais une crête
    entière chez le bébé, dont les traits disparaissaient en masse."""
    if aire_min is None:
        aire_min = max(6.0, 0.10 * periode_cretes(cretes) ** 2)
    ridge = ((cretes < 128).astype(np.uint8)) * 255
    if masque_clip is not None:
        ridge = cv2.bitwise_and(ridge, masque_clip)
    up = cv2.resize(ridge, None, fx=echelle, fy=echelle,
                    interpolation=cv2.INTER_LINEAR)
    up = cv2.GaussianBlur(up, (0, 0), echelle * 0.9)
    plein = (up > 100).astype(np.uint8) * 255
    plein = cv2.morphologyEx(plein, cv2.MORPH_CLOSE,
                             cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    contours, _ = cv2.findContours(plein, cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
    sortie = []
    seuil = aire_min * echelle * echelle
    for c in contours:
        if cv2.contourArea(c) < seuil:
            continue
        pts = c.reshape(-1, 2).astype(np.float64) / echelle
        if len(pts) >= 6:
            pts = lisser(reechantillonner(pts, pas=2.0), fenetre=5, passes=1)
        sortie.append(pts)
    return sortie


def groupe_contours(contours, couleur="black"):
    """Bloc <g> de formes pleines (contours lissés fermés)."""
    lignes = [f'<g fill="{couleur}" stroke="none">']
    lignes += [f'<path d="{chemin_bezier_ferme(c)}"/>' for c in contours]
    lignes.append("</g>")
    return lignes


def tracer_svg(cretes, chemin_svg, largeur_trait=None):
    """Image de crêtes (uint8, crêtes sombres) -> fichier SVG.
    Retourne le nombre de traits dessinés.
    `largeur_trait=None` : l'épaisseur est calculée sur l'interligne mesuré —
    le dessin reste lisible et gravable, crêtes d'adulte comme de bébé."""
    finales = calculer_traits(cretes)
    h, w = cretes.shape
    if largeur_trait is None:
        largeur_trait = largeur_trait_pour(periode_cretes(cretes))
    return ecrire_svg(finales, w, h, chemin_svg, largeur_trait)


def principal():
    if len(sys.argv) < 2:
        sys.exit("Utilisation : python3 tracer_svg.py image_cretes.png [sortie.svg]")
    entree = sys.argv[1]
    sortie = sys.argv[2] if len(sys.argv) > 2 \
        else os.path.splitext(entree)[0] + ".svg"
    image = cv2.imread(entree, cv2.IMREAD_GRAYSCALE)
    if image is None:
        sys.exit(f"Illisible : {entree}")
    nb = tracer_svg(image, sortie)
    print(f"{nb} traits -> {sortie}")


if __name__ == "__main__":
    principal()
