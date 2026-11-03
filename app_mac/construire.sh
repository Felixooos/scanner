#!/bin/bash
# construire.sh — compile l'app SwiftUI « Empreinte » en un vrai .app
# double-cliquable, posé dans le dossier empreintescanner (à côté des scripts
# Python qu'il pilote). Relance ce script après chaque modification du code.
#
#   ./construire.sh                      compile seulement
#   ./construire.sh --lancer             compile, ferme l'ancienne instance, puis ouvre
#   ./construire.sh --captures [dossier] compile, puis rend chaque écran en PNG
#                                        (données factices, sans capteur ni moteur)
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
# L'icône (générée par icone.sh depuis logo/logo_mmd_1024.png). Le logo
# affiché DANS l'app est vectoriel (LogoVectoriel.swift) : rien à embarquer.
[ -f "$ICI/Empreinte.icns" ] && cp "$ICI/Empreinte.icns" "$APP/Contents/Resources/Empreinte.icns"

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
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key>           <string>3.0</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>          <string>Empreinte</string>
    <key>NSRequiresAquaSystemAppearance</key> <true/>
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

case "$1" in
    --lancer)
        pkill -x "$NOM" 2>/dev/null || true      # ceinture et bretelles
        sleep 0.3
        open "$APP"
        echo "🚀 Lancée."
        ;;
    --captures)
        DEST="${2:-$ICI/captures}"
        echo "→ Captures d'écran (données factices) dans $DEST…"
        "$APP/Contents/MacOS/$NOM" --captures "$DEST"
        ;;
    *)
        echo "   Double-clique dessus, ou lance :  open \"$APP\""
        ;;
esac
