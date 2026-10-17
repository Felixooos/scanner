#!/usr/bin/env python3
"""
fusionner_empreinte.py — assemble plusieurs captures partielles du JM-101 en
une seule grande empreinte (mosaïquage, comme les « empreintes roulées » des
systèmes d'état civil).

Deux usages :
  - mode live (via capture_empreinte.py) : SessionFusion accumule les scans
    un par un, chaque pose se raccorde à la mosaïque en cours et l'aperçu
    est mis à jour à l'écran ;
  - mode lot :  python3 fusionner_empreinte.py a.png b.png c.png ...

Principe :
  1. chaque capture est améliorée (contraste, CLAHE, reconnexion des crêtes) ;
  2. on détecte la zone où il y a vraiment des crêtes (masque de doigt) ;
  3. la capture est alignée sur la mosaïque en cours : points SIFT + RANSAC,
     sinon corrélation de phase avec balayage d'angle (-12° à +12°) ;
  4. fondu progressif aux raccords (feathering par carte de distance) ;
  5. rendu final aux filtres de Gabor.

Une nouvelle pose COMPLÈTE la mosaïque, elle ne la repeint pas (§ carte_qualite
et SessionFusion._recomposer) : là où il n'y a rien encore, elle remplit ; là où
il y a déjà des crêtes, c'est la meilleure des deux qui l'emporte, mesurée par
une carte de netteté locale. Un bord de pose flou (contact partiel du doigt) ne
peut donc plus écraser une zone déjà nette.

Fusion par CONSENSUS (anti-taches) : chaque pose est gardée en couche alignée
(bloc warpé + poids + netteté + plausibilité). Là où plusieurs poses se
recouvrent, on mesure leur DÉSACCORD local (résidu entre une pose et l'estimation
des autres, lissé sur ~1 période de crête) ; en cas de désaccord, c'est la pose
la plus PLAUSIBLE qui l'emporte — celle dont le voisinage ressemble le plus à
des crêtes propres (§ carte_plausibilite : corrélation locale avec une sinusoïde
orientée à la période des crêtes). Une tache (blob sombre qui ponte deux crêtes,
point clair rond, traînée) n'apparaît que dans une pose : elle est en désaccord
avec les autres et peu plausible, donc rejetée. Avec 3 poses ou plus s'ajoute un
vote robuste (moindres carrés repondérés) : la pose qui s'écarte des autres perd
sa voix. Là où les poses sont d'accord, rien ne change : les détails vrais
(pores, cicatrices, minuties) restent, même s'ils ressemblent peu à des crêtes.
"""

import datetime
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ameliorer_empreinte

# toutes les images finissent dans le sous-dossier photos/ — sauf en mode
# embarqué dans l'app : écrire dans le bundle casserait sa signature.
_ICI = os.path.dirname(os.path.abspath(__file__))
if ".app/Contents/" in _ICI:
    DOSSIER_PHOTOS = os.path.expanduser(
        "~/Library/Application Support/EmpreinteMMD/photos")
else:
    DOSSIER_PHOTOS = os.path.join(_ICI, "photos")
os.makedirs(DOSSIER_PHOTOS, exist_ok=True)

# --- réglages du mélange « compléter sans abîmer » -----------------------
PERIODE_DEFAUT = 13.0      # période des crêtes (px) si la mesure échoue
QUALITE_BASSE = 10.0       # énergie de crêtes -> qualité 0 (zone floue/vide)
QUALITE_HAUTE = 38.0       # énergie de crêtes -> qualité 1 (crêtes franches)
EROSION_BORD = 4.0         # px rognés au bord d'une pose (contact douteux)
FONDU_BORD = 30.0          # px de montée en puissance après l'érosion
PLANCHER_QUALITE = 0.25    # une pose pâle pèse moins, mais couvre quand même
SEUIL_CONFIANCE = 0.8      # poids déjà accumulé à partir duquel on fait
                           # pleinement confiance à la mosaïque
PENTE_ARBITRAGE = 6.0      # netteté de la bascule entre poses de netteté différente
BIAIS_ARBITRAGE = 0.25     # marge : la meilleure pose garde la priorité
PLANCHER_ARBITRAGE = 0.05  # une pose franchement moins nette garde 5 % de voix

# --- réglages du consensus entre poses (anti-taches) ---------------------
NB_ORIENTATIONS = 16       # banc de Gabor pour la plausibilité (11,25° de pas)
SIGMA_PLAUSIBILITE = 0.4   # fenêtre de mesure de la plausibilité (en périodes)
SIGMA_ORIENTATION = 2.5    # lissage du tenseur de structure (en périodes)
EROSION_PLAUSIBILITE = 0.8 # la plausibilité prend le MIN sur ce diamètre (en
                           # périodes) : le pourtour d'une tache est suspect aussi
DESACCORD_BAS = 0.25       # résidu normalisé : en dessous, les poses sont d'accord
DESACCORD_HAUT = 0.65      # ... au-dessus, le désaccord est franc
PENTE_PLAUSIBILITE = 14.0  # netteté de la bascule vers la pose la plus plausible
BIAIS_PLAUSIBILITE = 0.08  # marge de plausibilité gardée par la meilleure pose
PLAUSIBILITE_MINI = 0.2    # en dessous (aucune pose n'a de crêtes ici), la
                           # netteté ne départage plus : simple moyenne
SIGMA_ROBUSTE = 0.25       # plancher de l'échelle du vote robuste (≥ 3 poses) :
                           # l'échelle réelle est le résidu moyen des poses
                           # présentes, une pose qui s'écarte ~2x plus que
                           # les autres perd sa voix
ITERATIONS_CONSENSUS = 2   # passes de repondération (IRLS), à 3 poses ou plus
AMPLITUDE_REFERENCE = 40.0 # amplitude (RMS) de crêtes franches sur l'image
                           # améliorée, et plancher de normalisation : une zone
