#!/usr/bin/env python3
"""
formes.py — assemble plusieurs empreintes dans une forme (ovale simple,
cœur, trèfle) pour la gravure. Chaque empreinte remplit son « lobe » ;
un fin espace sépare les lobes pour qu'ils ne se touchent pas.

Trois styles de rendu, tous exportés en SVG :
  - "gabor"   : crêtes pleines vectorisées (lissées, plus de pixels) ;
  - "sans"    : traits fins qui ne se touchent pas ;
  - "contact" : traits fins avec bifurcations soudées (comme le Gabor).

Formes selon le nombre d'empreintes :
  - "simple" : n ovales côte à côte ;
  - "coeur"  : 2 moitiés (2 empreintes) ;
  - "trefle" : 3 ou 4 lobes en trèfle.

Utilisation autonome (test) :
    python3 formes.py coeur contact sortie.svg a.png b.png
  où a.png / b.png sont des mosaïques (niveaux de gris) d'empreintes.
"""

import os
import sys
from collections import OrderedDict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import completer_empreinte
import fusionner_empreinte
import tracer_svg

ESPACE = 22               # épaisseur du fin espace entre deux lobes (px)
RAYON_LOBE = 430          # rayon de référence d'un lobe (px)
MARGE = 60                # marge blanche autour de la forme (px)
INCLINAISON_COEUR = 20    # les 2 empreintes du cœur penchent (en miroir), en °

# Mémoire des cartes de crêtes déjà calculées (la complétion est l'étape la
# plus longue du rendu). Clé = CONTENU exact de l'empreinte posée dans son
# lobe + masque du lobe + réglages : passer d'un style à l'autre, revenir à
# une forme déjà vue ou retoucher une seule empreinte d'une commande ne
# recalcule que ce qui a vraiment changé. Le résultat est le même qu'en
# recalculant. Les tracés eux-mêmes sont gardés par tracer_svg.
MEMOIRE_CRETES_MAX = 16   # ~1 à 3 Mo par carte
_MEMOIRE_CRETES = OrderedDict()


def _prechauffer():
    """Charge en arrière-plan les modules lourds du tracé (skimage, scipy :
    ~0,5 s) pendant que l'app s'ouvre et qu'on scanne, pour que le premier
    aperçu ne les attende pas. Sans effet sur le résultat."""
    try:
        import skimage.morphology  # noqa: F401
        import scipy.spatial  # noqa: F401
    except Exception:
        pass


try:
    import threading as _threading
    _threading.Thread(target=_prechauffer, name="prechauffage",
                      daemon=True).start()
except Exception:
    pass


def vider_cache():
    """Oublie toutes les cartes de crêtes et tous les tracés gardés."""
    with tracer_svg._VERROU_MEMOIRE:
        _MEMOIRE_CRETES.clear()
        _MEMOIRE_MASQUES.clear()
    tracer_svg.vider_cache()


_ATELIER_TRACES = None


def _atelier_traces():
    """Un fil de calcul pour tracer une empreinte pendant que la suivante se
    complète (voir composer)."""
    global _ATELIER_TRACES
    if _ATELIER_TRACES is None:
        from concurrent.futures import ThreadPoolExecutor
        _ATELIER_TRACES = ThreadPoolExecutor(max_workers=1,
                                             thread_name_prefix="trace")
    return _ATELIER_TRACES


class _Fait:
    """Tâche exécutée sur-le-champ, présentée comme une tâche en attente
    (même .result() qu'un Future : l'erreur éventuelle ressort à la lecture,
    dans l'ordre des lobes)."""

    def __init__(self, fonction, *arguments):
        try:
            self._resultat, self._erreur = fonction(*arguments), None
        except Exception as erreur:
            self._resultat, self._erreur = None, erreur

    def result(self):
        if self._erreur is not None:
            raise self._erreur
        return self._resultat

# Ajustement fin d'une empreinte dans son lobe (voir appliquer_ajust).
AJUST_NEUTRE = {"dx": 0.0, "dy": 0.0, "angle": 0.0}

