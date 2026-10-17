#!/usr/bin/env python3
"""
completer_empreinte.py — comble les trous d'une empreinte en extrapolant
les crêtes manquantes.

Principe (inspiré des générateurs d'empreintes synthétiques) :
  1. repère les zones où il y a de vraies données (contraste local) et le
     contour global du doigt ;
  2. calcule le champ d'orientation des crêtes (tenseur de structure) et le
     diffuse dans les trous : on sait dans quel sens les crêtes DEVRAIENT
     passer ;
  3. mesure l'espacement moyen des crêtes (pic du spectre de Fourier) ;
  4. fait pousser les crêtes dans les trous : filtrage de Gabor itératif
     orienté par le champ — les crêtes existantes se prolongent naturellement
     à travers les zones vides, en restant accrochées aux vraies données.

Utilisation autonome :
    python3 completer_empreinte.py image_amelioree.png [sortie_cretes.png]

VITESSE (le résultat est identique AU BIT PRÈS à l'ancien calcul — vérifié
sur toutes les empreintes réelles ; les deux astuces qui reproduisent un
calcul d'OpenCV se vérifient elles-mêmes au premier usage et s'effacent à la
moindre différence) :
  - la pousse ne travaille que sur la fenêtre du domaine à remplir (un lobe
    n'occupe qu'une partie de la toile d'un cœur ou d'un trèfle) et sur ses
    seuls pixels (le reste vaut 0 de toute façon) ;
  - les 16 filtres de Gabor refont le calcul de cv2.filter2D (transformée de
    Fourier par tuiles, en double), mais la transformée de chaque tuile
    d'image sert aux 16 noyaux au lieu d'être refaite 16 fois, seules les
    orientations utiles à une tuile sont calculées, et les tuiles se
    répartissent sur tous les cœurs (voir _Correlation) ;
  - les flous gaussiens des images moyennes sont faits en bandes parallèles
    (voir flou_gaussien) ; la diffusion du poids, jamais lue, n'est plus
    calculée ; le profil radial du spectre se lit en un passage.
"""

import os
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

K_ORIENTATIONS = 16       # finesse angulaire de la banque de filtres
ITERATIONS = 22           # passes de pousse des crêtes
SEUIL_DONNEES = 0.28      # amplitude locale mini pour "vraies données"
RATIO_OVALE = 1.4         # allongement maxi de l'ovale (h/l) — plus petit = plus rond

_ATELIER = None           # fils de calcul partagés (créés au premier besoin)
_VERROU_ATELIER = threading.Lock()


def _atelier():
    """Fils de calcul pour les filtres de Gabor : cv2.filter2D ne se
    parallélise pas tout seul, mais libère le verrou de Python — les 16
    orientations d'une passe se calculent donc côte à côte. Marche à
    l'identique sur Mac Intel et Apple Silicon (simple nombre de cœurs)."""
    global _ATELIER
    with _VERROU_ATELIER:
        if _ATELIER is None:
            _ATELIER = ThreadPoolExecutor(
                max_workers=max(1, min(K_ORIENTATIONS, os.cpu_count() or 4)),
                thread_name_prefix="gabor")
        return _ATELIER


# Flou en bandes vérifié égal au bit près à cv2.GaussianBlur, par
# (forme, type, sigma) : True = vérifié, False = différent (on s'abstient).
_FLOU_VERIFIE = {}


