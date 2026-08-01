#!/bin/bash
# =========================================================================
# distribuer.sh — fabrique la clé USB d'installation.
#
#   1. compile l'app (app_mac/construire.sh) ;
#   2. glisse le moteur Python DANS l'app (Contents/Resources/moteur) ;
#   3. produit Empreinte_MMD.zip = Empreinte.app + INSTALLER.command + LISEZMOI.
#
# Il suffit ensuite de copier Empreinte_MMD.zip sur une clé USB, de le
# décompresser sur l'autre Mac et de double-cliquer sur INSTALLER.command.
# =========================================================================
set -e

ICI="$(cd "$(dirname "$0")" && pwd)"
APP="$ICI/Empreinte.app"
ATELIER="$ICI/.distribution"
LIVRAISON="$ATELIER/Empreinte MMD"
ZIP="$ICI/Empreinte_MMD.zip"

# Les fichiers Python dont l'app a besoin pour tourner (obligatoires).
MODULES=(moteur_live.py capture_empreinte.py fusionner_empreinte.py
         completer_empreinte.py tracer_svg.py formes.py ameliorer_empreinte.py
         magasin_commandes.py)

echo "════════════════════════════════════════════════════════════"
echo " Fabrication du paquet « Maman m'a dit »"
echo "════════════════════════════════════════════════════════════"

# --- 1. l'app ------------------------------------------------------------
echo ""
echo "→ 1/4  Compilation de l'app…"
bash "$ICI/app_mac/construire.sh" >/dev/null
[ -d "$APP" ] || { echo "❌ Empreinte.app n'a pas été produite."; exit 1; }

# --- 2. le dossier à livrer ---------------------------------------------
# On travaille sur une COPIE : l'app du dossier de développement continue
# de lire les .py du projet (pratique pour tester les modifs du moteur).
echo "→ 2/4  Préparation du dossier à livrer…"
rm -rf "$ATELIER"
mkdir -p "$LIVRAISON"
ditto "$APP" "$LIVRAISON/Empreinte.app"

# --- 3. le moteur Python embarqué dans la copie -------------------------
echo "→ 3/4  Copie du moteur Python dans l'app…"
MOTEUR="$LIVRAISON/Empreinte.app/Contents/Resources/moteur"
rm -rf "$MOTEUR"        # jamais de résidu d'un ancien essai dans le paquet
mkdir -p "$MOTEUR"
for m in "${MODULES[@]}"; do
    if [ ! -f "$ICI/$m" ]; then
        echo "❌ Fichier manquant : $m"
        exit 1
    fi
    cp "$ICI/$m" "$MOTEUR/"
done
# Filet de sécurité : si le moteur gagne un module, il part quand même
# (on laisse de côté les scripts de test).
for f in "$ICI"/*.py; do
    base="$(basename "$f")"
    case "$base" in test_*) continue;; esac
    [ -f "$MOTEUR/$base" ] || cp "$f" "$MOTEUR/"
done
echo "        $(ls "$MOTEUR"/*.py | wc -l | tr -d ' ') fichiers Python embarqués."

# On resigne : le contenu du bundle a changé. Le ménage des attributs
# étendus est indispensable, sinon codesign refuse (« detritus not allowed »)
# et le moteur embarqué repart non scellé.
xattr -cr "$LIVRAISON/Empreinte.app" 2>/dev/null || true
codesign --force --deep --sign - "$LIVRAISON/Empreinte.app" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$LIVRAISON/Empreinte.app" 2>/dev/null \
    || echo "⚠️  signature ad-hoc incomplète (l'app tournera quand même)"

if [ ! -f "$ICI/INSTALLER.command" ]; then
    echo "❌ INSTALLER.command est introuvable à la racine du projet."
    exit 1
fi
cp "$ICI/INSTALLER.command" "$LIVRAISON/INSTALLER.command"
chmod +x "$LIVRAISON/INSTALLER.command"

cat > "$LIVRAISON/LISEZMOI.txt" <<'TXT'
EMPREINTE — « Maman m'a dit »
=============================

Installation sur un Mac (5 minutes) :

1. Copie ce dossier sur le bureau du Mac.
2. Double-clique sur INSTALLER.command.
   Si macOS refuse de l'ouvrir : clic DROIT dessus > Ouvrir > Ouvrir.
3. Laisse la fenêtre noire travailler (elle installe Python et les
   bibliothèques : ça peut prendre quelques minutes) puis ferme-la.
4. L'app « Empreinte » est maintenant dans le dossier Applications.

Utilisation :

- Branche le capteur d'empreintes en USB AVANT d'ouvrir l'app.
- Ouvre Empreinte : la pastille en haut à droite doit dire « Capteur prêt ».
- « Nouvelle commande » > ajoute une empreinte par personne > pose le doigt
  sur le capteur (le scan démarre tout seul, recommence en décalant un peu
  le doigt) > « Terminer » > ajuste le cadre > « Valider l'empreinte ».
- Choisis ensuite une forme (cœur, trèfle…) et un style pour voir le rendu,
  puis « Enregistrer le rendu » et « Exporter » pour tout envoyer.

Les commandes sont rangées dans ~/Documents/Empreintes MMD
(modifiable dans l'app : roue dentée en haut à droite).

En cas de souci : rouvre INSTALLER.command, il réinstalle tout proprement.
TXT

# --- 4. le zip -----------------------------------------------------------
echo "→ 4/4  Compression…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$LIVRAISON" "$ZIP"
rm -rf "$ATELIER"

TAILLE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
echo ""
echo "✅ Paquet prêt : $ZIP  ($TAILLE)"
echo "   Copie-le sur la clé USB, décompresse-le sur l'autre Mac,"
echo "   puis double-clique sur INSTALLER.command."