# L'app peut nommer les formes/styles autrement (« trefle3 », « traits »…) :
# on accepte ces synonymes pour ne rien casser des deux côtés.
ALIAS_FORMES = {"trefle3": "trefle", "trefle4": "trefle", "trèfle": "trefle",
                "cœur": "coeur", "ovale": "simple"}
ALIAS_STYLES = {"traits": "contact", "traits_soudes": "contact",
                "soude": "contact", "traits_fins": "sans", "fins": "sans",
                "plein": "gabor"}


def nom_forme(forme):
    """Nom canonique d'une forme (« trefle3 » -> « trefle »)."""
    forme = (forme or "simple").strip().lower()
    return ALIAS_FORMES.get(forme, forme)


def nom_style(style):
    """Nom canonique d'un style (« traits » -> « contact »)."""
    style = (style or "contact").strip().lower()
    return ALIAS_STYLES.get(style, style)


# --------------------------------------------------------------------------
# Masques de forme : renvoient (hauteur, largeur, contour, [masques de lobe])
# --------------------------------------------------------------------------

def _remplir(canvas_hw, polygone):
    m = np.zeros(canvas_hw, np.uint8)
    cv2.fillPoly(m, [np.round(polygone).astype(np.int32)], 255)
    return m


def _disque(canvas_hw, centre, rayon):
    m = np.zeros(canvas_hw, np.uint8)
    cv2.circle(m, (int(round(centre[0])), int(round(centre[1]))),
               int(round(rayon)), 255, -1)
    return m


def forme_ovale(n=1, rayon=RAYON_LOBE):
    """n ovales côte à côte (mode simple)."""
    rx, ry = int(rayon * 0.82), int(rayon * 1.02)
    h = 2 * ry + 2 * MARGE
    w = n * (2 * rx) + (n + 1) * MARGE
    contour = np.zeros((h, w), np.uint8)
    lobes = []
    for i in range(n):
        cx = MARGE + rx + i * (2 * rx + MARGE)
        cy = h // 2
        lobe = np.zeros((h, w), np.uint8)
        cv2.ellipse(lobe, (cx, cy), (rx, ry), 0, 0, 360, 255, -1)
        lobes.append(lobe)
        cv2.ellipse(contour, (cx, cy), (rx, ry), 0, 0, 360, 255, -1)
    return h, w, contour, lobes, [(0.0, 0.0)] * n     # (orbite, sur-soi)


