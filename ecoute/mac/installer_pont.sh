#!/bin/bash
# installer_pont.sh — fait tourner le pont en permanence sur CE Mac.
#
# Le pont se relance tout seul au démarrage et après un plantage, et empêche
# le Mac de s'endormir (sinon l'USB et le WiFi se coupent). À lancer une fois :
#
#     ./installer_pont.sh wss://ecoute.mon-domaine.fr/source  LE_JETON_SOURCE
#
# Le jeton doit être le MÊME que ECOUTE_JETON_SOURCE côté VPS.
set -e

URL="$1"
JETON="$2"
if [ -z "$URL" ] || [ -z "$JETON" ]; then
    echo "Usage : ./installer_pont.sh wss://<domaine>/source <jeton>"
    exit 1
fi

ICI="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$ICI/.." && pwd)/pont_mac.py"
[ -f "$SRC" ] || { echo "pont_mac.py introuvable à côté ($SRC)"; exit 1; }

# macOS interdit à un service (LaunchAgent) de lire le Bureau, Documents, etc.
# On copie donc le pont dans un dossier non protégé, d'où il tournera.
SUPPORT="$HOME/Library/Application Support/EcouteMMD"
mkdir -p "$SUPPORT"
cp "$SRC" "$SUPPORT/pont_mac.py"
PONT="$SUPPORT/pont_mac.py"

# python SYSTÈME (pas celui de Xcode, qui n'a pas aiohttp/pyserial).
PY="/usr/bin/python3"
LABEL="com.felix.ecoute.pont"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ecoute-pont.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# caffeinate -s : tant que le pont tourne, le Mac ne s'endort pas (sur secteur).
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
        <string>$PY</string>
        <string>$PONT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ECOUTE_RELAIS_URL</key><string>$URL</string>
        <key>ECOUTE_JETON_SOURCE</key><string>$JETON</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "✅ Pont installé et lancé."
echo "   Journal : $LOG"
echo "   Pour l'arrêter  : launchctl unload \"$PLIST\""
echo "   Pour le relancer: launchctl load   \"$PLIST\""
