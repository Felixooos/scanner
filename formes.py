#!/usr/bin/env python3
"""
formes.py — assemble plusieurs empreintes dans une forme (ovale simple,
cœur, trèfle, ovale coupé, tête-bêche) pour la gravure. Chaque empreinte
remplit son « lobe » ; un fin espace sépare les lobes pour qu'ils ne se
touchent pas.

Trois styles de rendu, tous exportés en SVG :
  - "gabor"   : crêtes pleines vectorisées (lissées, plus de pixels) ;
  - "sans"    : traits fins qui ne se touchent pas ;
  - "contact" : traits fins avec bifurcations soudées (comme le Gabor).

Formes selon le nombre d'empreintes :
  - "simple"     : n ovales côte à côte ;
  - "coeur"      : 2 moitiés (2 empreintes) ;
  - "trefle"     : 3 ou 4 lobes en trèfle ;
  - "ovale_lr"   : « Ovale coupé » — UN ovale (celui d'une empreinte seule)
                   coupé verticalement par un fin espace : empreinte 1 à
                   gauche, empreinte 2 à droite (exactement 2 empreintes) ;
  - "tete_beche" : « Tête-bêche » — le même ovale coupé horizontalement :
                   empreinte 1 droite en haut, empreinte 2 tournée de 180°
                   en bas (exactement 2 empreintes) ;
  - "separees"   : pas de composition, chaque empreinte est rendue SEULE
                   (rendre_seule) ; planche() les pose côte à côte pour
                   l'aperçu.
Pour l'ovale coupé et le tête-bêche, chaque empreinte est mise à l'échelle
comme si elle remplissait TOUT l'ovale (même échelle qu'une empreinte
seule), centrée sur le centre de l'ovale, puis découpée par sa moitié.

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
                "cœur": "coeur", "ovale": "simple",
                "ovale_coupe": "ovale_lr", "ovale-lr": "ovale_lr",
                "tete-beche": "tete_beche", "tête-bêche": "tete_beche",
                "tête_bêche": "tete_beche", "tetebeche": "tete_beche",
                "separee": "separees", "séparées": "separees",
                "separe": "separees"}
# Libellés de l'app (messages d'erreur, noms de fichiers exportés).
LIBELLES_FORMES = {"simple": "Simple", "separees": "Séparées", "coeur": "Cœur",
                   "trefle": "Trèfle", "ovale_lr": "Ovale coupé",
                   "tete_beche": "Tête-bêche"}
# Formes à nombre d'empreintes imposé (les autres : voir l'app).
NOMBRE_EXACT = {"ovale_lr": 2, "tete_beche": 2}
FORMES_COUPEES = ("ovale_lr", "tete_beche")
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


def erreur_nombre(forme, n):
    """Message d'erreur si la forme n'accepte pas n empreintes, sinon None.
    (« La forme « Ovale coupé » demande exactement 2 empreintes. »)"""
    forme = nom_forme(forme)
    attendu = NOMBRE_EXACT.get(forme)
    if attendu is not None and n != attendu:
        return (f"La forme « {LIBELLES_FORMES.get(forme, forme)} » demande "
                f"exactement {attendu} empreintes.")
    return None


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


def forme_ovale_coupe(sens, rayon=RAYON_LOBE, espace=ESPACE):
    """UN ovale — exactement celui d'une empreinte seule (forme_ovale(1)) —
    coupé en deux par un fin espace vide de `espace` px, comme le milieu du
    cœur (rien n'y est gravé).
      sens "vertical"   : « Ovale coupé » (ovale_lr), moitié GAUCHE pour
                          l'empreinte 1, moitié DROITE pour l'empreinte 2 ;
      sens "horizontal" : « Tête-bêche », moitié du HAUT pour l'empreinte 1
                          (droite), moitié du BAS pour l'empreinte 2, tournée
                          de 180° sur elle-même : on voit le haut de chacune.
    Renvoie (h, w, ovale entier, [moitié 1, moitié 2], [(orbite, sur-soi)])."""
    h, w, ovale, (plein,), _ = forme_ovale(1, rayon)
    cx = MARGE + int(rayon * 0.82)               # centre de forme_ovale(1)
    cy = h // 2
    un, deux = plein.copy(), plein.copy()
    if sens == "vertical":
        un[:, cx - espace // 2:] = 0
        deux[:, :cx + espace // 2] = 0
        return h, w, ovale, [un, deux], [(0.0, 0.0), (0.0, 0.0)]
    un[cy - espace // 2:, :] = 0
    deux[:cy + espace // 2, :] = 0
    return h, w, ovale, [un, deux], [(0.0, 0.0), (0.0, 180.0)]


_MEMOIRE_MASQUES = OrderedDict()


def _geometrie(forme, n):
    """Tout ce qu'il faut pour poser n empreintes dans la forme :
    (h, w, contour, [lobes], [(orbite, sur-soi)], [cadres], [centres]).
      cadres[i]  : masque sur lequel l'empreinte i est mise à l'échelle et
                   centrée — None = son propre lobe (cœur, trèfle, simple :
                   comme toujours) ; l'ovale ENTIER pour les formes coupées ;
      centres[i] : centre de rotation de son `ajust` — None = centre de son
                   lobe (comme toujours) ; centre de l'ovale pour les formes
                   coupées (l'empreinte y est centrée).
    Ne dépend que de la forme, du nombre d'empreintes et des réglages : gardé
    en mémoire (le trèfle demande ~0,1 s à dessiner). Ne pas modifier les
    tableaux rendus (masques() en donne des copies)."""
    forme = nom_forme(forme)
    cle = (forme, int(n) if forme not in ("coeur",) + FORMES_COUPEES else 0,
           tracer_svg._reglages_du_module(globals()))
    deja = tracer_svg._lire_memoire(_MEMOIRE_MASQUES, cle)
    if deja is None or not tracer_svg.CACHE_ACTIF:
        if forme == "coeur":
            base = forme_coeur()
        elif forme == "trefle":
            base = forme_trefle(n)
        elif forme == "ovale_lr":
            base = forme_ovale_coupe("vertical")
        elif forme == "tete_beche":
            base = forme_ovale_coupe("horizontal")
        else:
            base = forme_ovale(n)                  # "simple" (et "separees")
        h, w, contour, lobes, transforms = base
        if forme in FORMES_COUPEES:
            centre = centre_lobe(contour)
            cadres = [contour] * len(lobes)
            centres = [centre] * len(lobes)
        else:
            cadres = [None] * len(lobes)
            centres = [None] * len(lobes)
        deja = (h, w, contour, lobes, transforms, cadres, centres)
        if tracer_svg.CACHE_ACTIF:
            tracer_svg._ranger_memoire(_MEMOIRE_MASQUES, cle, deja, 4)
    return deja


def masques(forme, n):
    """Aiguilleur : renvoie (h, w, contour, [lobes], [rotations]) — des
    copies (voir _geometrie)."""
    h, w, contour, lobes, transforms = _geometrie(forme, n)[:5]
    return h, w, contour.copy(), [l.copy() for l in lobes], list(transforms)


# --------------------------------------------------------------------------
# Placer une empreinte dans un lobe
# --------------------------------------------------------------------------

def _bbox(masque):
    ys, xs = np.where(masque > 0)
    return xs.min(), ys.min(), xs.max(), ys.max()


def tourner_sur_elle_meme(mosaique, degres):
    """Tourne l'empreinte sur elle-même (toile agrandie, fond blanc).
    Un demi-tour (tête-bêche) est fait EXACTEMENT (retournement des pixels,
    sans interpolation)."""
    if abs(degres) < 0.5:
        return mosaique
    if abs((float(degres) % 360.0) - 180.0) < 1e-9:
        return np.ascontiguousarray(mosaique[::-1, ::-1])
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


def appliquer_ajust(toile, lobe, ajust, rayon=RAYON_LOBE, centre=None):
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
    `centre` : centre de la rotation (défaut : centre du lobe). Les formes
    coupées tournent l'empreinte autour du centre de l'ovale, où elle est
    posée.
    """
    if not ajust:
        return toile
    dx = float(ajust.get("dx", 0.0) or 0.0)
    dy = float(ajust.get("dy", 0.0) or 0.0)
    angle = float(ajust.get("angle", 0.0) or 0.0)
    if abs(dx) < 1e-4 and abs(dy) < 1e-4 and abs(angle) < 1e-3:
        return toile
    h, w = toile.shape
    cx, cy = centre_lobe(lobe) if centre is None else centre
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
    style : "gabor" | "sans" | "contact" | "photo". Renvoie (chemin, nb).
    forme : voir l'en-tête du module ; "separees" se compose ici comme
             "simple" (ovales côte à côte) — pour des empreintes vraiment
             SEULES, voir rendre_seule / planche.
    Lève ValueError (message prêt à afficher) si la forme exige un autre
    nombre d'empreintes (ovale coupé, tête-bêche : 2)."""
    forme, style = nom_forme(forme), nom_style(style)
    n = len(mosaiques)
    probleme = erreur_nombre(forme, n)
    if probleme:
        raise ValueError(probleme)
    geometrie = _geometrie(forme, n)
    h, w, contour, lobes, transforms = geometrie[:5]

    # style "photo" : on montre la vraie photo (mosaïque) découpée, pas un tracé
    if style == "photo":
        return _composer_photo(mosaiques, geometrie, crops, chemin_svg,
                               apercu_png, ajusts)

    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

    def tracer_lobe(cretes, lobe_net, i):
        # tous les styles partent du squelette (crêtes bien séparées) ; le
        # "gabor plein" ne fait que les dessiner épais -> jamais de blob noir,
        # les vallées entre crêtes restent toujours visibles.
        traits_lobe = tracer_svg.calculer_traits(
            cretes, masque_clip=lobe_net, contact=(style != "sans"))
        # l'épaisseur suit l'INTERLIGNE de CETTE empreinte (voir composer)
        periode = _periode_cretes(cretes)
        if forme in FORMES_COUPEES:                # coupure nette, sans miettes
            traits_lobe = _degager_coupure(traits_lobe, lobe_net, forme, i,
                                           periode)
        return traits_lobe, (periode * 0.52 if style == "gabor"
                             else tracer_svg.largeur_trait_pour(periode))

    # À la chaîne : pendant que l'empreinte i se trace (calcul Python, sur un
    # fil à part), l'empreinte i+1 se complète (OpenCV / numpy, sur tous les
    # cœurs). Les tracés sont repris DANS L'ORDRE des lobes : le dessin est
    # exactement celui d'un calcul l'un après l'autre.
    en_cours = []
    nb_lobes = min(len(mosaiques), len(lobes), len(transforms))
    try:
        for i, (mosaique, lobe) in enumerate(zip(mosaiques[:nb_lobes],
                                                 lobes)):
            crop = crops[i] if crops else None
            completer = completions[i] if completions else True
            toile = _poser(mosaique, i, geometrie, crop,
                           ajusts[i] if ajusts else None)
            lobe_net = cv2.erode(lobe, noyau)      # bord franc
            cretes = _cretes_du_lobe(toile, lobe_net, completer)  # (mémorisé)
            if apercu_png is not None:             # trace pour le diagnostic
                base = os.path.splitext(apercu_png)[0]
                cv2.imwrite(f"{base}_debug{i}_source.png", toile)
                cv2.imwrite(f"{base}_debug{i}_cretes.png", cretes)
            if i == nb_lobes - 1:                  # le dernier : tout de suite
                en_cours.append(_Fait(tracer_lobe, cretes, lobe_net, i))
            else:
                en_cours.append(_atelier_traces().submit(tracer_lobe, cretes,
                                                         lobe_net, i))
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


COUPURE_BANDE = 0.35      # largeur (en interlignes) de la bande le long de la
                          # coupure d'une forme coupée où un trait n'a pas le
                          # droit de COURIR le long de la coupure
COUPURE_PARALLELE = 35.0  # ...« le long » = à moins de ce nombre de degrés


def _degager_coupure(traits, lobe_net, forme, i, periode):
    """Formes coupées : la coupure doit rester un fin espace VIDE, bordé de
    traits qui s'y arrêtent net. Le découpage au masque laisse parfois un
    bout de crête qui court le long du bord (une crête presque parallèle à la
    coupure, rognée sur sa longueur) : on dirait un trait gravé le long de la
    coupure. On retire ces portions-là — points à moins de COUPURE_BANDE
    interligne du bord ET orientés à moins de COUPURE_PARALLELE degrés de
    lui —, puis les bouts devenus trop courts pour être des crêtes (même
    seuil que tracer_svg : pas de miettes). Les crêtes qui TRAVERSENT la
    coupure ne sont pas touchées : elles s'arrêtent net au bord."""
    if not traits:
        return traits
    xs = np.flatnonzero(lobe_net.any(axis=0))
    ys = np.flatnonzero(lobe_net.any(axis=1))
    verticale = forme == "ovale_lr"             # ovale_lr : coupure verticale
    if verticale:
        bord, axe = (xs[-1] if i == 0 else xs[0]), 0
    else:                                       # tête-bêche : horizontale
        bord, axe = (ys[-1] if i == 0 else ys[0]), 1
    bande = max(2.0, COUPURE_BANDE * float(periode))
    seuil = max(tracer_svg.LONGUEUR_PLANCHER,
                tracer_svg.LONGUEUR_MINI_PERIODES * float(periode))
    sinus = np.sin(np.radians(COUPURE_PARALLELE))
    sortie = []
    for t in traits:
        t = np.asarray(t, np.float64)
        if len(t) < 2:
            continue
        pres = np.abs(t[:, axe] - bord) < bande
        if not pres.any():
            sortie.append(t)
            continue
        tangente = np.gradient(t, axis=0)
        norme = np.linalg.norm(tangente, axis=1) + 1e-12
        travers = np.abs(tangente[:, axe]) / norme  # composante à travers
        retirer = pres & (travers < sinus)
        if not retirer.any():
            sortie.append(t)
            continue
        bords = np.flatnonzero(np.diff(np.concatenate(
            [[0], (~retirer).astype(np.int8), [0]])))
        for a, b in zip(bords[::2], bords[1::2]):
            morceau = t[a:b]
            if len(morceau) >= 2 and tracer_svg.longueur(morceau) >= seuil:
                sortie.append(morceau)
    return sortie


def _poser(mosaique, i, geometrie, crop, ajust):
    """L'empreinte i posée dans la forme : toile de la taille du canevas,
    fond blanc, cadrage, rotation de forme et retouche (`ajust`) compris."""
    h, w, contour, lobes, transforms, cadres, centres = geometrie
    orbite, sur_soi = transforms[i]
    lobe = lobes[i]
    mos = tourner_sur_elle_meme(_recadrer_mosaique(mosaique, crop), sur_soi)
    if cadres[i] is not None:
        # formes coupées : à l'échelle de TOUT l'ovale, centrée sur lui ; sa
        # moitié la découpera
        toile = poser_dans_lobe(mos, cadres[i])
    elif orbite == 0:
        toile = poser_dans_lobe(mos, lobe)             # posée directement
    else:
        # posée à l'endroit dans le 1er lobe, puis toute la toile tourne
        # autour du centre pour l'amener (orientée) dans ce lobe-ci
        toile = poser_dans_lobe(mos, lobes[0])
        toile = tourner_autour_du_centre(toile, orbite)
    # retouche fine demandée par l'utilisateur (glisser / tourner)
    return appliquer_ajust(toile, lobe, ajust, centre=centres[i])


def _composer_photo(mosaiques, geometrie, crops, chemin_svg, apercu_png,
                    ajusts=None):
    """Style « photo » : la vraie empreinte (niveaux de gris) découpée dans
    chaque lobe, sans tracé. SVG = image PNG embarquée (base64)."""
    import base64
    h, w, contour, lobes = geometrie[:4]
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    compo = np.full((h, w), 255, np.uint8)
    nb_lobes = min(len(mosaiques), len(lobes), len(geometrie[4]))
    for i, (mosaique, lobe) in enumerate(zip(mosaiques[:nb_lobes], lobes)):
        crop = crops[i] if crops else None
        toile = _poser(mosaique, i, geometrie, crop,
                       ajusts[i] if ajusts else None)
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


# --------------------------------------------------------------------------
# Empreintes séparées, et où se trouve chaque empreinte dans un rendu
# --------------------------------------------------------------------------

def rendre_seule(mosaique, style, chemin_svg, apercu_png=None, crop=None,
                 completer=True):
    """UNE empreinte seule dans un style : l'ovale d'une empreinte seule, son
    cadrage et sa complétion, sans `ajust` (il ne règle que la place dans une
    forme composée). C'est le rendu de la forme « separees » et de l'export."""
    return composer([mosaique], "simple", style, chemin_svg,
                    apercu_png=apercu_png, crops=[crop],
                    completions=[completer])


def _normaliser_angle(degres):
    """Angle ramené dans ]-180, 180]."""
    a = (float(degres) + 180.0) % 360.0 - 180.0
    return 180.0 if a == -180.0 else a


def _fractions(valeurs, diviseurs):
    return [round(float(v) / float(d), 5) for v, d in zip(valeurs, diviseurs)]


def disposition(forme, n, ajusts=None):
    """Où est chaque empreinte dans l'image du rendu (PNG d'aperçu ou SVG),
    en FRACTIONS de sa largeur (x) et de sa hauteur (y) :

        {"largeur_forme": part de la largeur de l'image occupée par la forme
                          gravée (pour « separees » : celle d'UNE médaille),
         "lobes": [{"index", "cx", "cy", "rx", "ry", "angle", "zone"}]}

    (cx, cy) : centre ACTUEL de l'empreinte i, `ajust` compris ; rx, ry :
    demi-axes de son cadre de placement (l'ovale entier pour les formes
    coupées) ; angle : rotation affichée de l'empreinte en degrés, sens
    HORAIRE comme `ajust.angle` (rotation de la forme comprise : ±20° du
    cœur, rotation des feuilles du trèfle, 180° de l'empreinte 2 en
    tête-bêche), ramenée dans ]-180, 180] ; zone : [x0, y0, x1, y1] la partie
    VISIBLE de l'empreinte (son lobe)."""
    forme = nom_forme(forme)
    if forme == "separees":
        return _disposition_planche(n)
    h, w, contour, lobes, transforms, cadres, centres = _geometrie(forme, n)
    fx0, _fy0, fx1, _fy1 = _bbox(contour)
    lobes_info = []
    for i in range(min(n, len(lobes), len(transforms))):
        orbite, sur_soi = transforms[i]
        lobe = lobes[i]
        if cadres[i] is not None:
            cadre = cadres[i]
        else:
            cadre = lobe if orbite == 0 else lobes[0]
        cx, cy = centre_lobe(cadre)
        if cadres[i] is None and orbite != 0:          # trèfle : la toile tourne
            M = cv2.getRotationMatrix2D((w / 2, h / 2), orbite, 1.0)
            cx, cy = M @ np.array([cx, cy, 1.0])
            cadre = lobe                               # (demi-axes : son lobe)
        bx0, by0, bx1, by1 = _bbox(cadre)
        rx, ry = (bx1 - bx0) / 2.0, (by1 - by0) / 2.0
        ajust = (ajusts[i] if ajusts and i < len(ajusts) else None) or {}
        dx = float(ajust.get("dx", 0.0) or 0.0)
        dy = float(ajust.get("dy", 0.0) or 0.0)
        angle = float(ajust.get("angle", 0.0) or 0.0)
        pivot = centre_lobe(lobe) if centres[i] is None else centres[i]
        M = cv2.getRotationMatrix2D(pivot, -angle, 1.0)    # comme appliquer_ajust
        M[0, 2] += dx * RAYON_LOBE
        M[1, 2] += dy * RAYON_LOBE
        cx, cy = M @ np.array([cx, cy, 1.0])
        zx0, zy0, zx1, zy1 = _bbox(lobe)
        lobes_info.append({
            "index": i,
            "cx": round(float(cx) / w, 5), "cy": round(float(cy) / h, 5),
            "rx": round(rx / w, 5), "ry": round(ry / h, 5),
            # OpenCV tourne dans le sens anti-horaire : horaire = -(sur-soi + orbite)
            "angle": round(_normaliser_angle(angle - sur_soi - orbite), 3),
            "zone": _fractions([zx0, zy0, zx1 + 1, zy1 + 1], [w, h, w, h]),
        })
    return {"largeur_forme": round((fx1 - fx0 + 1) / w, 5), "lobes": lobes_info}


def _disposition_planche(n):
    """disposition() de la planche des empreintes séparées : n images
    d'empreinte seule (même toile chacune) posées côte à côte."""
    seule = disposition("simple", 1)
    lobes_info = []
    for i in range(n):
        l = dict(seule["lobes"][0])
        l["index"] = i
        l["cx"] = round((i + l["cx"]) / n, 5)
        l["rx"] = round(l["rx"] / n, 5)
        z = l["zone"]
        l["zone"] = [round((i + z[0]) / n, 5), z[1], round((i + z[2]) / n, 5), z[3]]
        lobes_info.append(l)
    return {"largeur_forme": round(seule["largeur_forme"] / max(n, 1), 5),
            "lobes": lobes_info}


def planche(chemins_png, chemin_sortie, cote_max=2200):
    """Planche des empreintes séparées : les images d'empreinte seule (rendues
    par rendre_seule, toutes de la même taille) côte à côte sur fond blanc,
    sans texte, réduite si besoin à `cote_max` px de large. Renvoie sa
    disposition (voir disposition)."""
    images = []
    for chemin in chemins_png:
        image = cv2.imread(chemin, cv2.IMREAD_COLOR)
        if image is None:
            raise IOError(f"image illisible : {chemin}")
        images.append(image)
    if not images:
        raise ValueError("aucune empreinte")
    hauteur = max(im.shape[0] for im in images)
    largeur = max(im.shape[1] for im in images)
    cases = []
    for im in images:                    # (même taille en pratique)
        case = np.full((hauteur, largeur, 3), 255, np.uint8)
        y0, x0 = (hauteur - im.shape[0]) // 2, (largeur - im.shape[1]) // 2
        case[y0:y0 + im.shape[0], x0:x0 + im.shape[1]] = im
        cases.append(case)
    image = np.hstack(cases)
    if image.shape[1] > cote_max:
        echelle = cote_max / float(image.shape[1])
        image = cv2.resize(image, (cote_max, max(1, int(round(image.shape[0] * echelle)))),
                           interpolation=cv2.INTER_AREA)
    if not cv2.imwrite(chemin_sortie, image):
        raise IOError(f"planche non écrite : {chemin_sortie}")
    return _disposition_planche(len(images))


def principal():
    if len(sys.argv) < 5:
        sys.exit("Utilisation : python3 formes.py <forme> <style> sortie.svg "
                 "mosaique1.png [mosaique2.png ...]\n"
                 "  forme : simple | coeur | trefle (alias : trefle3, trefle4)"
                 " | ovale_lr | tete_beche (2 empreintes)\n"
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