def forme_coeur(rayon=RAYON_LOBE, espace=ESPACE):
    """Cœur, séparé en moitié gauche / moitié droite (2 empreintes)."""
    t = np.linspace(0, 2 * np.pi, 800)
    x = 16 * np.sin(t) ** 3
    y = (13 * np.cos(t) - 5 * np.cos(2 * t)
         - 2 * np.cos(3 * t) - np.cos(4 * t))
    echelle = rayon * 2.0 / (x.max() - x.min())
    w = int((x.max() - x.min()) * echelle) + 2 * MARGE
    h = int((y.max() - y.min()) * echelle) + 2 * MARGE
    cx = MARGE - x.min() * echelle
    cy = MARGE + y.max() * echelle                 # image : y vers le bas
    poly = np.stack([cx + x * echelle, cy - y * echelle], 1)
    coeur = _remplir((h, w), poly)

    milieu = int(round(cx))
    gauche = coeur.copy()
    gauche[:, milieu - espace // 2:] = 0
    droite = coeur.copy()
    droite[:, :milieu + espace // 2] = 0
    # les deux empreintes penchent en miroir (sur elles-mêmes)
    t = INCLINAISON_COEUR
    return h, w, coeur, [gauche, droite], [(0.0, t), (0.0, -t)]


def forme_trefle(n, rayon=RAYON_LOBE, espace=ESPACE):
    """Trèfle à n feuilles (n = 3 ou 4) : n disques autour du centre,
    partagés au plus proche centre, avec un fin espace entre les lobes."""
    if n == 3:
        angles = [270, 30, 150]                    # une feuille en haut
        distance = rayon * 0.95
    else:                                          # n == 4
        angles = [45, 135, 225, 315]
        distance = rayon * 1.02
    taille = int(2 * (distance + rayon) + 2 * MARGE)
    h = w = taille
    cx, cy = w / 2, h / 2
    centres = [(cx + distance * np.cos(np.radians(a)),
                cy + distance * np.sin(np.radians(a))) for a in angles]

    disques = [_disque((h, w), c, rayon) for c in centres]
    union = np.zeros((h, w), np.uint8)
    for d in disques:
        union = cv2.bitwise_or(union, d)

    # étiquette chaque pixel au centre le plus proche
    ys, xs = np.mgrid[0:h, 0:w]
    d2 = np.stack([(xs - c[0]) ** 2 + (ys - c[1]) ** 2 for c in centres])
    plus_proche = np.argmin(d2, axis=0)

    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (espace, espace))
    lobes, contour = [], np.zeros((h, w), np.uint8)
    for i in range(n):
        region = (((plus_proche == i) & (union > 0)) * 255).astype(np.uint8)
        region = cv2.erode(region, noyau)          # fin espace entre lobes
        lobes.append(region)
        contour = cv2.bitwise_or(contour, region)
    # rotation À TOUTE LA TOILE pour amener l'empreinte posée dans le 1er lobe
    # jusqu'au lobe i (rotation autour du centre du trèfle) ; pas de sur-soi.
    orbites = [(angles[0] - a) % 360 for a in angles]
    return h, w, contour, lobes, [(o, 0.0) for o in orbites]


_MEMOIRE_MASQUES = OrderedDict()


def masques(forme, n):
    """Aiguilleur : renvoie (h, w, contour, [lobes], [rotations]).
    Les masques ne dépendent que de la forme, du nombre d'empreintes et des
    réglages ci-dessus : on les garde (le trèfle demande ~0,1 s à dessiner)
    et on rend des copies."""
    forme = nom_forme(forme)
    cle = (forme, int(n) if forme != "coeur" else 0,
           tracer_svg._reglages_du_module(globals()))
    deja = tracer_svg._lire_memoire(_MEMOIRE_MASQUES, cle)
    if deja is None or not tracer_svg.CACHE_ACTIF:
        if forme == "coeur":
            deja = forme_coeur()
        elif forme == "trefle":
            deja = forme_trefle(n)
        else:
            deja = forme_ovale(n)                  # "simple"
        if tracer_svg.CACHE_ACTIF:
            tracer_svg._ranger_memoire(_MEMOIRE_MASQUES, cle, deja, 4)
    h, w, contour, lobes, transforms = deja
    return h, w, contour.copy(), [l.copy() for l in lobes], list(transforms)


# --------------------------------------------------------------------------
# Placer une empreinte dans un lobe
# --------------------------------------------------------------------------

def _bbox(masque):
    ys, xs = np.where(masque > 0)
    return xs.min(), ys.min(), xs.max(), ys.max()


def tourner_sur_elle_meme(mosaique, degres):
    """Tourne l'empreinte sur elle-même (toile agrandie, fond blanc)."""
    if abs(degres) < 0.5:
        return mosaique
    h, w = mosaique.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), degres, 1.0)
    cos, sin = abs(M[0, 0]), abs(M[0, 1])
    nw, nh = int(h * sin + w * cos), int(h * cos + w * sin)
    M[0, 2] += nw / 2 - w / 2
    M[1, 2] += nh / 2 - h / 2
    return cv2.warpAffine(mosaique, M, (nw, nh), flags=cv2.INTER_LINEAR,
                          borderValue=255)


def tourner_autour_du_centre(toile, degres):
    """Tourne TOUTE la toile autour de son centre (fond blanc, taille gardée).
    C'est la rotation « autour du centre du trèfle » : l'empreinte posée en
    haut se retrouve dans le lobe suivant, orientée en conséquence."""
    if abs(degres) < 0.5:
        return toile
    h, w = toile.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), degres, 1.0)
    return cv2.warpAffine(toile, M, (w, h), flags=cv2.INTER_LINEAR,
                          borderValue=255)


def centre_lobe(lobe):
    """Centre (x, y) de la boîte englobante d'un lobe, en pixels du canevas."""
    lx0, ly0, lx1, ly1 = _bbox(lobe)
    return (lx0 + lx1) / 2.0, (ly0 + ly1) / 2.0


