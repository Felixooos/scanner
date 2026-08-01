#!/bin/bash
# =========================================================================
# publier.sh — publie une nouvelle version de l'app « Empreinte ».
#
#     ./publier.sh 2.1 "Le cadrage garde maintenant les proportions."
#
# En une commande :
#   1. vérifie que le dossier git est propre et que la version monte ;
#   2. inscrit la version dans app_mac/construire.sh (le binaire la porte) ;
#   3. reconstruit le paquet complet (distribuer.sh → Empreinte_MMD.zip) ;
#   4. copie le zip dans dist/ (c'est LUI que l'app ira télécharger) ;
#   5. écrit version.json (version, date, notes, paquets Python) ;
#   6. commite et pousse sur GitHub.
#
# Ensuite, sur le Mac de maman : roue dentée > « Rechercher une mise à
# jour » > « Installer ». Ses commandes ne sont jamais touchées.
# =========================================================================
set -e

ICI="$(cd "$(dirname "$0")" && pwd)"
cd "$ICI"

CONSTRUIRE="$ICI/app_mac/construire.sh"
INSTALLEUR="$ICI/INSTALLER.command"
MANIFESTE="$ICI/version.json"
DIST="$ICI/dist"
ZIP="$ICI/Empreinte_MMD.zip"
DEPOT_BRUT="https://raw.githubusercontent.com/Felixooos/scanner/main/dist/Empreinte_MMD.zip"

rouge()  { printf '\033[31m%s\033[0m\n' "$*"; }
vert()   { printf '\033[32m%s\033[0m\n' "$*"; }
titre()  { echo ""; echo "════════════════════════════════════════════════════════════";
           echo " $1"; echo "════════════════════════════════════════════════════════════"; }
echouer() { echo ""; rouge "❌ $*"; exit 1; }

# --- 0. les arguments ----------------------------------------------------
VERSION="$1"
NOTES="$2"

if [ -z "$VERSION" ] || [ -z "$NOTES" ]; then
    echo "Usage :  ./publier.sh <version> \"<ce qui change>\""
    echo ""
    echo "Exemple : ./publier.sh 2.1 \"Le cadrage garde les proportions.\""
    echo ""
    echo "Les notes sont lues telles quelles par maman dans l'app :"
    echo "écris-les en français, sans jargon."
    exit 1
fi

case "$VERSION" in
    *[!0-9.]*|.*|*.|"") echouer "Version invalide : « $VERSION ». Attendu : 2.1 ou 2.1.3." ;;
esac

