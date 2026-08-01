#!/bin/bash
# =========================================================================
# INSTALLER.command — installation de l'app « Empreinte » sur un Mac.
# Double-cliquable. Copie l'app dans /Applications et installe les
# bibliothèques Python dont le moteur a besoin.
# =========================================================================

ICI="$(cd "$(dirname "$0")" && pwd)"
APP_SOURCE="$ICI/Empreinte.app"
APP_INSTALLEE="/Applications/Empreinte.app"
SUPPORT="$HOME/Library/Application Support/EmpreinteMMD"
VENV="$SUPPORT/venv"
# scikit-image : tracer_svg.calculer_traits en a besoin (squelettisation).
# Sans lui, tous les styles sauf « photo » échouent au moment du rendu.
PAQUETS=(pyserial numpy opencv-python scipy scikit-image fingerprint-enhancer)

titre() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " $1"
    echo "════════════════════════════════════════════════════════════"
}

echo ""
echo "   ╭──────────────────────────────────────────╮"
echo "   │   Installation d'Empreinte               │"
echo "   │   « Maman m'a dit »                      │"
echo "   ╰──────────────────────────────────────────╯"
echo ""
echo "Cette fenêtre va installer l'application et ce dont elle a besoin."
echo "Ça peut prendre quelques minutes : laisse-la travailler."

# --- 1. l'application ----------------------------------------------------
titre "1/3  Installation de l'application"

if [ ! -d "$APP_SOURCE" ]; then
    echo "❌ Empreinte.app est introuvable à côté de cet installateur."
    echo "   Décompresse d'abord tout le dossier (Empreinte.app et"
    echo "   INSTALLER.command doivent être côte à côte), puis recommence."
    echo ""
    read -n 1 -s -r -p "Appuie sur une touche pour fermer."
    exit 1
fi

if [ -d "$APP_INSTALLEE" ]; then
    echo "→ Une ancienne version est présente : elle est remplacée."
    pkill -x Empreinte 2>/dev/null
    sleep 1
    rm -rf "$APP_INSTALLEE"
fi

if ! cp -R "$APP_SOURCE" "$APP_INSTALLEE" 2>/dev/null; then
    echo "⚠️  Impossible d'écrire dans /Applications."
    echo "   L'app est installée dans ton dossier Applications personnel."
    mkdir -p "$HOME/Applications"
    APP_INSTALLEE="$HOME/Applications/Empreinte.app"
    rm -rf "$APP_INSTALLEE"
    cp -R "$APP_SOURCE" "$APP_INSTALLEE"
fi

# Enlève la « quarantaine » posée par macOS sur les fichiers venus d'une clé.
xattr -dr com.apple.quarantine "$APP_INSTALLEE" 2>/dev/null
codesign --force --deep --sign - "$APP_INSTALLEE" >/dev/null 2>&1
echo "✅ Application installée : $APP_INSTALLEE"

# Copie de secours du moteur Python (si l'app est déplacée un jour).
mkdir -p "$SUPPORT/moteur"
if [ -d "$APP_INSTALLEE/Contents/Resources/moteur" ]; then
    cp -f "$APP_INSTALLEE/Contents/Resources/moteur/"*.py "$SUPPORT/moteur/" 2>/dev/null
fi

# --- 2. Python -----------------------------------------------------------
titre "2/3  Recherche de Python"

PYTHON=""
for candidat in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidat" ] && "$candidat" -c "import sys" >/dev/null 2>&1; then
        PYTHON="$candidat"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "❌ Python 3 n'est pas installé sur ce Mac."
    echo ""
    echo "   Ouvre l'app « Terminal » et tape exactement :"
    echo ""
    echo "       xcode-select --install"
    echo ""
    echo "   Une fenêtre d'Apple s'ouvre : clique « Installer », attends la"
    echo "   fin, puis double-clique à nouveau sur INSTALLER.command."
    echo ""
    read -n 1 -s -r -p "Appuie sur une touche pour fermer."
    exit 1
fi
echo "✅ Python trouvé : $PYTHON ($("$PYTHON" -V 2>&1))"

if ! "$PYTHON" -m pip --version >/dev/null 2>&1 && \
   ! "$PYTHON" -m ensurepip --version >/dev/null 2>&1; then
    echo ""
    echo "❌ « pip » (l'installateur de bibliothèques Python) est absent."
    echo ""
    echo "   Ouvre l'app « Terminal » et tape exactement :"
    echo ""
    echo "       xcode-select --install"
    echo ""
    echo "   Puis relance INSTALLER.command."
    echo ""
    read -n 1 -s -r -p "Appuie sur une touche pour fermer."
    exit 1
fi

# --- 3. les bibliothèques ------------------------------------------------
titre "3/3  Installation des bibliothèques (patiente…)"

mkdir -p "$SUPPORT"
PY_FINAL=""

# Méthode propre : un petit Python à part, rien n'est touché sur le système.
echo "→ Préparation d'un environnement Python dédié…"
rm -rf "$VENV"
if "$PYTHON" -m venv "$VENV" >/dev/null 2>&1 && [ -x "$VENV/bin/python3" ]; then
    "$VENV/bin/python3" -m pip install --upgrade pip >/dev/null 2>&1
    if "$VENV/bin/python3" -m pip install "${PAQUETS[@]}"; then
        PY_FINAL="$VENV/bin/python3"
    fi
fi

# Repli : installation « pour cet utilisateur » avec le Python du système.
if [ -z "$PY_FINAL" ]; then
    echo ""
    echo "→ Deuxième méthode : installation pour ton compte…"
    rm -rf "$VENV"
    if "$PYTHON" -m pip install --user "${PAQUETS[@]}"; then
        PY_FINAL="$PYTHON"
    elif "$PYTHON" -m pip install --user --break-system-packages "${PAQUETS[@]}"; then
        PY_FINAL="$PYTHON"
    fi
fi

if [ -z "$PY_FINAL" ]; then
    echo ""
    echo "❌ Les bibliothèques n'ont pas pu être installées."
    echo "   Vérifie que le Mac est bien connecté à Internet, puis relance"
    echo "   INSTALLER.command. Si ça recommence, note le message rouge"
    echo "   ci-dessus et envoie-le à Félix."
    echo ""
    read -n 1 -s -r -p "Appuie sur une touche pour fermer."
    exit 1
fi

# On note quel Python l'app doit utiliser (c'est lui qui a les bibliothèques).
printf '%s\n' "$PY_FINAL" > "$SUPPORT/python.txt"

echo ""
echo "→ Vérification…"
MANQUE=""
for mod in serial numpy cv2 scipy skimage; do
    "$PY_FINAL" -c "import $mod" >/dev/null 2>&1 || MANQUE="$MANQUE $mod"
done
if [ -n "$MANQUE" ]; then
    echo "⚠️  Ces bibliothèques manquent encore :$MANQUE"
    echo "   L'app s'ouvrira mais le scan ne marchera pas."
else
    echo "✅ Tout est en place."
fi

titre "Terminé"
echo ""
echo "  1. Branche le capteur d'empreintes en USB."
echo "  2. Ouvre « Empreinte » depuis le dossier Applications."
echo "  3. La pastille en haut à droite doit afficher « Capteur prêt »."
echo ""
echo "  Les commandes sont rangées dans :  ~/Documents/Empreintes MMD"
echo ""
read -n 1 -s -r -p "Appuie sur une touche pour fermer cette fenêtre."
echo ""