def appliquer_ajust(toile, lobe, ajust, rayon=RAYON_LOBE):
    """Retouche fine de l'empreinte DANS son lobe, telle que l'utilisateur la
    ressent en faisant glisser l'empreinte dans l'aperçu.

    `toile` est l'empreinte DÉJÀ placée dans la forme (image de la taille du
    canevas final, fond blanc) ; `lobe` est le masque de son lobe.
    `ajust` = {"dx", "dy", "angle"} :

      1. rotation supplémentaire de `angle` DEGRÉS autour du centre du lobe,
         angle > 0 = sens HORAIRE à l'écran ;
      2. puis translation de (dx, dy) × `rayon` pixels dans le repère du
         canevas FINAL : dx > 0 = vers la DROITE à l'écran, dy > 0 = vers
         le BAS. dx/dy valent typiquement −1..1 (fraction du rayon de lobe).

    L'ordre compte : on tourne l'empreinte sur place, ensuite on la déplace.
    Le lobe, lui, ne bouge pas : le découpage final se fait toujours sur le
    lobe d'origine, donc l'empreinte « glisse » derrière sa fenêtre.
    Les zones découvertes restent blanches (la complétion les remplira).
    """
    if not ajust:
        return toile
    dx = float(ajust.get("dx", 0.0) or 0.0)
    dy = float(ajust.get("dy", 0.0) or 0.0)
    angle = float(ajust.get("angle", 0.0) or 0.0)
    if abs(dx) < 1e-4 and abs(dy) < 1e-4 and abs(angle) < 1e-3:
        return toile
    h, w = toile.shape
    cx, cy = centre_lobe(lobe)
    # OpenCV tourne dans le sens ANTI-horaire pour un angle positif : on
    # inverse le signe pour que angle > 0 = horaire, comme à l'écran.
    M = cv2.getRotationMatrix2D((cx, cy), -angle, 1.0)
    M[0, 2] += dx * rayon                          # translation après rotation
    M[1, 2] += dy * rayon
    return cv2.warpAffine(toile, M, (w, h), flags=cv2.INTER_LINEAR,
                          borderValue=255)


def poser_dans_lobe(mosaique, lobe, couverture=1.12):
    """Met à l'échelle la mosaïque pour couvrir le lobe et la pose sur une
    toile blanche de la taille du lobe (à l'endroit, sans rotation)."""
    h, w = lobe.shape
    lx0, ly0, lx1, ly1 = _bbox(lobe)
    lw, lh = lx1 - lx0, ly1 - ly0
    mh, mw = mosaique.shape
    echelle = max(lw / mw, lh / mh) * couverture
    redim = cv2.resize(mosaique, None, fx=echelle, fy=echelle,
                       interpolation=cv2.INTER_AREA)
    rh, rw = redim.shape
    # centre la mosaïque sur le centre du lobe
    ccx, ccy = (lx0 + lx1) / 2, (ly0 + ly1) / 2
    x0 = int(round(ccx - rw / 2))
    y0 = int(round(ccy - rh / 2))
    toile = np.full((h, w), 255, np.uint8)
    # zone de recouvrement source/destination
    dx0, dy0 = max(x0, 0), max(y0, 0)
    dx1, dy1 = min(x0 + rw, w), min(y0 + rh, h)
    sx0, sy0 = dx0 - x0, dy0 - y0
    toile[dy0:dy1, dx0:dx1] = redim[sy0:sy0 + (dy1 - dy0),
                                    sx0:sx0 + (dx1 - dx0)]
    return toile


# --------------------------------------------------------------------------
# Composition
# --------------------------------------------------------------------------

