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
"""

import os
import sys

import cv2
import numpy as np

K_ORIENTATIONS = 16       # finesse angulaire de la banque de filtres
ITERATIONS = 22           # passes de pousse des crêtes
SEUIL_DONNEES = 0.28      # amplitude locale mini pour "vraies données"
RATIO_OVALE = 1.4         # allongement maxi de l'ovale (h/l) — plus petit = plus rond


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
    jxx = cv2.GaussianBlur(gx * gx, (0, 0), 7)
    jyy = cv2.GaussianBlur(gy * gy, (0, 0), 7)
    jxy = cv2.GaussianBlur(gx * gy, (0, 0), 7)

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
    C, S, W = c2 * poids, s2 * poids, poids.copy()
    for _ in range(40):                           # diffusion dans les trous
        C = cv2.GaussianBlur(C, (0, 0), 5)
        S = cv2.GaussianBlur(S, (0, 0), 5)
        W = cv2.GaussianBlur(W, (0, 0), 5)

    norme = np.sqrt(C * C + S * S) + 1e-12        # champ diffusé -> unitaire
    Cd, Sd = C / norme, S / norme
    # confiance dans la mesure locale (0 = on prend la diffusion, 1 = la mesure)
    fiable = (np.clip((coherence - 0.35) / 0.25, 0, 1)
              * (valide > 0)).astype(np.float32)
    Cf = Cd * (1.0 - fiable) + c2 * fiable
    Sf = Sd * (1.0 - fiable) + s2 * fiable
    return 0.5 * np.arctan2(Sf, Cf + 1e-12)


def _longueur_onde(signe, valide):
    """Espacement moyen des crêtes : pic du spectre de Fourier.
    On se limite à la zone qui contient vraiment des données et on lit le pic
    sur le profil radial moyen (et non sur un seul point du spectre) : un
    unique pixel de bruit ne peut plus fausser l'estimation, ce qui donnait
    des crêtes trop espacées et un cœur déformé."""
    lignes, colonnes = np.where(valide > 0)
    if len(lignes) > 100:                          # recadre sur les données
        f = signe[lignes.min():lignes.max() + 1,
                  colonnes.min():colonnes.max() + 1]
        m = (valide > 0)[lignes.min():lignes.max() + 1,
                         colonnes.min():colonnes.max() + 1]
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
    energie = np.zeros_like(ondes)
    for i, onde in enumerate(ondes):
        anneau = (rayon > 1.0 / (onde + 0.5)) & (rayon <= 1.0 / (onde - 0.5))
        if anneau.any():
            energie[i] = float(spectre[anneau].mean())
    if not energie.any():
        return 18.0
    energie = cv2.GaussianBlur(energie.reshape(-1, 1), (1, 5), 0).ravel()
    return float(np.clip(ondes[int(np.argmax(energie))], 8, 30))


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
    moyenne = cv2.GaussianBlur(g, (0, 0), 8)
    bande = moyenne - g                              # crêtes positives
    contraste = np.sqrt(cv2.GaussianBlur(bande * bande, (0, 0), 12) + 1e-6)
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

    # la silhouette du doigt suit les données FORTES ; les données faibles
    # (halo pâle des poses légères) servent d'ancrage mais pas de contour
    seuil_fort = 0.55 * float(np.percentile(contraste[valide > 0], 60))
    fort = (((contraste > seuil_fort) & (valide > 0)) * 255).astype(np.uint8)
    if int((fort > 0).sum()) < 0.2 * (valide > 0).sum():
        fort = valide
    domaine = _domaine(fort)

    if domaine_force is not None:                 # forme imposée (lobe)
        domaine = (domaine_force > 0).astype(np.uint8) * 255
    elif ovale:                                   # forme finale = ovale plein
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

    # poids des 2 orientations les plus proches, par pixel
    position = (theta % np.pi) / (np.pi / K_ORIENTATIONS)
    bin0 = np.floor(position).astype(np.int64) % K_ORIENTATIONS
    bin1 = (bin0 + 1) % K_ORIENTATIONS
    poids1 = (position - np.floor(position)).astype(np.float32)
    poids0 = 1.0 - poids1

    for _ in range(iterations):
        reponses = np.stack([cv2.filter2D(image, -1, n) for n in banque])
        reponse = (np.take_along_axis(reponses, bin0[None], 0)[0] * poids0
                   + np.take_along_axis(reponses, bin1[None], 0)[0] * poids1)
        reponse /= float(np.std(reponse[dans])) + 1e-9
        reponse = np.tanh(1.5 * reponse)
        # Les vraies données restent ancrées, les trous prennent la pousse.
        # Ancrage fort (0,7) : sinon la synthèse finit par réécrire les vraies
        # crêtes et déforme les zones délicates (cœur, deltas).
        image = (np.where(donnees, 0.7 * signe + 0.3 * reponse, reponse)
                 * dans).astype(np.float32)

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
