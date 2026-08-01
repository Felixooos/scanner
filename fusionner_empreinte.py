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
et SessionFusion._deposer) : là où il n'y a rien encore, elle remplit ; là où il
y a déjà des crêtes, c'est la meilleure des deux qui l'emporte, mesurée par une
carte de netteté locale. Un bord de pose flou (contact partiel du doigt) ne peut
donc plus écraser une zone déjà nette.
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
PENTE_ARBITRAGE = 6.0      # netteté de la bascule ancien <-> nouveau
BIAIS_ARBITRAGE = 0.25     # à qualité égale, l'existant garde la priorité
PLANCHER_ARBITRAGE = 0.05  # un nouveau franchement moins bon garde 5 % de voix


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
    p = (p - p.mean()) * np.outer(np.hanning(n), np.hanning(n)).astype(np.float32)
    spectre = np.abs(np.fft.fftshift(np.fft.fft2(p))) ** 2
    centre = n // 2
    lignes, colonnes = np.mgrid[0:n, 0:n]
    rayon = np.hypot(lignes - centre, colonnes - centre).astype(np.int32).ravel()
    somme = np.bincount(rayon, spectre.ravel(), minlength=centre + 1)
    compte = np.maximum(np.bincount(rayon, minlength=centre + 1), 1)
    profil = (somme / compte)[:centre]
    bas, haut = max(int(n / 40), 2), max(int(n / 6), 4)   # périodes 6 à 40 px
    if haut <= bas + 1:
        return PERIODE_DEFAUT
    k = bas + int(np.argmax(profil[bas:haut]))
    return float(np.clip(n / max(k, 1), 6.0, 40.0))


def carte_qualite(brute, taille=None):
    """Netteté locale des crêtes, de 0 (rien d'exploitable) à 1 (crêtes
    franches), calculée sur la capture BRUTE.

    Volontairement mesurée avant ameliorer() : son CLAHE remonte le contraste
    d'une zone floue et la ferait passer pour nette. Sur la brute, un bord de
    doigt mal posé garde peu d'énergie dans la bande de fréquence des crêtes,
    et son score s'effondre — c'est ce qui empêche ce bord d'écraser une zone
    déjà bien scannée."""
    bas, haut = np.percentile(brute, (2, 98))         # même étirement global
    if haut <= bas:                                   # que ameliorer(), pour
        haut = bas + 1.0                              # comparer des poses
    f = np.clip((brute.astype(np.float32) - bas) * 255.0 / (haut - bas), 0, 255)

    periode = periode_cretes(brute)
    bande = (cv2.GaussianBlur(f, (0, 0), periode / 6.0)
             - cv2.GaussianBlur(f, (0, 0), periode / 2.0))
    energie = np.sqrt(np.maximum(
        cv2.GaussianBlur(bande * bande, (0, 0), periode), 0.0))

    qualite = np.clip((energie - QUALITE_BASSE)
                      / (QUALITE_HAUTE - QUALITE_BASSE), 0.0, 1.0)
    if taille is not None and qualite.shape != tuple(taille):
        qualite = cv2.resize(qualite, (int(taille[1]), int(taille[0])),
                             interpolation=cv2.INTER_LINEAR)
    return qualite.astype(np.float32)


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
    raccorde à ce qui est déjà posé."""

    def __init__(self):
        self.numerateur = None
        self.denominateur = None
        self.couverture = None      # poids purement géométrique : « il y a
                                    # quelque chose ici » (sert aux raccords)
        self.qualite_num = None     # netteté accumulée (à diviser par le poids)
        self.H = self.W = 0
        self.nb_posees = 0

    def ajouter(self, capture_brute):
        """Améliore, aligne et fond une capture (niveaux de gris numpy).
        Retourne True si elle a pu être raccordée."""
        traitee = ameliorer_empreinte.ameliorer(capture_brute)
        masque = masque_doigt(traitee)
        if int((masque > 0).sum()) < 2000:
            return False                      # capture quasi vide
        qualite = carte_qualite(capture_brute, traitee.shape)
        h, w = traitee.shape

        if self.numerateur is None:
            # première pose : grande toile, capture au centre
            self.H, self.W = h * 3, w * 3
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

        self._deposer(traitee, masque, M, qualite)
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
        x0 = max(int(np.floor(projetes[:, 0].min())) - 2, 0)
        x1 = min(int(np.ceil(projetes[:, 0].max())) + 2, self.W)
        y0 = max(int(np.floor(projetes[:, 1].min())) - 2, 0)
        y1 = min(int(np.ceil(projetes[:, 1].max())) + 2, self.H)
        return y0, y1, x0, x1

    def _deposer(self, image, masque, M, qualite=None):
        """Fond une pose dans la mosaïque en la COMPLÉTANT :
          - là où la toile est vide, la pose remplit ;
          - là où il y a déjà des crêtes, c'est la plus nette des deux qui
            l'emporte, avec priorité à l'existant à qualité égale.
        Le passage de l'un à l'autre est progressif (carte de distance +
        montée en confiance) pour que la couture reste invisible."""
        if qualite is None:
            qualite = np.ones(image.shape, np.float32)
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

        # 2. pondération par la netteté locale des crêtes ; le plancher garantit
        #    qu'une pose pâle couvre quand même la zone (sinon, trou blanc)
        poids_qualite = poids * (PLANCHER_QUALITE
                                 + (1.0 - PLANCHER_QUALITE) * qualite)

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
        poids_q_t = vers_bloc(poids_qualite.astype(np.float32))
        qualite_t = vers_bloc(qualite.astype(np.float32))

        # 3. arbitrage avec ce qui est déjà posé, pixel par pixel.
        couverture = self.couverture[y0:y1, x0:x1]
        deja = np.maximum(self.denominateur[y0:y1, x0:x1], 1e-6).astype(np.float32)
        qualite_deja = np.clip(self.qualite_num[y0:y1, x0:x1] / deja, 0.0, 1.0)
        # la mosaïque n'est crédible que là où elle a du poids : sur son propre
        # bord en fondu, la confiance remonte doucement -> pas de marche
        qualite_deja *= np.clip(couverture / SEUIL_CONFIANCE, 0.0, 1.0)

        avantage = (qualite_t - qualite_deja) / (qualite_deja + 0.15)
        facteur = PLANCHER_ARBITRAGE + (1.0 - PLANCHER_ARBITRAGE) / (
            1.0 + np.exp(-PENTE_ARBITRAGE * (avantage - BIAIS_ARBITRAGE)))
        poids_q_t = poids_q_t * facteur.astype(np.float32)

        self.numerateur[y0:y1, x0:x1] += image_t.astype(np.float64) * poids_q_t
        self.denominateur[y0:y1, x0:x1] += poids_q_t
        self.couverture[y0:y1, x0:x1] += poids_t
        self.qualite_num[y0:y1, x0:x1] += poids_q_t * qualite_t

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


def fusionner_et_enregistrer(captures):
    """Mode lot : fusionne une liste d'images numpy en commençant par la
    plus couverte. Retourne le chemin du montage, ou None."""
    aires = [int((masque_doigt(ameliorer_empreinte.ameliorer(c)) > 0).sum())
             for c in captures]
    session = SessionFusion()
    for i in np.argsort(aires)[::-1]:
        raccordee = session.ajouter(captures[int(i)])
        print(f"   capture {int(i) + 1} : "
              f"{'raccordée' if raccordee else 'impossible à raccorder, ignorée'}")
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