AMPLITUDE_PLANCHER = 20.0  # pâle (tache sombre, pression faible) voit son bruit
                           # atténué au lieu d'être gonflé en « désaccord »


def masque_doigt(image):
    """Masque des zones qui contiennent vraiment des crêtes (fort contraste
    local), pour ne pas fondre le fond vide dans la mosaïque."""
    f = image.astype(np.float32)
    moyenne = cv2.GaussianBlur(f, (0, 0), 8)
    moyenne2 = cv2.GaussianBlur(f * f, (0, 0), 8)
    ecart_type = np.sqrt(np.maximum(moyenne2 - moyenne * moyenne, 0))
    masque = (ecart_type > 20).astype(np.uint8) * 255

    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    masque = cv2.morphologyEx(masque, cv2.MORPH_CLOSE, noyau)
    masque = cv2.morphologyEx(masque, cv2.MORPH_OPEN, noyau)

    # ne garde que la plus grande zone (le doigt), pas les taches isolées
    nb, etiquettes, stats, _ = cv2.connectedComponentsWithStats(masque)
    if nb > 1:
        plus_grande = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        masque = np.where(etiquettes == plus_grande, 255, 0).astype(np.uint8)
    return masque


def periode_cretes(image):
    """Période dominante des crêtes, en pixels (pic du spectre radial).

    Sert à calibrer la mesure de netteté quelle que soit la résolution : une
    capture du capteur (~13 px entre deux crêtes) et une image injectée par
    les tests (déjà agrandie) se mesurent alors sur la même échelle."""
    h, w = image.shape[:2]
    n = int(min(h, w, 256))
    if n < 32:
        return PERIODE_DEFAUT
    y0, x0 = (h - n) // 2, (w - n) // 2
    p = image[y0:y0 + n, x0:x0 + n].astype(np.float32)
    # passe-haut : le contour du doigt et l'éclairage (basses fréquences)
    # pèsent sinon plus lourd que les crêtes dans le spectre, et la période
    # mesurée saute à 30-40 px sur une pose au contact partiel
    p = p - cv2.GaussianBlur(p, (0, 0), 12.0)
    p = p * np.outer(np.hanning(n), np.hanning(n)).astype(np.float32)
    spectre = np.abs(np.fft.fftshift(np.fft.fft2(p))) ** 2
    centre = n // 2
    lignes, colonnes = np.mgrid[0:n, 0:n]
    rayon = np.hypot(lignes - centre, colonnes - centre).astype(np.int32).ravel()
    somme = np.bincount(rayon, spectre.ravel(), minlength=centre + 1)
    compte = np.maximum(np.bincount(rayon, minlength=centre + 1), 1)
    profil = (somme / compte)[:centre]
    # blanchiment : le spectre d'une image naturelle décroît en ~1/f², on
    # redresse pour que le pic des crêtes ressorte seul
    profil = profil * (np.arange(centre, dtype=np.float64) ** 2)
    bas, haut = max(int(n / 40), 2), max(int(n / 5), 4)   # périodes 5 à 40 px
    if haut <= bas + 1:
        return PERIODE_DEFAUT
    k = bas + int(np.argmax(profil[bas:haut]))
    return float(np.clip(n / max(k, 1), 5.0, 40.0))


def _etirer(brute):
    """Même étirement global (percentiles 2-98) que ameliorer(), en float :
    les poses se mesurent ainsi sur la même échelle."""
    bas, haut = (float(v) for v in np.percentile(brute, (2, 98)))
    if haut <= bas:
        haut = bas + 1.0
    return np.clip((brute.astype(np.float32) - bas) * 255.0 / (haut - bas),
                   0, 255).astype(np.float32)


def _passe_bande(f, periode):
    """Bande de fréquence des crêtes (différence de gaussiennes)."""
    return (cv2.GaussianBlur(f, (0, 0), periode / 6.0)
            - cv2.GaussianBlur(f, (0, 0), periode / 2.0))


def _ajuster_taille(carte, taille):
    if taille is not None and carte.shape != tuple(taille):
        carte = cv2.resize(carte, (int(taille[1]), int(taille[0])),
                           interpolation=cv2.INTER_LINEAR)
    return carte.astype(np.float32)


def carte_qualite(brute, taille=None, periode=None):
    """Netteté locale des crêtes, de 0 (rien d'exploitable) à 1 (crêtes
    franches), calculée sur la capture BRUTE.

    Volontairement mesurée avant ameliorer() : son CLAHE remonte le contraste
    d'une zone floue et la ferait passer pour nette. Sur la brute, un bord de
    doigt mal posé garde peu d'énergie dans la bande de fréquence des crêtes,
    et son score s'effondre — c'est ce qui empêche ce bord d'écraser une zone
    déjà bien scannée."""
    f = _etirer(brute)
    if periode is None:
        periode = periode_cretes(brute)
    bande = _passe_bande(f, periode)
    energie = np.sqrt(np.maximum(
        cv2.GaussianBlur(bande * bande, (0, 0), periode), 0.0))

    qualite = np.clip((energie - QUALITE_BASSE)
                      / (QUALITE_HAUTE - QUALITE_BASSE), 0.0, 1.0)
    return _ajuster_taille(qualite, taille)


_NOYAUX_GABOR = {}