def flou_gaussien(image, sigma):
    """Exactement cv2.GaussianBlur(image, (0, 0), sigma) — même résultat au
    bit près — mais plus vite sur les images moyennes.

    OpenCV ne répartit un flou sur plusieurs cœurs qu'au-delà d'environ un
    million de pixels : la toile d'une empreinte seule (~0,8 Mpx) était floutée
    sur un seul cœur, des dizaines de fois par rendu. Ici on la découpe en
    bandes horizontales, chacune avec une marge de 4 sigmas de vraies lignes
    voisines (au-delà, le noyau d'OpenCV ne lit plus rien), floutées côte à
    côte : chaque pixel gardé voit exactement les mêmes voisins, dans les
    mêmes calculs. Garde-fou : la première fois qu'une forme d'image et un
    sigma se présentent, le résultat est comparé au bit près (zéros signés
    compris) au flou d'OpenCV ; à la moindre différence, on s'en tient à
    OpenCV pour ce cas."""
    hauteur = image.shape[0]
    fils = max(1, min(8, os.cpu_count() or 1))
    marge = int(np.ceil(4.0 * float(sigma))) + 2
    if (fils < 2 or image.size > (1 << 20) or not image.flags.c_contiguous
            or hauteur < 4 * marge
            or threading.current_thread().name.startswith("gabor")):
        return cv2.GaussianBlur(image, (0, 0), sigma)
    cle = (image.shape, image.dtype.str, float(sigma))
    etat = _FLOU_VERIFIE.get(cle)
    if etat is False:
        return cv2.GaussianBlur(image, (0, 0), sigma)
    bandes = min(fils, max(1, hauteur // (2 * marge)))
    bornes = np.linspace(0, hauteur, bandes + 1).astype(int)
    sortie = np.empty_like(image)

    def une_bande(i):
        a, b = int(bornes[i]), int(bornes[i + 1])
        a0, b0 = max(0, a - marge), min(hauteur, b + marge)
        sortie[a:b] = cv2.GaussianBlur(image[a0:b0], (0, 0), sigma)[a - a0:b - a0]

    for _fait in _atelier().map(une_bande, range(bandes)):
        pass
    if etat is None:                              # vérification, une fois
        attendu = cv2.GaussianBlur(image, (0, 0), sigma)
        _FLOU_VERIFIE[cle] = bool(np.array_equal(
            sortie.reshape(-1).view(np.uint8), attendu.reshape(-1).view(np.uint8)))
        return attendu
    return sortie


def _domaine(valide):
    """Zone à remplir : les trous INTERNES sont bouchés, mais le contour
    du doigt n'est pas gonflé (on n'invente rien au-delà du doigt).
    La fermeture scelle les passages étroits entre fragments, puis le
    remplissage topologique bouche tout ce qui n'est pas relié au bord."""
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (21, 21))
    domaine = cv2.morphologyEx(valide, cv2.MORPH_CLOSE, noyau)
    # bouche les trous internes (non reliés au bord de l'image)
    inverse = cv2.bitwise_not(domaine)
    remplissage = np.zeros((domaine.shape[0] + 2, domaine.shape[1] + 2), np.uint8)
    cv2.floodFill(inverse, remplissage, (0, 0), 0)
    domaine = cv2.bitwise_or(domaine, inverse)
    nb, etiquettes, stats, _ = cv2.connectedComponentsWithStats(domaine)
    if nb > 1:
        plus_grande = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        domaine = np.where(etiquettes == plus_grande, 255, 0).astype(np.uint8)
    return domaine


def _ovale(masque, agrandissement=1.06):
    """Ajuste une ellipse (l'ovale « façon œuf ») sur la zone de données et
    renvoie son masque plein — c'est la forme finale à remplir puis découper.
    On enlève d'abord les fines excroissances (plis de la base du doigt,
    bavures) pour que l'ovale colle à la pulpe et reste régulier."""
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (35, 35))
    propre = cv2.morphologyEx(masque, cv2.MORPH_OPEN, noyau)
    nb, etiquettes, stats, _ = cv2.connectedComponentsWithStats(propre)
    if nb > 1:
        grande = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        propre = np.where(etiquettes == grande, 255, 0).astype(np.uint8)
    if int((propre > 0).sum()) < 0.25 * int((masque > 0).sum()):
        propre = masque                            # ouverture trop agressive
    contours, _ = cv2.findContours(propre, cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea)
    if len(contour) < 5:
        return None
    (cx, cy), (d1, d2), _ = cv2.fitEllipse(contour)
    grand, petit = max(d1, d2), min(d1, d2)

    # direction du grand axe (robuste à l'inclinaison du doigt)
    pts = contour.reshape(-1, 2).astype(np.float64)
    _, vecteurs = np.linalg.eigh(np.cov((pts - pts.mean(0)).T))
    axe = vecteurs[:, -1]
    if axe[1] < 0:
        axe = -axe                                 # oriente vers le bas (+y)

    # bride l'allongement en « œuf » : garde le sommet, rogne la base
    # (le bas du doigt — plis, base — est de moins bonne qualité)
    grand_rogne = min(grand, petit * RATIO_OVALE)
    sommet = np.array([cx, cy]) - axe * (grand / 2)
    centre = sommet + axe * (grand_rogne / 2)
    angle = float(np.degrees(np.arctan2(axe[1], axe[0])))

    ovale = np.zeros(masque.shape, np.uint8)
    cv2.ellipse(ovale, (int(round(centre[0])), int(round(centre[1]))),
                (max(int(grand_rogne * agrandissement / 2), 1),
                 max(int(petit * agrandissement / 2), 1)),
                angle, 0, 360, 255, -1)
    return ovale