# Compare deux versions composant par composant (2.10 > 2.9).
# Renvoie 0 si $1 > $2.
version_superieure() {
    local a="$1" b="$2" i n
    local IFS=.
    # shellcheck disable=SC2206
    local A=($a)
    # shellcheck disable=SC2206
    local B=($b)
    unset IFS
    n=${#A[@]}
    [ ${#B[@]} -gt "$n" ] && n=${#B[@]}
    for ((i = 0; i < n; i++)); do
        local x="${A[i]:-0}" y="${B[i]:-0}"
        x=$((10#${x:-0})); y=$((10#${y:-0}))
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1        # égales
}

# --- 1. l'état du dossier ------------------------------------------------
titre "1/6  Vérifications"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || echouer "Ce dossier n'est pas un dépôt git."

if [ -n "$(git status --porcelain)" ]; then
    echo ""
    git status --short
    echo ""
    echouer "Le dossier n'est pas propre : commite (ou annule) tes modifications
   avant de publier, sinon on ne sait plus ce qui part chez maman.

     git add -A && git commit -m \"ce que tu as changé\""
fi

[ -f "$CONSTRUIRE" ]  || echouer "app_mac/construire.sh est introuvable."
[ -f "$ICI/distribuer.sh" ] || echouer "distribuer.sh est introuvable."

ACTUELLE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$MANIFESTE" 2>/dev/null | head -1)"
[ -z "$ACTUELLE" ] && ACTUELLE="0"
echo "→ Version publiée aujourd'hui : $ACTUELLE"
echo "→ Nouvelle version demandée   : $VERSION"

if ! version_superieure "$VERSION" "$ACTUELLE"; then
    echouer "La version doit être SUPÉRIEURE à $ACTUELLE (l'app compare les
   numéros : elle ignorerait une version inférieure ou égale)."
fi
vert "✅ Dossier propre, version en hausse."

# --- 2. la version dans le binaire --------------------------------------
titre "2/6  Inscription de la version dans l'app"

# CFBundleVersion doit monter aussi : macOS s'en sert pour départager deux
# bundles de même nom (et l'app la relit après l'échange).
sed -i '' \
    -e "s|\(<key>CFBundleShortVersionString</key><string>\)[^<]*\(</string>\)|\1$VERSION\2|" \
    -e "s|\(<key>CFBundleVersion</key>           <string>\)[^<]*\(</string>\)|\1$VERSION\2|" \
    "$CONSTRUIRE"

VERIF="$(grep -c "<string>$VERSION</string>" "$CONSTRUIRE" || true)"
[ "$VERIF" -ge 2 ] || echouer "La version n'a pas pu être inscrite dans construire.sh.
   Vérifie les lignes CFBundleShortVersionString / CFBundleVersion."
vert "✅ construire.sh : version $VERSION"

# --- 3. construction du paquet ------------------------------------------
titre "3/6  Construction du paquet (compilation + moteur Python)"
bash "$ICI/distribuer.sh"
[ -f "$ZIP" ] || echouer "Empreinte_MMD.zip n'a pas été produit."

# Ceinture et bretelles : le binaire livré doit porter la bonne version.
POSEE="$(defaults read "$ICI/Empreinte.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
[ "$POSEE" = "$VERSION" ] \
    || echouer "L'app construite annonce la version « $POSEE » au lieu de « $VERSION »."
ARCHS="$(lipo -archs "$ICI/Empreinte.app/Contents/MacOS/Empreinte" 2>/dev/null || echo "?")"
echo "   architectures du binaire : $ARCHS"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "   ⚠️  binaire NON universel : il ne tournera que sur $ARCHS." ;;
esac

# --- 4. le zip dans dist/ ------------------------------------------------
titre "4/6  Dépôt du paquet dans dist/"
mkdir -p "$DIST"
cp -f "$ZIP" "$DIST/Empreinte_MMD.zip"
TAILLE="$(du -h "$DIST/Empreinte_MMD.zip" | cut -f1 | tr -d ' ')"
vert "✅ dist/Empreinte_MMD.zip ($TAILLE)"

# --- 5. version.json -----------------------------------------------------
titre "5/6  Écriture de version.json"

# La liste des paquets Python est celle de l'installateur : une seule
# source de vérité (on s'est déjà fait piéger par scikit-image manquant).
PAQUETS_JSON="$(sed -n 's/^PAQUETS=(\(.*\))/\1/p' "$INSTALLEUR" | head -1 \
    | tr ' ' '\n' | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd, - )"
[ -z "$PAQUETS_JSON" ] && PAQUETS_JSON='"pyserial","numpy","opencv-python","scipy","scikit-image","fingerprint-enhancer"'

# Les notes partent dans du JSON : on échappe \ et " et on met les retours
# à la ligne au format JSON.
NOTES_JSON="$(printf '%s' "$NOTES" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}')"

cat > "$MANIFESTE" <<JSON
{
  "version": "$VERSION",
  "date": "$(date +%Y-%m-%d)",
  "notes": "$NOTES_JSON",
  "zip": "$DEPOT_BRUT",
  "paquets_python": [$PAQUETS_JSON]
}
JSON

# Relecture : un version.json cassé rendrait la mise à jour invisible.
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFESTE" \
        || echouer "version.json est mal formé (notes trop exotiques ?)."
fi
cat "$MANIFESTE"

# --- 6. commit + push ----------------------------------------------------
titre "6/6  Envoi sur GitHub"

git add -- "$MANIFESTE" "$DIST/Empreinte_MMD.zip" "$CONSTRUIRE"
if [ -z "$(git diff --cached --name-only)" ]; then
    echouer "Rien à commiter : le paquet est-il identique au précédent ?"
fi
echo "→ Fichiers du commit :"
git diff --cached --name-only | sed 's/^/     /'
git commit -q -m "Version $VERSION — $NOTES"
vert "✅ Commit créé."

# GIT_TERMINAL_PROMPT=0 : si l'authentification n'est pas configurée, git
# ÉCHOUE au lieu de rester bloqué à demander un identifiant. Ce script ne
# demande, ne lit et ne stocke jamais de mot de passe ni de jeton.
BRANCHE="$(git rev-parse --abbrev-ref HEAD)"
if GIT_TERMINAL_PROMPT=0 git push origin "$BRANCHE"; then
    ENVOYE=1
else
    ENVOYE=0
fi

titre "Récapitulatif"
echo ""
echo "   Version      : $VERSION   ($(date +%d/%m/%Y))"
echo "   Notes        : $NOTES"
echo "   Paquet       : dist/Empreinte_MMD.zip ($TAILLE)"
echo "   Architectures: $ARCHS"
echo "   Branche      : $BRANCHE"
echo ""
if [ "$ENVOYE" = "1" ]; then
    vert "✅ Publié. Sur le Mac de maman : roue dentée > « Rechercher une"
    vert "   mise à jour » > « Installer ». Ses commandes ne bougent pas."
else
    rouge "⚠️  Le commit est fait, mais l'ENVOI a échoué."
    echo ""
    echo "   L'authentification GitHub n'est pas encore configurée sur ce Mac."
    echo "   Tant que le push n'est pas passé, maman ne verra RIEN de nouveau."
    echo ""
    echo "   Configure-la une fois pour toutes (au choix) :"
    echo "     • GitHub Desktop, puis  git push"
    echo "     • une clé SSH :  git remote set-url origin git@github.com:Felixooos/scanner.git"
    echo ""
    echo "   Puis relance simplement :  git push"
    exit 1
fi