def _noyaux_gabor(periode):
    """Banc de filtres de Gabor (cosinus) à la période donnée, un par
    orientation, normalisés pour répondre 1 à une sinusoïde d'amplitude 1 de
    même période et même orientation. Mis en cache (période arrondie)."""
    cle = round(float(periode), 1)
    if cle in _NOYAUX_GABOR:
        return _NOYAUX_GABOR[cle]
    sigma = 0.55 * cle                      # ~1 période de large à mi-hauteur
    taille = 2 * int(np.ceil(2.5 * sigma)) + 1
    demi = taille // 2
    yy, xx = np.mgrid[-demi:demi + 1, -demi:demi + 1].astype(np.float32)
    noyaux = []
    for k in range(NB_ORIENTATIONS):
        theta = np.pi * k / NB_ORIENTATIONS   # direction NORMALE aux crêtes
        u = xx * np.cos(theta) + yy * np.sin(theta)
        v = -xx * np.sin(theta) + yy * np.cos(theta)
        # un peu plus long le long des crêtes (gamma < 1) : suit la crête
        g = np.exp(-(u * u + (0.7 * v) ** 2) / (2 * sigma * sigma))
        noyau = g * np.cos(2 * np.pi * u / cle)
        noyau -= noyau.mean() * g / g.mean()  # moyenne nulle (ignore l'éclairage)
        gain = float((noyau * np.cos(2 * np.pi * u / cle)).sum())
        noyaux.append((noyau / max(gain, 1e-6)).astype(np.float32))
    _NOYAUX_GABOR[cle] = noyaux
    return noyaux


def orientation_cretes(bande, periode):
    """Direction locale du gradient dominant (normale aux crêtes), en
    radians dans [0, pi), par tenseur de structure lissé sur ~2,5 périodes.

    Les gradients sont NORMALISÉS avant le tenseur : chaque pixel vote avec
    la même voix quel que soit son contraste. Sans cela, une traînée claire
    bien contrastée impose sa propre direction à tout son voisinage, et la
    plausibilité la prend alors pour une crête parfaitement régulière."""
    gx = cv2.Sobel(bande, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(bande, cv2.CV_32F, 0, 1, ksize=3)
    norme = np.sqrt(gx * gx + gy * gy) + 0.5 * QUALITE_BASSE
    gx, gy = gx / norme, gy / norme
    s = SIGMA_ORIENTATION * periode
    jxx = cv2.GaussianBlur(gx * gx, (0, 0), s)
    jyy = cv2.GaussianBlur(gy * gy, (0, 0), s)
    jxy = cv2.GaussianBlur(gx * gy, (0, 0), s)
    theta = 0.5 * np.arctan2(2.0 * jxy, jxx - jyy)      # ]-pi/2, pi/2]
    return np.mod(theta, np.pi).astype(np.float32)


def carte_plausibilite(brute, taille=None, periode=None):
    """À quel point chaque voisinage ressemble à des crêtes PROPRES, de 0 à 1.

    On ajuste localement une sinusoïde orientée (filtre de Gabor à la période
    et dans la direction mesurées) et on garde le carré de la corrélation
    locale entre l'image et cet ajustement, sur une fenêtre de ~1 période.
    Des crêtes régulières donnent ~1. Une tache qui ne suit pas les crêtes —
    blob sombre pontant deux crêtes, point clair rond, traînée — n'est pas
    expliquée par la sinusoïde : le score chute. Un point clair qui efface
    les crêtes n'a aucune énergie à expliquer : score ~0.

    Mesurée sur la brute (même échelle pour toutes les poses, et quatre fois
    moins de pixels que l'image améliorée). Sert UNIQUEMENT à départager des
    poses en désaccord : un détail vrai mais peu « sinusoïdal » (pore,
    cicatrice, minutie), présent dans toutes les poses, n'est pas touché."""
    f = _etirer(brute)
    if periode is None:
        periode = periode_cretes(brute)
    bande = _passe_bande(f, periode)
    theta = orientation_cretes(bande, periode)

    # réponse du Gabor dans l'orientation locale (la plus proche du banc)
    noyaux = _noyaux_gabor(periode)
    indices = np.rint(theta * NB_ORIENTATIONS / np.pi).astype(np.int32) \
        % NB_ORIENTATIONS
    modele = np.zeros_like(bande)
    for k, noyau in enumerate(noyaux):
        zone = indices == k
        if not zone.any():
            continue
        reponse = cv2.filter2D(bande, -1, noyau, borderType=cv2.BORDER_REFLECT)
        modele[zone] = reponse[zone]

    s = SIGMA_PLAUSIBILITE * periode
    fm = cv2.GaussianBlur(bande * modele, (0, 0), s)
    ff = cv2.GaussianBlur(bande * bande, (0, 0), s)
    mm = cv2.GaussianBlur(modele * modele, (0, 0), s)
    # epsilon ~ (énergie d'une zone vide)^2 : une zone plate tombe à 0
    eps = (0.5 * QUALITE_BASSE * QUALITE_BASSE) ** 2
    plausibilite = np.clip(fm * fm / (ff * mm + eps), 0.0, 1.0)
    # le pourtour d'une tache est suspect aussi (c'est là que le désaccord
    # avec les autres poses déborde) : minimum sur ~0,8 période
    diametre = int(EROSION_PLAUSIBILITE * periode) | 1
    if diametre >= 3:
        plausibilite = cv2.erode(plausibilite, cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (diametre, diametre)))
    return _ajuster_taille(plausibilite, taille)


def aligner_sift(reference, image, masque_ref, masque_img):
    """Transformation rigide (rotation+translation) image -> référence par
    points SIFT + RANSAC. Retourne une matrice 2x3, ou None si échec."""
    sift = cv2.SIFT_create(nfeatures=4000)
    points_ref, desc_ref = sift.detectAndCompute(reference, masque_ref)
    points_img, desc_img = sift.detectAndCompute(image, masque_img)
    if desc_ref is None or desc_img is None \
            or len(points_ref) < 20 or len(points_img) < 20:
        return None

    paires = cv2.BFMatcher(cv2.NORM_L2).knnMatch(desc_img, desc_ref, k=2)
    bonnes = [m for m, n in paires if m.distance < 0.75 * n.distance]
    if len(bonnes) < 12:
        return None

    source = np.float32([points_img[m.queryIdx].pt for m in bonnes])
    cible = np.float32([points_ref[m.trainIdx].pt for m in bonnes])
    M, inliers = cv2.estimateAffinePartial2D(
        source, cible, method=cv2.RANSAC, ransacReprojThreshold=4)
    if M is None or inliers is None or int(inliers.sum()) < 10:
        return None

    # garde-fous : échelle ~1 (même capteur) et rotation raisonnable
    echelle = float(np.hypot(M[0, 0], M[0, 1]))
    angle = abs(np.degrees(np.arctan2(M[1, 0], M[0, 0])))
    if not 0.85 < echelle < 1.18 or angle > 30:
        return None
    return M