def _recadrer_mosaique(mosaique, crop):
    """Découpe la zone cadrée par l'utilisateur (crop = cx, cy, hw, hh en
    fractions [0,1] de la mosaïque). Si le cadre dépasse la mosaïque
    (« pris trop large »), la zone manquante est blanche : la complétion
    prolongera les crêtes jusqu'au bord."""
    if crop is None:
        return mosaique
    cx, cy, hw, hh = crop
    H, W = mosaique.shape
    x0 = cx * W - hw * W
    y0 = cy * H - hh * H
    ow = max(1, int(round(2 * hw * W)))
    oh = max(1, int(round(2 * hh * H)))
    out = np.full((oh, ow), 255, np.uint8)
    sx0, sy0 = int(round(x0)), int(round(y0))
    dxa, dya = max(0, -sx0), max(0, -sy0)          # décalage dans la sortie
    sxa, sya = max(0, sx0), max(0, sy0)            # début dans la source
    sxb, syb = min(W, sx0 + ow), min(H, sy0 + oh)
    if sxb > sxa and syb > sya:
        out[dya:dya + (syb - sya), dxa:dxa + (sxb - sxa)] = \
            mosaique[sya:syb, sxa:sxb]
    return out


def recadrer_mosaique(mosaique, crop):
    """Version publique de _recadrer_mosaique : magasin_commandes s'en sert
    pour fabriquer photo.png EXACTEMENT comme le rendu découpe l'empreinte."""
    return _recadrer_mosaique(mosaique, crop)


def _cretes_brutes(toile, lobe_net):
    """Complétion OFF : uniquement les vraies crêtes (Gabor), masquées à la
    zone de doigt réelle ∩ lobe. Les trous restent blancs, bord brut."""
    import ameliorer_empreinte
    from fusionner_empreinte import masque_doigt
    cretes = ameliorer_empreinte.cretes_gabor(ameliorer_empreinte.ameliorer(toile))
    if cretes is None:                              # Gabor a échoué : on complète
        return completer_empreinte.completer(toile, domaine_force=lobe_net)
    if cretes.shape != toile.shape:                 # ameliorer peut agrandir
        cretes = cv2.resize(cretes, (toile.shape[1], toile.shape[0]),
                            interpolation=cv2.INTER_AREA)
    garde = (masque_doigt(toile) > 0) & (lobe_net > 0)
    sortie = np.full((toile.shape[0], toile.shape[1]), 255, np.uint8)
    sortie[garde] = cretes[garde]
    return sortie


def _cretes_du_lobe(toile, lobe_net, completer):
    """Carte de crêtes d'une empreinte posée dans son lobe : complétée
    (completer=True) ou brute (Gabor seul). Gardée en mémoire, voir
    MEMOIRE_CRETES_MAX. On rend toujours une COPIE."""
    calcul = (lambda: completer_empreinte.completer(toile, domaine_force=lobe_net)) \
        if completer else (lambda: _cretes_brutes(toile, lobe_net))
    if not tracer_svg.CACHE_ACTIF:
        return calcul()
    import ameliorer_empreinte
    reglages = (tracer_svg._reglages_du_module(vars(completer_empreinte))
                + (tracer_svg._reglages_du_module(vars(ameliorer_empreinte))
                   if not completer else ""))
    cle = tracer_svg._cle_contenu("cretes", toile, lobe_net, bool(completer),
                                  reglages=reglages)
    deja = tracer_svg._lire_memoire(_MEMOIRE_CRETES, cle)
    if deja is None:
        deja = calcul()
        tracer_svg._ranger_memoire(_MEMOIRE_CRETES, cle, deja.copy(),
                                   MEMOIRE_CRETES_MAX)
    return deja.copy()


def _periode_cretes(cretes):
    """Espacement moyen des crêtes (interligne), en px.

    UNE SEULE MESURE POUR TOUT LE RENDU : c'est exactement celle dont
    tracer_svg tire ses tolérances. L'épaisseur du trait et la géométrie du
    tracé ne peuvent donc pas se contredire — un « Gabor plein » calé sur une
    période et des traits calés sur une autre donneraient, sur la même
    empreinte, des crêtes trop grasses ou trop maigres."""
    return tracer_svg.periode_cretes(cretes)


