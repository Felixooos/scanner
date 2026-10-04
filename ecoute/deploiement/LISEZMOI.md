# Déployer le relais sur le VPS (ineko)

Le relais est le point de rendez-vous : le Mac et le téléphone s'y connectent
tous les deux *vers* lui. Il tourne en Docker, derrière Caddy qui gère le
HTTPS tout seul.

## 1. Un sous-domaine qui pointe vers le VPS

Crée un enregistrement DNS **A** (ex. `ecoute.ton-domaine.fr`) vers l'IP du
VPS. Sans ça, Caddy ne peut pas obtenir de certificat HTTPS.

## 2. Vérifier que les ports 80 et 443 sont libres

Si ineko a **déjà** un serveur web / reverse-proxy sur 443, les deux Caddy se
marcheraient dessus. Deux cas :

- **443 libre** → tu peux utiliser ce dossier tel quel (option A ci-dessous).
- **443 déjà pris par ineko** → n'utilise PAS le Caddy d'ici : lance seulement
  le conteneur `relais` sur `127.0.0.1:8787` et ajoute une route dans ton
  proxy existant (option B).

## Option A — autonome (443 libre)

Copie le dossier `ecoute/` sur le VPS, puis :

```bash
cd ecoute/deploiement
./installer_vps.sh ecoute.ton-domaine.fr      # crée .env (note le JETON affiché)
```

C'est tout : https://ecoute.ton-domaine.fr affiche la page.

## Option B — derrière le proxy existant d'ineko

Dans `docker-compose.yml`, supprime le service `caddy` et, sur `relais`,
remplace `expose` par `ports: ["127.0.0.1:8787:8787"]`. Crée `.env` à la main
(domaine, mot de passe, jeton). Puis `docker compose up -d --build`, et ajoute
à ton proxy une route `ecoute.ton-domaine.fr → 127.0.0.1:8787` **en laissant
passer les WebSockets** (nginx : `proxy_set_header Upgrade $http_upgrade;` +
`Connection "upgrade"`).

## 3. Côté Mac (une fois le relais en ligne)

```bash
cd ecoute/mac
./installer_pont.sh wss://ecoute.ton-domaine.fr/source  LE_JETON
```

Le pont se lance au démarrage, se relance seul, et empêche le Mac de dormir.

## Changer un secret plus tard

Édite `.env` sur le VPS → `docker compose up -d` (rebuild inutile). Pense à
re-lancer l'installeur du Mac si tu changes le jeton.