def aligner_correlation(reference, image, masque_img=None, masque_ref=None):
    """Recherche grossière de la position de la capture dans la référence :
    template matching multi-angle sur cartes signées réduites 4x
    (crêtes = +1, vallées = -1, vide = 0 : un mauvais alignement donne ~0).
    Retourne une liste de matrices 2x3 candidates, meilleures d'abord —
    c'est la vérification de recouvrement (SessionFusion) qui tranchera."""
    REDUC = 4
    h, w = image.shape
    if masque_img is None:
        masque_img = np.full((h, w), 255, np.uint8)
    if masque_ref is None:
        masque_ref = np.full(reference.shape, 255, np.uint8)

    ref_signe = ((127.5 - reference.astype(np.float32)) / 127.5
                 * (masque_ref.astype(np.float32) / 255.0))
    img_signe = ((127.5 - image.astype(np.float32)) / 127.5
                 * (masque_img.astype(np.float32) / 255.0))

    ref_petit = cv2.resize(ref_signe, None, fx=1 / REDUC, fy=1 / REDUC,
                           interpolation=cv2.INTER_AREA)
    hp, wp = h // REDUC, w // REDUC
    # énergie locale de la référence, pour ignorer les positions quasi vides
    energie_ref = cv2.boxFilter(ref_petit * ref_petit, -1, (wp, hp),
                                normalize=False)

    candidats = []
    for angle in range(-12, 13, 3):
        R = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
        img_r = cv2.warpAffine(img_signe, R, (w, h), borderValue=0)
        masque_r = cv2.warpAffine(masque_img, R, (w, h), borderValue=0)
        petit = cv2.resize(img_r, (wp, hp), interpolation=cv2.INTER_AREA)
        masque_petit = ((cv2.resize(masque_r, (wp, hp),
                                    interpolation=cv2.INTER_AREA) > 127)
                        * 255).astype(np.uint8)
        if ref_petit.shape[0] <= hp or ref_petit.shape[1] <= wp:
            continue

        scores = cv2.matchTemplate(ref_petit, petit, cv2.TM_CCORR_NORMED,
                                   mask=masque_petit)
        scores = np.nan_to_num(scores, nan=0.0, posinf=0.0, neginf=0.0)
        # coupe les positions où la référence est presque vide
        zone = energie_ref[hp // 2:hp // 2 + scores.shape[0],
                           wp // 2:wp // 2 + scores.shape[1]]
        scores[zone < 0.05 * float((petit * petit).sum())] = 0.0

        _, score, _, position = cv2.minMaxLoc(scores)
        if score <= 0:
            continue
        R3 = np.vstack([R, [0, 0, 1]])
        T3 = np.float32([[1, 0, position[0] * REDUC],
                         [0, 1, position[1] * REDUC], [0, 0, 1]])
        candidats.append((score, np.float32((T3 @ R3)[:2])))

    candidats.sort(key=lambda c: c[0], reverse=True)
    return [M for _, M in candidats[:6]]


class SessionFusion:
    """Mosaïque incrémentale : on ajoute les scans un par un, chacun se
    raccorde à ce qui est déjà posé.

    Chaque pose acceptée reste en mémoire comme une COUCHE alignée (bloc de
    toile warpé, poids, netteté, plausibilité, crêtes signées) : la mosaïque
    affichée est à tout moment le consensus de toutes les couches, recalculé
    dans l'emprise de chaque nouvelle pose (§ _recomposer)."""

    def __init__(self):
        self.numerateur = None
        self.denominateur = None
        self.couverture = None      # poids purement géométrique : « il y a
                                    # quelque chose ici » (sert aux raccords)
        self.qualite_num = None     # netteté accumulée (à diviser par le poids)
        self.H = self.W = 0
        self.nb_posees = 0
        self.couches = []           # une entrée par pose acceptée (§ _deposer)
        self.captures = []          # captures BRUTES acceptées, dans l'ordre
        self.periode = PERIODE_DEFAUT * 2   # période des crêtes sur la toile

    def ajouter(self, capture_brute):
        """Améliore, aligne et fond une capture (niveaux de gris numpy).
        Retourne True si elle a pu être raccordée."""
        traitee = ameliorer_empreinte.ameliorer(capture_brute)
        masque = masque_doigt(traitee)
        if int((masque > 0).sum()) < 2000:
            return False                      # capture quasi vide
        periode = periode_cretes(capture_brute)
        qualite = carte_qualite(capture_brute, traitee.shape, periode)
        plausibilite = carte_plausibilite(capture_brute, traitee.shape, periode)
        h, w = traitee.shape

        if self.numerateur is None:
            # première pose : grande toile (dimensions paires, le consensus
            # travaille en demi-résolution), capture au centre
            self.H, self.W = (h * 3 + 1) & ~1, (w * 3 + 1) & ~1
            self.numerateur = np.zeros((self.H, self.W), np.float64)
            self.denominateur = np.zeros((self.H, self.W), np.float64)
            self.couverture = np.zeros((self.H, self.W), np.float32)
            self.qualite_num = np.zeros((self.H, self.W), np.float32)
            M = np.float32([[1, 0, (self.W - w) // 2],
                            [0, 1, (self.H - h) // 2]])
        else:
            mosaique = self.image_actuelle()
            candidats = []
            candidat_sift = aligner_sift(mosaique, traitee,
                                         self.masque_actuel(), masque)
            if candidat_sift is not None:
                candidats.append(candidat_sift)
            candidats += aligner_correlation(mosaique, traitee, masque,
                                             self.masque_actuel())
            if not candidats:
                print("   (raccord : aucun candidat d'alignement trouvé)")
                return False

            M = None
            meilleure = -1.0
            for candidat in candidats:
                affine = self._affiner_ecc(mosaique, traitee, masque, candidat)
                correlation = self._verifier(mosaique, traitee, masque, affine)
                meilleure = max(meilleure, correlation)
                if correlation > 0.35:
                    M = affine
                    break
            if M is None:
                print(f"   (raccord rejeté : meilleure corrélation {meilleure:.2f},"
                      " il faut > 0.35 — recouvre mieux la zone déjà scannée)")
                return False

        # l'image améliorée est agrandie 2x : la période sur la toile l'est aussi
        self._deposer(traitee, masque, M, qualite, plausibilite, 2.0 * periode)
        self.captures.append(np.array(capture_brute, dtype=np.uint8, copy=True))
        self.nb_posees += 1
        return True

    def _affiner_ecc(self, mosaique, image, masque, M):
        """Affine un candidat d'alignement au dixième de degré près
        (findTransformECC, itératif). Retourne M inchangé si échec."""
        # ne fait compter que les pixels du doigt qui tombent sur la zone
        # déjà couverte de la mosaïque (au candidat près)
        projection = cv2.warpAffine(self.masque_actuel(),
                                    cv2.invertAffineTransform(M),
                                    (image.shape[1], image.shape[0]),
                                    flags=cv2.INTER_NEAREST, borderValue=0)
        masque_ecc = (((masque > 127) & (projection > 127)) * 255).astype(np.uint8)
        if int((masque_ecc > 0).sum()) < 5000:
            return M
        critere = (cv2.TERM_CRITERIA_COUNT | cv2.TERM_CRITERIA_EPS, 60, 1e-4)
        try:
            # findTransformECC travaille avec la matrice inverse de la nôtre
            # (toile -> capture) : on inverse à l'entrée et à la sortie
            _, M_inverse = cv2.findTransformECC(
                np.float32(mosaique), np.float32(image),
                cv2.invertAffineTransform(M).astype(np.float32),
                cv2.MOTION_EUCLIDEAN, critere, masque_ecc, 5)
            return cv2.invertAffineTransform(M_inverse)
        except cv2.error:
            return M

    def _verifier(self, mosaique, image, masque, M):
        """Corrélation des crêtes de la capture avec la mosaïque à l'endroit
        proposé (-1 si le recouvrement est trop petit pour juger)."""
        image_t = cv2.warpAffine(image, M, (self.W, self.H), borderValue=0)
        masque_t = cv2.warpAffine(masque, M, (self.W, self.H), borderValue=0)
        zone = (masque_t > 127) & (self.couverture > 0.05)
        if int(zone.sum()) < 8000:            # recouvrement trop petit
            return -1.0
        a = image_t[zone].astype(np.float32)
        b = mosaique[zone].astype(np.float32)
        a -= a.mean()
        b -= b.mean()
        energie = float(np.sqrt((a * a).sum() * (b * b).sum()))
        if energie < 1e-6:
            return -1.0
        return float((a * b).sum()) / energie

    def _emprise(self, forme, M):
        """Rectangle de la toile réellement touché par une pose (marge de 2 px).
        Tout le mélange se fait dans ce bloc : neuf fois moins de calcul que
        sur la toile entière."""
        h, w = forme
        coins = np.float32([[0, 0], [w, 0], [0, h], [w, h]])
        projetes = coins @ M[:, :2].T.astype(np.float32) + M[:, 2]
        # coordonnées PAIRES : le consensus se calcule en demi-résolution, et
        # un redimensionnement exactement 1/2 est 50x plus rapide qu'un autre
        x0 = max(int(np.floor(projetes[:, 0].min())) - 2, 0) & ~1
        x1 = min((int(np.ceil(projetes[:, 0].max())) + 3) & ~1, self.W)
        y0 = max(int(np.floor(projetes[:, 1].min())) - 2, 0) & ~1
        y1 = min((int(np.ceil(projetes[:, 1].max())) + 3) & ~1, self.H)
        return y0, y1, x0, x1

    def _deposer(self, image, masque, M, qualite=None, plausibilite=None,
                 periode=None):
        """Range une pose alignée comme nouvelle COUCHE (bloc de toile warpé
        + poids géométrique + netteté + plausibilité + crêtes signées), puis
        recompose la mosaïque dans son emprise à partir de toutes les couches
        (§ _recomposer). Le poids géométrique rogne et fond le bord de pose
        pour que la couture reste invisible."""
        if qualite is None:
            qualite = np.ones(image.shape, np.float32)
        if plausibilite is None:
            plausibilite = np.ones(image.shape, np.float32)
        if periode is None:
            periode = self.periode
        # 1. poids géométrique : bord de pose rogné puis fondu jusqu'au coeur.
        #    Le contact du doigt est toujours douteux sur son pourtour — et le
        #    bord de l'IMAGE en est un aussi, puisque la capture s'arrête là.
        #    Le cadre de zéros ci-dessous est indispensable : sans lui,
        #    distanceTransform ne voit pas le bord de l'image (il ne cherche
        #    des zéros qu'À L'INTÉRIEUR), la pose garde un poids plein jusqu'au
        #    dernier pixel, et une fois posée de travers elle découpe dans la
        #    mosaïque une couture rectiligne — le poids tombe de 1 à 0 en un
        #    seul pixel tout le long du rectangle.
        distance = cv2.distanceTransform(
            cv2.copyMakeBorder((masque > 0).astype(np.uint8), 1, 1, 1, 1,
                               cv2.BORDER_CONSTANT, value=0),
            cv2.DIST_L2, 5)[1:-1, 1:-1]
        poids = np.clip((distance - EROSION_BORD) / FONDU_BORD, 0.0, 1.0)
        poids = poids.astype(np.float32)

        # 2. la pondération par la netteté locale et l'arbitrage entre poses
        #    se font à la recomposition (§ _recomposer), à partir des cartes
        #    gardées ci-dessous
        y0, y1, x0, x1 = self._emprise(image.shape, M)
        if y1 <= y0 or x1 <= x0:
            return
        taille = (x1 - x0, y1 - y0)
        Mb = M.astype(np.float32).copy()
        Mb[0, 2] -= x0
        Mb[1, 2] -= y0

        def vers_bloc(source):
            return cv2.warpAffine(source, Mb, taille,
                                  flags=cv2.INTER_LINEAR, borderValue=0)

        image_t = vers_bloc(image.astype(np.float32))
        poids_t = vers_bloc(poids)
        qualite_t = vers_bloc(qualite.astype(np.float32))
        plausibilite_t = vers_bloc(plausibilite.astype(np.float32))

        # 3. crêtes signées normalisées (bande des crêtes / amplitude locale) :
        #    c'est là-dessus que les poses se comparent, insensible au
        #    contraste. Des crêtes franches donnent ~±1 ; le plancher
        #    d'amplitude évite de gonfler le bruit d'une zone pâle.
        bande = _passe_bande(image_t, periode)
        amplitude = np.sqrt(np.maximum(
            cv2.GaussianBlur(bande * bande, (0, 0), periode), 0.0))
        echelle = (AMPLITUDE_REFERENCE + AMPLITUDE_PLANCHER) / AMPLITUDE_REFERENCE
        cretes_t = bande * echelle / (amplitude + AMPLITUDE_PLANCHER)

        # les cartes qui ne servent qu'au consensus sont gardées en
        # demi-résolution (l'emprise a des dimensions paires, cf. _emprise)
        demi = (taille[0] // 2, taille[1] // 2)

        def en_demi(carte):
            return cv2.resize(carte, demi, interpolation=cv2.INTER_AREA)

        self.couches.append({
            "y0": y0, "y1": y1, "x0": x0, "x1": x1, "M": M.copy(),
            "image": image_t, "poids": poids_t, "qualite": qualite_t,
            "plausibilite_demi": en_demi(plausibilite_t),
            "cretes_demi": en_demi(cretes_t), "periode": float(periode)})
        self.periode = float(np.median([c["periode"] for c in self.couches]))
        self._recomposer(y0, y1, x0, x1)

    def _couche_sur(self, couche, y0, y1, x0, x1, cle, demi=False):
        """Le bloc `cle` d'une couche, découpé/complété à zéro sur la zone
        (en demi-résolution pour les cartes *_demi : toutes les coordonnées
        d'emprise sont paires)."""
        r = 2 if demi else 1
        bloc = np.zeros(((y1 - y0) // r, (x1 - x0) // r), np.float32)
        iy0, iy1 = max(y0, couche["y0"]), min(y1, couche["y1"])
        ix0, ix1 = max(x0, couche["x0"]), min(x1, couche["x1"])
        if iy1 > iy0 and ix1 > ix0:
            bloc[(iy0 - y0) // r:(iy1 - y0) // r,
                 (ix0 - x0) // r:(ix1 - x0) // r] = couche[cle][
                (iy0 - couche["y0"]) // r:(iy1 - couche["y0"]) // r,
                (ix0 - couche["x0"]) // r:(ix1 - couche["x0"]) // r]
        return bloc

    def _recomposer(self, y0, y1, x0, x1):
        """Recalcule la mosaïque sur une zone de la toile comme CONSENSUS de
        toutes les couches qui la touchent :
          1. poids de base = géométrie x netteté (une pose pâle couvre quand
             même) ; puis arbitrage par netteté, symétrique entre les poses :
             la plus nette l'emporte, un bord flou perd sa voix ;
          2. désaccord local : résidu entre les crêtes d'une pose et
             l'estimation des AUTRES, lissé sur ~1 période ;
          3. là où il y a désaccord, la pose la plus plausible l'emporte
             (sigmoïde sur la plausibilité) et, à 3 poses ou plus, celle qui
             s'écarte nettement plus que les autres perd sa voix (vote
             robuste, repondéré) ;
          4. la référence de netteté ignore les poses contredites, et à 3
             poses ou plus une 2e passe recalcule l'estimation avec les poids
             corrigés.
        Là où une seule pose existe, ou là où elles sont d'accord, le poids de
        base reste tel quel : rien n'est jamais perdu sans contradiction.

        Les cartes de poids sont lisses à l'échelle de la demi-période : tout
        l'arbitrage se calcule en DEMI-résolution (4x moins de calcul), seule
        la composition finale se fait sur les pixels de la toile."""
        couches = [c for c in self.couches
                   if c["y1"] > y0 and c["y0"] < y1 and c["x1"] > x0 and c["x0"] < x1]
        if not couches:
            return
        zone = (y0, y1, x0, x1)
        poids = [self._couche_sur(c, *zone, "poids") for c in couches]
        images = [self._couche_sur(c, *zone, "image") for c in couches]
        qualite = [self._couche_sur(c, *zone, "qualite") for c in couches]

        # poids de base = géométrie x netteté ; le plancher garantit qu'une
        # pose pâle couvre quand même la zone (sinon, trou blanc)
        def base_de(poids_, qualite_):
            return poids_ * (PLANCHER_QUALITE + (1.0 - PLANCHER_QUALITE) * qualite_)

        if len(couches) == 1:
            w = [base_de(poids[0], qualite[0])]
        else:
            h, l = y1 - y0, x1 - x0                 # pairs (cf. _emprise)
            hp, lp = h // 2, l // 2

            def petit(carte):
                return cv2.resize(carte, (lp, hp), interpolation=cv2.INTER_AREA)

            poids_p = [petit(p) for p in poids]
            qualite_p = [petit(q) for q in qualite]
            base = [base_de(p, q) for p, q in zip(poids_p, qualite_p)]
            # 1. arbitrage par netteté (symétrique) : la pose la plus nette fait
            #    référence ; une pose n'est crédible que là où elle a du poids,
            #    sur son bord en fondu sa netteté compte progressivement
            confiance = [np.clip(p / SEUIL_CONFIANCE, 0.0, 1.0) for p in poids_p]
            q_eff = [q * cf for q, cf in zip(qualite_p, confiance)]

            cretes = [self._couche_sur(c, *zone, "cretes_demi", demi=True)
                      for c in couches]
            # plausibilité effective : une pose n'est crédible que là où elle a
            # du poids (son bord en fondu plaide moins) ; la référence est la
            # meilleure des poses présentes, chacune est jugée par rapport à elle
            plaus = [self._couche_sur(c, *zone, "plausibilite_demi", demi=True) * cf
                     for c, cf in zip(couches, confiance)]
            p_ref = np.maximum.reduce(plaus)
            # là où AUCUNE pose n'a de crêtes plausibles, la netteté ne veut
            # plus rien dire (une tache a de l'énergie...) : on n'arbitre plus
            credible = np.clip(p_ref / PLAUSIBILITE_MINI, 0.0, 1.0)

            def arbitrage(q_ref):
                facteurs = []
                for q in q_eff:
                    avantage = (q - q_ref) / (q_ref + 0.15)
                    facteur = PLANCHER_ARBITRAGE + (1.0 - PLANCHER_ARBITRAGE) / (
                        1.0 + np.exp(-PENTE_ARBITRAGE * (avantage + BIAIS_ARBITRAGE)))
                    facteurs.append((1.0 + credible * (facteur - 1.0))
                                    .astype(np.float32))
                return facteurs

            s = [1.0 / (1.0 + np.exp(-PENTE_PLAUSIBILITE
                                     * (pl - p_ref + BIAIS_PLAUSIBILITE)))
                 for pl in plaus]
            # « quelqu'un en face » : d'autres poses ont du poids ici (fixé
            # d'après les poids de base, il ne bouge pas d'une passe à l'autre)
            sigma_r = 0.25 * self.periode             # demi-période, en demi-res
            somme_base = np.add.reduce(base)
            presences, normes = [], []
            for b in base:
                en_face = (somme_base - b > 0.02).astype(np.float32)
                presences.append(en_face)
                normes.append(np.maximum(cv2.GaussianBlur(en_face, (0, 0), sigma_r),
                                         0.2))

            facteurs = arbitrage(np.maximum.reduce(q_eff))
            w = [b * f for b, f in zip(base, facteurs)]
            # à 2 poses, l'estimation « de l'autre » ne dépend pas des poids :
            # une seule passe suffit
            passes = ITERATIONS_CONSENSUS if len(couches) > 2 else 1
            for _ in range(passes):
                somme_w = np.add.reduce(w)
                somme_wc = np.add.reduce([wi * ci for wi, ci in zip(w, cretes)])
                residus = []
                for wi, ci, en_face, norme in zip(w, cretes, presences, normes):
                    # 2. estimation des AUTRES poses (sans celle-ci) et résidu
                    #    lissé sur ~1 période, là où il y a quelqu'un en face
                    autres = somme_w - wi
                    estimation = (somme_wc - wi * ci) / np.maximum(autres, 1e-6)
                    ecart = np.abs(ci - estimation) * en_face
                    residus.append(cv2.GaussianBlur(ecart, (0, 0), sigma_r)
                                   / norme * en_face)
                # échelle du vote robuste : le résidu moyen des poses présentes
                # (dans une zone bruitée, tout le monde s'écarte un peu ; seule
                # la pose qui s'écarte nettement plus que les autres est rejetée)
                echelle = np.maximum(np.add.reduce(residus)
                                     / np.maximum(np.add.reduce(presences), 1.0),
                                     SIGMA_ROBUSTE)
                correction = []
                for residu, si in zip(residus, s):
                    desaccord = np.clip((residu - DESACCORD_BAS)
                                        / (DESACCORD_HAUT - DESACCORD_BAS),
                                        0.0, 1.0)
                    # 3. en cas de désaccord : plausibilité et vote robuste
                    robuste = 1.0 / (1.0 + (residu / echelle) ** 4)
                    correction.append(((1.0 - desaccord)
                                       + desaccord * si * robuste).astype(np.float32))
                # 4. la référence de netteté ignore les poses contredites : une
                #    tache a de l'énergie dans la bande des crêtes et passe pour
                #    « nette », elle ne doit pas rabaisser les poses saines
                facteurs = arbitrage(np.maximum.reduce(
                    [q * c for q, c in zip(q_eff, correction)]))
                w = [b * f * c for b, f, c in zip(base, facteurs, correction)]
            # retour à la pleine résolution ; le poids reste nul hors de la pose
            w = [cv2.resize(wi, (l, h), interpolation=cv2.INTER_LINEAR) * (p > 0)
                 for wi, p in zip(w, poids)]

        self.numerateur[y0:y1, x0:x1] = np.add.reduce(
            [wi.astype(np.float64) * im for wi, im in zip(w, images)])
        self.denominateur[y0:y1, x0:x1] = np.add.reduce(w).astype(np.float64)
        self.couverture[y0:y1, x0:x1] = np.add.reduce(poids)
        self.qualite_num[y0:y1, x0:x1] = np.add.reduce(
            [wi * q for wi, q in zip(w, qualite)])

    def image_actuelle(self):
        couvert = self.couverture > 0.05
        image = np.full((self.H, self.W), 255, np.uint8)
        poids = np.maximum(self.denominateur[couvert], 1e-6)
        image[couvert] = np.clip(self.numerateur[couvert] / poids,
                                 0, 255).astype(np.uint8)
        return image

    def masque_actuel(self):
        return ((self.couverture > 0.05) * 255).astype(np.uint8)

    def _recadrer(self, image):
        lignes, colonnes = np.where(self.couverture > 0.05)
        marge = 12
        return image[max(int(lignes.min()) - marge, 0):
                     min(int(lignes.max()) + marge, self.H),
                     max(int(colonnes.min()) - marge, 0):
                     min(int(colonnes.max()) + marge, self.W)]

    def apercu(self, chemin=None):
        """Écrit l'aperçu de la mosaïque en cours, retourne son chemin."""
        if self.nb_posees == 0:
            return None
        if chemin is None:
            chemin = os.path.join(DOSSIER_PHOTOS, "apercu_fusion.png")
        cv2.imwrite(chemin, normaliser_affichage(
            self._recadrer(self.image_actuelle())))
        return chemin

    def finaliser(self):
        """Retourne (mosaïque, crêtes complétées ou None), ou (None, None)."""
        if self.nb_posees == 0:
            return None, None
        mosaique = cv2.medianBlur(self._recadrer(self.image_actuelle()), 3)
        # marge blanche autour pour que l'ovale complet tienne dans l'image
        marge = int(0.09 * max(mosaique.shape))
        mosaique = cv2.copyMakeBorder(mosaique, marge, marge, marge, marge,
                                      cv2.BORDER_CONSTANT, value=255)
        try:
            import completer_empreinte
            cretes = completer_empreinte.completer(mosaique, ovale=True)
        except Exception as erreur:
            print(f"   (complétion impossible : {erreur}), Gabor simple")
            cretes = ameliorer_empreinte.cretes_gabor(mosaique)
        return mosaique, cretes


def normaliser_affichage(gris):
    """Renforce localement le contraste pour l'affichage : les crêtes
    ressortent nettes même là où la mosaïque est pâle, le vide reste blanc."""
    f = gris.astype(np.float32)
    oscillation = cv2.GaussianBlur(f, (0, 0), 8) - f
    ecart = np.sqrt(cv2.GaussianBlur(oscillation * oscillation, (0, 0), 12))
    s = np.clip(oscillation / (1.6 * ecart + 6.0), -1, 1)
    presence = np.clip((ecart - 5.0) / 15.0, 0, 1)     # 0 = vide, 1 = crêtes
    return (255.0 * (1 - presence)
            + presence * (127.5 - 127.5 * s)).astype(np.uint8)


def enregistrer_resultat(mosaique, cretes):
    """Montage final -> empreinte_fusion_*.png. Retourne le chemin ou None."""
    if mosaique is None:
        return None
    images, etiquettes = [normaliser_affichage(mosaique)], ["fusion"]
    if cretes is not None:
        images.append(cretes)
        etiquettes.append("cretes (completees)")
    montage = ameliorer_empreinte.montage(images, etiquettes)
    horodatage = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    chemin = os.path.join(DOSSIER_PHOTOS, f"empreinte_fusion_{horodatage}.png")
    cv2.imwrite(chemin, montage)
    print(f"   -> {chemin}")
    if cretes is not None:
        try:
            import tracer_svg
            chemin_svg = os.path.join(DOSSIER_PHOTOS,
                                      f"empreinte_fusion_{horodatage}.svg")
            nb = tracer_svg.tracer_svg(cretes, chemin_svg)
            print(f"   -> {chemin_svg} ({nb} traits)")
        except Exception as erreur:
            print(f"   (SVG non généré : {erreur})")
    return chemin


def finaliser_et_enregistrer(session):
    mosaique, cretes = session.finaliser()
    return enregistrer_resultat(mosaique, cretes)


def session_depuis_captures(captures, ordre_couverture=True):
    """Re-fusionne une liste de captures BRUTES (numpy uint8) dans une
    SessionFusion neuve — pour refaire la mosaïque à partir des poses
    sauvées sur disque (session.captures). Par défaut on commence par la
    plus couverte, comme en mode lot ; ordre_couverture=False garde l'ordre
    donné (celui des poses en direct). Retourne la session."""
    if ordre_couverture:
        aires = [int((masque_doigt(ameliorer_empreinte.ameliorer(c)) > 0).sum())
                 for c in captures]
        ordre = [int(i) for i in np.argsort(aires)[::-1]]
    else:
        ordre = list(range(len(captures)))
    session = SessionFusion()
    for i in ordre:
        raccordee = session.ajouter(captures[i])
        print(f"   capture {i + 1} : "
              f"{'raccordée' if raccordee else 'impossible à raccorder, ignorée'}")
    return session


def fusionner_et_enregistrer(captures):
    """Mode lot : fusionne une liste d'images numpy en commençant par la
    plus couverte. Retourne le chemin du montage, ou None."""
    session = session_depuis_captures(captures)
    if session.nb_posees < 2:
        return None
    return finaliser_et_enregistrer(session)


def principal():
    fichiers = sys.argv[1:]
    if len(fichiers) < 2:
        sys.exit("Donne au moins 2 captures :\n"
                 "    python3 fusionner_empreinte.py a.png b.png [c.png ...]")
    captures = []
    for f in fichiers:
        gris = cv2.imread(f, cv2.IMREAD_GRAYSCALE)
        if gris is None:
            sys.exit(f"Illisible : {f}")
        captures.append(gris)
    if not fusionner_et_enregistrer(captures):
        sys.exit("Fusion impossible : pas assez de recouvrement entre les captures.")


if __name__ == "__main__":
    principal()