def _tenseur(bande):
    """Tenseur de structure : orientation double-angle + cohérence."""
    gx = cv2.Sobel(bande, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(bande, cv2.CV_32F, 0, 1, ksize=3)
    jxx = flou_gaussien(gx * gx, 7)
    jyy = flou_gaussien(gy * gy, 7)
    jxy = flou_gaussien(gx * gy, 7)

    c2, s2 = jxx - jyy, 2.0 * jxy                 # double angle du gradient
    magnitude = np.sqrt(c2 * c2 + s2 * s2) + 1e-9
    coherence = magnitude / (jxx + jyy + 1e-9)
    return -c2 / magnitude, -s2 / magnitude, coherence   # crêtes = gradient + 90°


def _orientation(c2, s2, coherence, valide):
    """Direction locale des crêtes, diffusée dans les zones sans données.
    IMPORTANT : là où les vraies données sont nettes, on garde l'orientation
    MESURÉE. Sinon la diffusion « repasse » le cœur de l'empreinte (un point
    singulier où l'orientation tourne de 180°) et l'étire en une longue
    langue au lieu d'une boucle."""
    poids = (coherence * (valide > 0)).astype(np.float32)
    C, S = c2 * poids, s2 * poids
    # (la somme des poids diffusée n'entre pas dans le résultat : seule la
    # DIRECTION de (C, S) compte, on ne la calcule donc plus)
    for _ in range(40):                           # diffusion dans les trous
        C = flou_gaussien(C, 5)
        S = flou_gaussien(S, 5)

    norme = np.sqrt(C * C + S * S) + 1e-12        # champ diffusé -> unitaire
    Cd, Sd = C / norme, S / norme
    # confiance dans la mesure locale (0 = on prend la diffusion, 1 = la mesure)
    fiable = (np.clip((coherence - 0.35) / 0.25, 0, 1)
              * (valide > 0)).astype(np.float32)
    Cf = Cd * (1.0 - fiable) + c2 * fiable
    Sf = Sd * (1.0 - fiable) + s2 * fiable
    return 0.5 * np.arctan2(Sf, Cf + 1e-12)


def _energie_anneaux(spectre, rayon, ondes, compte_mini=1):
    """Profil radial du spectre : energie[i] = moyenne de `spectre` sur
    l'anneau 1/(onde+0.5) < rayon <= 1/(onde-0.5) de ondes[i], laissée à 0
    s'il compte moins de `compte_mini` cases.
    C'est exactement la boucle « anneau par anneau » d'origine (mêmes bornes,
    calculées par les mêmes opérations ; mêmes cases, sommées dans le même
    ordre), mais en un seul passage sur le spectre au lieu d'un par anneau."""
    energie = np.zeros_like(ondes)
    hauts = np.array([1.0 / (onde - 0.5) for onde in ondes])
    bas = np.array([1.0 / (onde + 0.5) for onde in ondes])
    if len(ondes) < 2 or not np.array_equal(bas[:-1], hauts[1:]) \
            or np.any(np.diff(hauts) >= 0):
        for i, onde in enumerate(ondes):       # anneaux non jointifs : boucle
            anneau = (rayon > 1.0 / (onde + 0.5)) & (rayon <= 1.0 / (onde - 0.5))
            if int(anneau.sum()) >= max(1, compte_mini):
                energie[i] = float(spectre[anneau].mean())
        return energie
    plat = np.asarray(rayon).reshape(-1)
    cases = np.flatnonzero((plat > bas[-1]) & (plat <= hauts[0]))
    croissants = hauts[::-1].astype(np.float64)
    rang = len(ondes) - 1 - np.searchsorted(croissants, plat[cases], side="left")
    ordre = np.argsort(rang, kind="stable")       # ordre ligne par ligne gardé
    valeurs = np.asarray(spectre).reshape(-1)[cases][ordre]
    comptes = np.bincount(rang, minlength=len(ondes))
    debuts = np.concatenate([[0], np.cumsum(comptes)])
    for i in range(len(ondes)):
        if comptes[i] >= max(1, compte_mini):
            energie[i] = float(valeurs[debuts[i]:debuts[i + 1]].mean())
    return energie


def _longueur_onde(signe, valide):
    """Espacement moyen des crêtes : pic du spectre de Fourier.
    On se limite à la zone qui contient vraiment des données et on lit le pic
    sur le profil radial moyen (et non sur un seul point du spectre) : un
    unique pixel de bruit ne peut plus fausser l'estimation, ce qui donnait
    des crêtes trop espacées et un cœur déformé."""
    donnees = valide > 0
    if int(np.count_nonzero(donnees)) > 100:       # recadre sur les données
        lignes = np.flatnonzero(donnees.any(axis=1))
        colonnes = np.flatnonzero(donnees.any(axis=0))
        f = signe[lignes[0]:lignes[-1] + 1, colonnes[0]:colonnes[-1] + 1]
        m = donnees[lignes[0]:lignes[-1] + 1, colonnes[0]:colonnes[-1] + 1]
        f = f * m
    else:
        f = signe * (valide > 0)
    if min(f.shape) < 32:
        return 18.0
    f = f * np.outer(np.hanning(f.shape[0]),
                     np.hanning(f.shape[1])).astype(np.float32)
    spectre = np.abs(np.fft.rfft2(f)) ** 2
    fy = np.fft.fftfreq(f.shape[0])[:, None]
    fx = np.fft.rfftfreq(f.shape[1])[None, :]
    rayon = np.sqrt(fx * fx + fy * fy)

    # profil radial : énergie moyenne par longueur d'onde (1 px de résolution)
    ondes = np.arange(6, 41, dtype=np.float32)
    energie = _energie_anneaux(spectre, rayon, ondes)
    if not energie.any():
        return 18.0
    energie = cv2.GaussianBlur(energie.reshape(-1, 1), (1, 5), 0).ravel()
    return float(np.clip(ondes[int(np.argmax(energie))], 8, 30))


def _tailles_dft(taille, longueur=None):
    """(taille de la DFT, côté de tuile) de cv2.filter2D sur un axe de
    `longueur` pixels, pour un noyau taille x taille.
    Au-delà de quelques pixels de noyau, filter2D convolue par transformée de
    Fourier, TUILE PAR TUILE (cv::crossCorr : blockScale 4,5, bloc mini 256,
    calcul en double). Mêmes formules qu'OpenCV."""
    bloc = max(int(round(taille * 4.5)), 256 - taille + 1)
    if longueur is not None:
        bloc = min(bloc, longueur)
    dft = int(cv2.getOptimalDFTSize(bloc + taille - 1))
    bloc = dft - taille + 1
    return dft, (bloc if longueur is None else min(bloc, longueur))


def _tuile_dft(taille):
    """Côté des tuiles de cv2.filter2D pour un noyau taille x taille.
    Une fenêtre qui démarre sur cette grille découpe les mêmes tuiles que la
    toile entière : chaque pixel est calculé par exactement les mêmes
    opérations, d'où un résultat identique au bit près."""
    return _tailles_dft(taille)[1]


# La corrélation « maison » (voir _Correlation) a-t-elle été vérifiée égale,
# au bit près, à cv2.filter2D ? Une entrée par taille de noyau et de
# transformée : True = vérifiée, False = différence constatée (on s'en tient
# alors à filter2D). "etat" = False coupe tout (une différence suffit).
_CORRELATION_SURE = {"etat": None}


class _Correlation:
    """Les 16 réponses de Gabor d'une passe, aux seuls pixels du domaine.

    cv2.filter2D refait, pour CHACUN des 16 noyaux, la transformée de Fourier
    de chaque tuile d'image. Ici on refait exactement son calcul (mêmes
    tuiles, mêmes tailles de transformée, mêmes bords, en double puis arrondi
    en float32), mais la transformée de chaque tuile est faite UNE fois et
    resservie aux 16 noyaux, et seules les tuiles qui touchent le domaine
    sont calculées — les tuiles se partagent entre les cœurs.
    Garde-fou : à la première passe, la réponse d'un noyau est comparée à
    celle de cv2.filter2D ; à la moindre différence (autre version d'OpenCV,
    autre machine…), on revient définitivement à cv2.filter2D."""

    def __init__(self, forme, banque, ici, bin0, bin1):
        self.hauteur, self.largeur = forme
        self.banque = banque
        self.taille = banque[0].shape[0]
        self.ici, self.bin0, self.bin1 = ici, bin0, bin1
        dh, bh = _tailles_dft(self.taille, self.hauteur)
        dw, bw = _tailles_dft(self.taille, self.largeur)
        self.dft = (dh, dw)
        self.spectres = None
        # pixels du domaine regroupés par tuile (grille de crossCorr)
        ys, xs = np.divmod(ici, self.largeur)
        par_ligne = -(-self.largeur // bw)
        tuile = (ys // bh) * par_ligne + (xs // bw)
        ordre = np.argsort(tuile, kind="stable")
        self.tuiles = []
        for groupe in np.split(ordre, np.flatnonzero(np.diff(tuile[ordre])) + 1):
            if not len(groupe):
                continue
            ty, tx = divmod(int(tuile[groupe[0]]), par_ligne)
            y, x = ty * bh, tx * bw
            b0, b1 = bin0[groupe], bin1[groupe]
            # seules les orientations dont un pixel de la tuile a besoin
            # sont calculées (le champ varie peu à l'échelle d'une tuile)
            utiles = np.flatnonzero(np.bincount(np.concatenate([b0, b1]),
                                                minlength=len(banque)))
            rang = np.zeros(len(banque), np.int64)
            rang[utiles] = np.arange(len(utiles))
            self.tuiles.append((y, x, min(bh, self.hauteur - y),
                                min(bw, self.largeur - x), groupe,
                                ys[groupe] - y, xs[groupe] - x,
                                rang[b0], rang[b1], utiles))
        # pour cv2.filter2D : par orientation, les pixels qui en ont besoin
        self.besoins = []
        for k in range(len(banque)):
            i0 = np.flatnonzero(bin0 == k)
            i1 = np.flatnonzero(bin1 == k)
            self.besoins.append((i0, ici[i0], i1, ici[i1]))

    def _par_filter2d(self, image, rep0, rep1):
        def filtrer(k):
            r = cv2.filter2D(image, -1, self.banque[k]).reshape(-1)
            i0, f0, i1, f1 = self.besoins[k]
            rep0[i0] = r[f0]                      # indices disjoints d'une
            rep1[i1] = r[f1]                      # orientation à l'autre
        for _fait in _atelier().map(filtrer, range(len(self.banque))):
            pass

    def _une_tuile(self, image, tuile, rep0, rep1, temoin):
        y, x, bh, bw, groupe, ly, lx, b0, b1, utiles = tuile
        a = self.taille // 2
        dh, dw = bh + self.taille - 1, bw + self.taille - 1
        y0, x0 = y - a, x - a
        y1, x1 = max(0, y0), max(0, x0)
        y2, x2 = min(self.hauteur, y0 + dh), min(self.largeur, x0 + dw)
        tampon = np.zeros(self.dft, np.float64)
        if x2 - x1 < dw or y2 - y1 < dh:          # tuile au bord de l'image
            tampon[:dh, :dw] = cv2.copyMakeBorder(
                image[y1:y2, x1:x2].astype(np.float64),
                y1 - y0, dh - (y2 - y0), x1 - x0, dw - (x2 - x0),
                cv2.BORDER_REFLECT_101)
        else:
            tampon[:dh, :dw] = image[y1:y2, x1:x2]
        spectre = cv2.dft(tampon, flags=0, nonzeroRows=dh)
        if temoin is not None and utiles[0] != 0:   # le témoin, c'est le
            utiles = np.concatenate([[0], utiles])  # noyau 0 : on l'ajoute
            b0, b1 = b0 + 1, b1 + 1
        pile = np.empty((len(utiles), bh, bw), np.float32)
        for j, k in enumerate(utiles):
            produit = cv2.mulSpectrums(spectre, self.spectres[k], 0, conjB=True)
            pile[j] = cv2.dft(produit, flags=cv2.DFT_INVERSE | cv2.DFT_SCALE,
                              nonzeroRows=bh)[:bh, :bw]
        rep0[groupe] = pile[b0, ly, lx]
        rep1[groupe] = pile[b1, ly, lx]
        if temoin is not None:
            temoin[groupe] = pile[0, ly, lx]

    def _par_tuiles(self, image, rep0, rep1, temoin=None):
        if self.spectres is None:                 # DFT des noyaux, une fois
            t = self.taille
            self.spectres = []
            for noyau in self.banque:
                m = np.zeros(self.dft, np.float64)
                m[:t, :t] = noyau
                self.spectres.append(cv2.dft(m, flags=0, nonzeroRows=t))
        for _fait in _atelier().map(
                lambda tuile: self._une_tuile(image, tuile, rep0, rep1, temoin),
                self.tuiles):
            pass

    def calculer(self, image, rep0, rep1):
        """Remplit rep0 / rep1 (réponses des 2 orientations de chaque pixel)."""
        cle = (self.taille, self.dft)
        if _CORRELATION_SURE["etat"] is False or _CORRELATION_SURE.get(cle) is False:
            self._par_filter2d(image, rep0, rep1)
            return
        if _CORRELATION_SURE.get(cle) is None:    # vérification, une fois
            temoin = np.empty(len(self.ici), np.float32)
            self._par_tuiles(image, rep0, rep1, temoin)
            attendu = cv2.filter2D(image, -1, self.banque[0]).reshape(-1)[self.ici]
            if np.array_equal(temoin.view(np.uint32), attendu.view(np.uint32)):
                _CORRELATION_SURE[cle] = True
            else:
                _CORRELATION_SURE[cle] = False
                _CORRELATION_SURE["etat"] = False
                self._par_filter2d(image, rep0, rep1)
            return
        self._par_tuiles(image, rep0, rep1)


def _fenetre(dans, taille):
    """Fenêtre (y0, y1, x0, x1) où faire pousser les crêtes : le domaine, plus
    une marge d'un rayon de noyau (au-delà l'image est nulle et le reste),
    arrondie à la grille de tuiles de filter2D (voir _tuile_dft)."""
    h, w = dans.shape
    lignes = np.flatnonzero(dans.any(axis=1))
    colonnes = np.flatnonzero(dans.any(axis=0))
    marge = taille // 2 + 2
    bloc = _tuile_dft(taille)

    def borner(debut, fin, total):
        a = max(0, (int(debut) - marge) // bloc * bloc)
        b = min(total, -(-(int(fin) + 1 + marge) // bloc) * bloc)
        if b - a < bloc:                 # dernière tuile tronquée : on prend
            a = max(0, a - bloc)         # la voisine, les tuiles restent égales
        return a, b

    y0, y1 = borner(lignes[0], lignes[-1], h)
    x0, x1 = borner(colonnes[0], colonnes[-1], w)
    return y0, y1, x0, x1


def completer(gris, iterations=ITERATIONS, ovale=False, domaine_force=None):
    """Image améliorée (uint8, crêtes sombres) -> crêtes complétées
    (uint8, crêtes noires sur fond blanc), trous comblés.
    Si ovale=True : la zone remplie est un ovale ajusté sur le doigt, et
    les crêtes sont poussées jusqu'à son bord puis découpées net.
    Si domaine_force (masque uint8) est donné : les crêtes remplissent
    EXACTEMENT cette forme (un lobe de cœur / trèfle) — prioritaire."""
    g = gris.astype(np.float32)

    # normalisation locale passe-bande : on ne garde que l'oscillation
    # crête/vallée. Un pâté uniforme (trop encré) ou une zone pâle n'ont
    # pas d'oscillation -> classés "sans données" et resynthétisés.
    moyenne = flou_gaussien(g, 8)
    bande = moyenne - g                              # crêtes positives
    contraste = np.sqrt(flou_gaussien(bande * bande, 12) + 1e-6)
    signe = np.clip(bande / (1.5 * contraste + 1e-6), -1, 1).astype(np.float32)

    # vraies données = contraste suffisant ET crêtes localement parallèles
    # (la cohérence écarte le halo pâle et le bruit autour du doigt)
    c2, s2, coherence = _tenseur(bande)
    valide = ((contraste > 16) & (coherence > 0.30)).astype(np.uint8) * 255
    valide = cv2.morphologyEx(valide, cv2.MORPH_OPEN,
                              cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
    valide = cv2.morphologyEx(valide, cv2.MORPH_CLOSE,
                              cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    if int((valide > 0).sum()) < 2000:
        raise ValueError("pas assez de données pour compléter")

    if domaine_force is not None:                 # forme imposée (lobe) : la
        domaine = (domaine_force > 0).astype(np.uint8) * 255   # silhouette
    else:                                         # du doigt ne servirait à rien
        # la silhouette du doigt suit les données FORTES ; les données
        # faibles (halo pâle des poses légères) servent d'ancrage mais pas de
        # contour
        seuil_fort = 0.55 * float(np.percentile(contraste[valide > 0], 60))
        fort = (((contraste > seuil_fort) & (valide > 0)) * 255).astype(np.uint8)
        if int((fort > 0).sum()) < 0.2 * (valide > 0).sum():
            fort = valide
        domaine = _domaine(fort)
        if ovale:                                 # forme finale = ovale plein
            ov = _ovale(domaine)
            if ov is not None:
                domaine = ov

    theta = _orientation(c2, s2, coherence, valide)
    onde = _longueur_onde(signe, valide)

    # banque de filtres de Gabor orientés
    taille = int(onde * 2) | 1
    banque = []
    for k in range(K_ORIENTATIONS):
        angle = np.pi * k / K_ORIENTATIONS
        noyau = cv2.getGaborKernel((taille, taille), sigma=onde * 0.45,
                                   theta=angle + np.pi / 2, lambd=onde,
                                   gamma=0.5, psi=0)
        noyau -= noyau.mean()
        noyau /= np.linalg.norm(noyau) + 1e-9
        banque.append(np.float32(noyau))

    dans = domaine > 0
    donnees = valide > 0
    # amorce : vraies crêtes + léger bruit dans les trous
    alea = np.random.default_rng(0)
    image = signe * donnees + 0.15 * alea.standard_normal(signe.shape).astype(np.float32) * (dans & ~donnees)
    image = (image * dans).astype(np.float32)
    if not dans.any():                            # rien à remplir
        return cv2.medianBlur(np.full(dans.shape, 255, np.uint8), 3)

    # La pousse ne concerne que le domaine : hors de lui l'image vaut 0 à
    # chaque passe et la réponse des filtres n'est jamais lue. On travaille
    # donc dans la fenêtre du domaine (voir _fenetre), et sur ses seuls pixels.
    y0, y1, x0, x1 = _fenetre(dans, taille)
    image_f = np.ascontiguousarray(image[y0:y1, x0:x1])
    plan_f = image_f.reshape(-1)                  # vue à plat de la fenêtre
    ici = np.flatnonzero(dans[y0:y1, x0:x1])      # pixels du domaine (ordre
    signe_d = signe[y0:y1, x0:x1].ravel()[ici]    # ligne par ligne, comme
    donnees_d = donnees[y0:y1, x0:x1].ravel()[ici]   # reponse[dans])

    # poids des 2 orientations les plus proches, par pixel
    position = (theta[y0:y1, x0:x1].ravel()[ici] % np.pi) / (np.pi / K_ORIENTATIONS)
    bin0 = np.floor(position).astype(np.int64) % K_ORIENTATIONS
    bin1 = (bin0 + 1) % K_ORIENTATIONS
    poids1 = (position - np.floor(position)).astype(np.float32)
    poids0 = 1.0 - poids1
    correlation = _Correlation(image_f.shape, banque, ici, bin0, bin1)
    rep0 = np.empty(len(ici), np.float32)         # réponse de l'orientation 1
    rep1 = np.empty(len(ici), np.float32)         # ...et de l'orientation 2

    for _ in range(iterations):
        correlation.calculer(image_f, rep0, rep1)
        reponse = rep0 * poids0 + rep1 * poids1
        reponse /= float(np.std(reponse)) + 1e-9
        reponse = np.tanh(1.5 * reponse)
        # Les vraies données restent ancrées, les trous prennent la pousse.
        # Ancrage fort (0,7) : sinon la synthèse finit par réécrire les vraies
        # crêtes et déforme les zones délicates (cœur, deltas).
        plan_f[ici] = np.where(donnees_d, 0.7 * signe_d + 0.3 * reponse,
                               reponse)

    image = np.zeros(dans.shape, np.float32)
    image[y0:y1, x0:x1] = image_f
    cretes = np.where((image > 0) & dans, 0, 255).astype(np.uint8)
    return cv2.medianBlur(cretes, 3)


def principal():
    ovale = "--ovale" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit("Utilisation : python3 completer_empreinte.py image.png "
                 "[sortie.png] [--ovale]")
    entree = args[0]
    sortie = args[1] if len(args) > 1 \
        else os.path.splitext(entree)[0] + "_completee.png"
    gris = cv2.imread(entree, cv2.IMREAD_GRAYSCALE)
    if gris is None:
        sys.exit(f"Illisible : {entree}")
    cv2.imwrite(sortie, completer(gris, ovale=ovale))
    print(f"-> {sortie}")


if __name__ == "__main__":
    principal()
