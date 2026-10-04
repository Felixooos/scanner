#!/bin/bash
# installer_vps.sh — à lancer SUR le VPS (dans ce dossier deploiement/).
# Crée .env si besoin, puis démarre le relais + Caddy (HTTPS automatique).
#
#     ./installer_vps.sh ecoute.mon-domaine.fr
#
# Pré-requis : Docker + le plugin compose, et un enregistrement DNS A qui fait
# pointer le domaine vers l'IP du VPS (sinon Caddy ne peut pas obtenir le
# certificat). Les ports 80 et 443 doivent être libres sur le VPS.
set -e
cd "$(dirname "$0")"

DOMAINE="$1"
if [ ! -f .env ]; then
    [ -n "$DOMAINE" ] || { echo "Usage (1re fois) : ./installer_vps.sh <domaine>"; exit 1; }
    JETON="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))' 2>/dev/null \
             || openssl rand -base64 24 | tr -d '/+=')"
    read -r -p "Choisis le mot de passe d'écoute : " MDP
    cat > .env <<EOF
ECOUTE_DOMAINE=$DOMAINE
ECOUTE_MOT_DE_PASSE=$MDP
ECOUTE_JETON_SOURCE=$JETON
EOF
    chmod 600 .env
    echo "✅ .env créé. JETON pour l'installeur du Mac :"
    echo "   $JETON"
fi

docker compose up -d --build
echo ""
echo "✅ Relais en ligne. Teste dans un navigateur : https://$(grep ECOUTE_DOMAINE .env | cut -d= -f2)"
echo "   (le certificat HTTPS peut prendre ~30 s à la première ouverture)"
echo "   Logs : docker compose logs -f"
