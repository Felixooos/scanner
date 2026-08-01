#!/bin/bash
# construire.sh — compile l'app SwiftUI « Empreinte » en un vrai .app
# double-cliquable, posé dans le dossier empreintescanner (à côté des scripts
# Python qu'il pilote). Relance ce script après chaque modification du code.
#
#   ./construire.sh            compile seulement
#   ./construire.sh --lancer   compile, ferme l'ancienne instance, puis ouvre
set -e

ICI="$(cd "$(dirname "$0")" && pwd)"
PROJET="$(cd "$ICI/.." && pwd)"          # ~/Desktop/empreintescanner
SRC="$ICI/Empreinte"
APP="$PROJET/Empreinte.app"
NOM="Empreinte"

# On ferme TOUJOURS l'app avant de remplacer le bundle : sinon l'ancienne
# version reste au premier plan et on croit que rien n'a changé.
pkill -x "$NOM" 2>/dev/null || true
sleep 0.3

echo "→ Compilation Swift…"
BIN="$ICI/.build_bin"
mkdir -p "$BIN"
# Binaire UNIVERSEL : l'app doit tourner aussi bien sur un Mac Apple Silicon
# que sur un Mac Intel (on ne choisit pas la machine sur laquelle on installe).
# On compile une fois par architecture, puis on fusionne avec lipo.
ARCHS="arm64 x86_64"
MORCEAUX=""
for arch in $ARCHS; do
    if swiftc -O -parse-as-library \
        -target "$arch-apple-macos13.0" \
        -o "$BIN/$NOM.$arch" \
        "$SRC"/*.swift 2>"$BIN/erreurs.$arch"; then
        MORCEAUX="$MORCEAUX $BIN/$NOM.$arch"
    else
        if [ "$arch" = "arm64" ]; then     # l'architecture native doit passer
            cat "$BIN/erreurs.$arch" >&2
            echo "❌ La compilation a échoué." >&2
            exit 1
        fi
        echo "⚠️  Compilation $arch impossible (SDK absent ?) : l'app ne"
        echo "    tournera QUE sur Apple Silicon. Détails : $BIN/erreurs.$arch"
    fi
done
# shellcheck disable=SC2086
lipo -create $MORCEAUX -output "$BIN/$NOM"
echo "        architectures : $(lipo -archs "$BIN/$NOM")"

echo "→ Assemblage du bundle .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NOM" "$APP/Contents/MacOS/$NOM"
[ -f "$ICI/Empreinte.icns" ] && cp "$ICI/Empreinte.icns" "$APP/Contents/Resources/Empreinte.icns"

# --- le logo d'origine de la maison --------------------------------------
# Emplacement canonique : app_mac/Empreinte/logo_mmd.png. On accepte aussi le
# fichier déposé à la racine du projet, sous n'importe quel nom commençant par
# « logo ». Sans logo, l'app retombe sur le dessin vectoriel (LogoMMD).
LOGO=""
for CAND in "$SRC/logo_mmd.png" "$PROJET/logo_mmd.png"; do
    [ -f "$CAND" ] && { LOGO="$CAND"; break; }
done
if [ -z "$LOGO" ]; then
    LOGO="$(find "$PROJET" "$SRC" -maxdepth 1 -type f \
        \( -iname 'logo*.png' -o -iname 'logo*.jpg' -o -iname 'logo*.jpeg' \) \
        2>/dev/null | sort | head -1)"
fi
if [ -n "$LOGO" ] && [ -f "$LOGO" ]; then
    cp "$LOGO" "$APP/Contents/Resources/logo_mmd.png"
    echo "   logo embarqué : $(basename "$LOGO")"
else
    echo "   ⚠️  pas de logo trouvé (dépose-le en $SRC/logo_mmd.png)"
    echo "      → l'app affiche le logo vectoriel de secours."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$NOM</string>
    <key>CFBundleDisplayName</key>       <string>$NOM</string>
    <key>CFBundleIdentifier</key>        <string>com.felix.empreinte</string>
    <key>CFBundleExecutable</key>        <string>$NOM</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.1</string>
    <key>CFBundleVersion</key>           <string>2.1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>          <string>Empreinte</string>
</dict>
</plist>
PLIST

echo "→ Signature ad-hoc (pour lancer sans blocage Gatekeeper)…"
# Sans ce ménage, codesign refuse le bundle (« resource fork, Finder
# information, or similar detritus not allowed ») : l'icône et les fichiers
# copiés arrivent avec des attributs étendus, et la signature échouait en
# silence (le bundle repartait non scellé).
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ Terminé : $APP"

if [ "$1" = "--lancer" ]; then
    pkill -x "$NOM" 2>/dev/null || true      # ceinture et bretelles
    sleep 0.3
    open "$APP"
    echo "🚀 Lancée."
else
    echo "   Double-clique dessus, ou lance :  open \"$APP\""
fi