def _rasteriser(traits, h, w, chemin_png, largeur_trait, cote_max=1100):
    """Aperçu PNG (rapide) des traits, pour l'affichage dans l'app."""
    echelle = min(1.0, cote_max / max(h, w))
    img = np.full((int(h * echelle), int(w * echelle), 3), 255, np.uint8)
    ep = max(1, int(round(largeur_trait * echelle)))
    for t in traits:
        cv2.polylines(img, [np.round(t * echelle).astype(np.int32)], False,
                      (0, 0, 0), ep, cv2.LINE_AA)
    cv2.imwrite(chemin_png, img)


def composer(mosaiques, forme, style, chemin_svg, apercu_png=None,
             crops=None, completions=None,
             largeur_trait=None, tracer_contour=False,
             ajusts=None):
    """Assemble les mosaïques dans la forme et écrit le SVG (+ un PNG d'aperçu
    si apercu_png est donné).
    crops : liste de (cx, cy, hw, hh) normalisés par empreinte, ou None.
    completions : liste de booléens (compléter les trous ?) par empreinte.
    ajusts : liste de {dx, dy, angle} (ou None) par empreinte — retouche fine
             du placement dans le lobe, voir appliquer_ajust.
    largeur_trait : épaisseur du trait en px. None = calculée sur l'INTERLIGNE
             mesuré de l'empreinte — c'est le cas normal. Une empreinte de
             bébé a des crêtes environ deux fois plus serrées : un trait
             d'épaisseur fixe y ferait fusionner deux crêtes voisines à la
             gravure. Le trait garde donc la même part de l'interligne à
             toutes les tailles (et le « gabor plein », déjà calé sur la
             période, reste cohérent avec lui).
    style : "gabor" | "sans" | "contact" | "photo". Renvoie (chemin, nb)."""
    forme, style = nom_forme(forme), nom_style(style)
    n = len(mosaiques)
    h, w, contour, lobes, transforms = masques(forme, n)

    # style "photo" : on montre la vraie photo (mosaïque) découpée, pas un tracé
    if style == "photo":
        return _composer_photo(mosaiques, lobes, transforms, crops, h, w,
                               chemin_svg, apercu_png, ajusts)

    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

    def tracer_lobe(cretes, lobe_net):
        # tous les styles partent du squelette (crêtes bien séparées) ; le
        # "gabor plein" ne fait que les dessiner épais -> jamais de blob noir,
        # les vallées entre crêtes restent toujours visibles.
        traits_lobe = tracer_svg.calculer_traits(
            cretes, masque_clip=lobe_net, contact=(style != "sans"))
        # l'épaisseur suit l'INTERLIGNE de CETTE empreinte (voir composer)
        periode = _periode_cretes(cretes)
        return traits_lobe, (periode * 0.52 if style == "gabor"
                             else tracer_svg.largeur_trait_pour(periode))

    # À la chaîne : pendant que l'empreinte i se trace (calcul Python, sur un
    # fil à part), l'empreinte i+1 se complète (OpenCV / numpy, sur tous les
    # cœurs). Les tracés sont repris DANS L'ORDRE des lobes : le dessin est
    # exactement celui d'un calcul l'un après l'autre.
    en_cours = []
    nb_lobes = min(len(mosaiques), len(lobes), len(transforms))
    try:
        for i, (mosaique, lobe, (orbite, sur_soi)) in enumerate(
                zip(mosaiques, lobes, transforms)):
            crop = crops[i] if crops else None
            completer = completions[i] if completions else True
            mos = tourner_sur_elle_meme(_recadrer_mosaique(mosaique, crop),
                                        sur_soi)
            if orbite == 0:
                toile = poser_dans_lobe(mos, lobe)         # posée directement
            else:
                # posée à l'endroit dans le 1er lobe, puis toute la toile
                # tourne autour du centre pour l'amener (orientée) dans ce
                # lobe-ci
                toile = poser_dans_lobe(mos, lobes[0])
                toile = tourner_autour_du_centre(toile, orbite)
            # retouche fine demandée par l'utilisateur (glisser / tourner)
            toile = appliquer_ajust(toile, lobe, ajusts[i] if ajusts else None)
            lobe_net = cv2.erode(lobe, noyau)      # bord franc
            cretes = _cretes_du_lobe(toile, lobe_net, completer)  # (mémorisé)
            if apercu_png is not None:             # trace pour le diagnostic
                base = os.path.splitext(apercu_png)[0]
                cv2.imwrite(f"{base}_debug{i}_source.png", toile)
                cv2.imwrite(f"{base}_debug{i}_cretes.png", cretes)
            if i == nb_lobes - 1:                  # le dernier : tout de suite
                en_cours.append(_Fait(tracer_lobe, cretes, lobe_net))
            else:
                en_cours.append(_atelier_traces().submit(tracer_lobe, cretes,
                                                         lobe_net))
    except BaseException:
        for tache in en_cours:                     # une erreur de tracé d'un
            tache.result()                         # lobe d'avant passe d'abord
        raise
    traits, largeurs = [], []
    for tache in en_cours:
        traits_lobe, largeur_lobe = tache.result()
        traits += traits_lobe
        largeurs.append(largeur_lobe)

    if largeur_trait is not None:                  # épaisseur imposée
        largeur = float(largeur_trait)
    else:
        largeur = float(np.median(largeurs)) if largeurs \
            else tracer_svg.LARGEUR_TRAIT

    morceaux = tracer_svg.entete_svg(w, h)
    morceaux += tracer_svg.groupe_traits(traits, largeur)
    morceaux.append("</svg>")
    with open(chemin_svg, "w") as f:
        f.write("\n".join(morceaux))
    if apercu_png is not None:
        _rasteriser(traits, h, w, apercu_png, largeur)
    return chemin_svg, len(traits)


