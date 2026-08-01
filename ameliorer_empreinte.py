#!/usr/bin/env python3
"""
ameliorer_empreinte.py — améliore les captures du JM-101.

Pour chaque empreinte_*.png du dossier (ou les fichiers passés en argument),
produit :
  *_amelioree.png    version niveaux de gris nettoyée et contrastée
  *_cretes.png       crêtes reconstruites par filtres de Gabor orientés
                     (noir et blanc, idéal pour l'analyse)
  comparaison_*.png  montage avant/après

Techniques appliquées, dans l'ordre :
  1. étirement de contraste (percentiles 2-98) — compense les 16 niveaux
     de gris du capteur
  2. agrandissement 2x (interpolation cubique)
  3. CLAHE : égalisation d'histogramme adaptative locale
  4. fermeture morphologique : reconnecte les crêtes en pointillés
     (doigt sec / pression légère)
  5. filtre médian : enlève le bruit poivre et sel
  6. filtres de Gabor orientés (méthode Hong-Wan-Jain) : suit la direction
     locale des crêtes et les reconstruit en traits continus

Utilisation :
    python3 ameliorer_empreinte.py                 # toutes les captures
    python3 ameliorer_empreinte.py empreinte_X.png # une seule
"""

import glob
import os
import sys

import cv2
import numpy as np


def score_qualite(gris):
    """Retourne (couverture %, netteté) + conseils de reprise éventuels."""
    etire = cv2.normalize(gris, None, 0, 255, cv2.NORM_MINMAX)
    couverture = float((etire < 100).mean()) * 100.0
    nettete = float(cv2.Laplacian(etire, cv2.CV_64F).var())
    conseils = []
    if couverture < 15:
        conseils.append("peu de surface de doigt : pose le doigt bien à plat, appuie plus fort")
    if nettete < 200:
        conseils.append("crêtes peu marquées : doigt trop sec ? souffle dessus et recommence")
    return couverture, nettete, conseils


def ameliorer(gris):
    """Pipeline niveaux de gris : contraste, 2x, CLAHE, fermeture, médian."""
    # 1. étirement de contraste robuste (percentiles 2-98)
    bas, haut = np.percentile(gris, (2, 98))
    if haut <= bas:
        bas, haut = gris.min(), max(gris.max(), gris.min() + 1)
    etire = np.clip((gris.astype(np.float32) - bas) * 255.0 / (haut - bas), 0, 255).astype(np.uint8)

    # 2. agrandissement 2x avant filtrage (les détails survivent mieux)
    grand = cv2.resize(etire, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)

    # 3. égalisation adaptative locale
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    egalise = clahe.apply(grand)

    # 4. fermeture morphologique sur l'image inversée : les crêtes (sombres)
    #    en pointillés se ressoudent
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    inverse = 255 - egalise
    ferme = cv2.morphologyEx(inverse, cv2.MORPH_CLOSE, noyau)
    resultat = 255 - ferme

    # 5. filtre médian doux contre le bruit
    return cv2.medianBlur(resultat, 3)


def cretes_gabor(gris_ameliore):
    """Reconstruction des crêtes par filtres de Gabor orientés. None si échec."""
    try:
        import fingerprint_enhancer
        fonction = getattr(fingerprint_enhancer, "enhance_fingerprint", None) \
            or getattr(fingerprint_enhancer, "enhance_Fingerprint")
        sortie = fonction(gris_ameliore)
        sortie = np.asarray(sortie)
        if sortie.dtype == bool:
            sortie = sortie.astype(np.uint8) * 255
        elif sortie.max() <= 1:
            sortie = (sortie * 255).astype(np.uint8)
        else:
            sortie = sortie.astype(np.uint8)
        # crêtes en noir sur fond blanc
        if (sortie > 127).mean() < 0.5:
            sortie = 255 - sortie
        return sortie
    except Exception as e:                      # le Gabor peut échouer sur une image vide
        print(f"   (filtres de Gabor impossibles ici : {e})")
        return None


def montage(images, etiquettes):
    """Montage horizontal avec étiquettes, toutes images à la même hauteur."""
    hauteur = max(im.shape[0] for im in images)
    bande = 28
    colonnes = []
    for im, txt in zip(images, etiquettes):
        if im.shape[0] != hauteur:
            echelle = hauteur / im.shape[0]
            im = cv2.resize(im, (int(im.shape[1] * echelle), hauteur),
                            interpolation=cv2.INTER_NEAREST)
        colonne = np.full((hauteur + bande, im.shape[1]), 255, np.uint8)
        colonne[bande:, :] = im
        cv2.putText(colonne, txt, (6, 20), cv2.FONT_HERSHEY_SIMPLEX,
                    0.55, 0, 1, cv2.LINE_AA)
        colonnes.append(colonne)
        colonnes.append(np.full((hauteur + bande, 4), 128, np.uint8))
    return np.hstack(colonnes[:-1])


def traiter(chemin):
    nom = os.path.splitext(os.path.basename(chemin))[0]
    dossier = os.path.dirname(chemin)          # les sorties vont à côté de l'entrée
    gris = cv2.imread(chemin, cv2.IMREAD_GRAYSCALE)
    if gris is None:
        print(f"!! Impossible de lire {chemin}")
        return

    couverture, nettete, conseils = score_qualite(gris)
    print(f"\n=== {nom} ===")
    print(f"   couverture du doigt : {couverture:.0f} %   netteté : {nettete:.0f}")
    for c in conseils:
        print(f"   conseil : {c}")

    amelioree = ameliorer(gris)
    chemin_amelioree = os.path.join(dossier, f"{nom}_amelioree.png")
    cv2.imwrite(chemin_amelioree, amelioree)
    print(f"   -> {chemin_amelioree}")

    images = [gris, amelioree]
    etiquettes = ["originale", "amelioree"]

    try:
        import completer_empreinte
        cretes = completer_empreinte.completer(amelioree)
        etiquette_cretes = "cretes (completees)"
    except Exception as erreur:
        print(f"   (complétion impossible : {erreur}), Gabor simple")
        cretes = cretes_gabor(amelioree)
        etiquette_cretes = "cretes (Gabor)"
    if cretes is not None:
        chemin_cretes = os.path.join(dossier, f"{nom}_cretes.png")
        cv2.imwrite(chemin_cretes, cretes)
        print(f"   -> {chemin_cretes}")
        images.append(cretes)
        etiquettes.append(etiquette_cretes)
        try:
            import tracer_svg
            chemin_svg = os.path.join(dossier, f"{nom}_traits.svg")
            nb = tracer_svg.tracer_svg(cretes, chemin_svg)
            print(f"   -> {chemin_svg} ({nb} traits)")
        except Exception as erreur:
            print(f"   (SVG non généré : {erreur})")

    chemin_comparaison = os.path.join(dossier, f"comparaison_{nom}.png")
    cv2.imwrite(chemin_comparaison, montage(images, etiquettes))
    print(f"   -> {chemin_comparaison}")
    return chemin_comparaison


def principal():
    if len(sys.argv) > 1:
        fichiers = sys.argv[1:]
    else:
        fichiers = sorted(f for f in glob.glob("empreinte_*.png")
                          if "_amelioree" not in f and "_cretes" not in f)
    if not fichiers:
        sys.exit("Aucune capture empreinte_*.png dans ce dossier.")
    for f in fichiers:
        traiter(f)
    print("\nTermine !")


if __name__ == "__main__":
    principal()