def _composer_photo(mosaiques, lobes, transforms, crops, h, w,
                    chemin_svg, apercu_png, ajusts=None):
    """Style « photo » : la vraie empreinte (niveaux de gris) découpée dans
    chaque lobe, sans tracé. SVG = image PNG embarquée (base64)."""
    import base64
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    compo = np.full((h, w), 255, np.uint8)
    for i, (mosaique, lobe, (orbite, sur_soi)) in enumerate(
            zip(mosaiques, lobes, transforms)):
        crop = crops[i] if crops else None
        mos = tourner_sur_elle_meme(_recadrer_mosaique(mosaique, crop), sur_soi)
        if orbite == 0:
            toile = poser_dans_lobe(mos, lobe)
        else:
            toile = tourner_autour_du_centre(poser_dans_lobe(mos, lobes[0]), orbite)
        toile = appliquer_ajust(toile, lobe, ajusts[i] if ajusts else None)
        lobe_net = cv2.erode(lobe, noyau)
        affiche = fusionner_empreinte.normaliser_affichage(toile)
        compo[lobe_net > 0] = affiche[lobe_net > 0]
    if apercu_png is not None:
        echelle = min(1.0, 1100.0 / max(h, w))
        cv2.imwrite(apercu_png, cv2.resize(compo, None, fx=echelle, fy=echelle,
                                           interpolation=cv2.INTER_AREA))
    ok, tampon = cv2.imencode(".png", compo)
    donnees = base64.b64encode(tampon.tobytes()).decode("ascii")
    with open(chemin_svg, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" '
                f'xmlns:xlink="http://www.w3.org/1999/xlink" '
                f'viewBox="0 0 {w} {h}" width="{w}" height="{h}">'
                f'<image width="{w}" height="{h}" '
                f'xlink:href="data:image/png;base64,{donnees}"/></svg>')
    return chemin_svg, 1


def principal():
    if len(sys.argv) < 5:
        sys.exit("Utilisation : python3 formes.py <forme> <style> sortie.svg "
                 "mosaique1.png [mosaique2.png ...]\n"
                 "  forme : simple | coeur | trefle (alias : trefle3, trefle4)\n"
                 "  style : gabor | sans | contact (alias : traits) | photo")
    forme, style, sortie = sys.argv[1], sys.argv[2], sys.argv[3]
    mosaiques = []
    for f in sys.argv[4:]:
        g = cv2.imread(f, cv2.IMREAD_GRAYSCALE)
        if g is None:
            sys.exit(f"Illisible : {f}")
        mosaiques.append(g)
    _, nb = composer(mosaiques, forme, style, sortie)
    print(f"{nb} éléments -> {sortie}")


if __name__ == "__main__":
    principal()
