# Écoute à distance de la pièce

Écouter le micro du boîtier depuis n'importe où, sans ouvrir de port sur la
box. Le Mac (toujours allumé, dans la pièce) et le téléphone se connectent
tous les deux *vers* le VPS, qui fait le pont.

```
micro I2S → ESP32 → USB → [Mac] pont_mac.py → (WiFi, sortant)
                                                      ↓
                                          [VPS ineko] relais.py
                                                      ↑
                               (internet) ← navigateur du téléphone
```

Le micro ne s'allume **que** pendant une écoute : sans auditeur, le relais dit
« STOP » et le boîtier ne diffuse rien.

## Pièces

| Fichier | Où ça tourne | Rôle |
|---|---|---|
| `relais.py` | VPS | point de rendez-vous : recopie le son source → auditeurs |
| `page.html` | servie par le relais | la page avec le bouton « Écouter » |
| `pont_mac.py` | Mac de la pièce | demande le son à l'ESP32 et le pousse au relais |

## Secrets (variables d'environnement, à choisir)

- `ECOUTE_MOT_DE_PASSE` : demandé au téléphone sur la page.
- `ECOUTE_JETON_SOURCE` : prouve au relais que c'est bien le Mac qui émet.
  (le même des deux côtés)

## Lancer le relais (sur le VPS)

```bash
ECOUTE_MOT_DE_PASSE="..." ECOUTE_JETON_SOURCE="..." python3 relais.py
```
Il écoute sur le port 8787. **À mettre derrière un proxy HTTPS** (voir plus
bas) : sans HTTPS, les navigateurs refusent le son et le mot de passe
passerait en clair.

## Lancer le pont (sur le Mac)

```bash
ECOUTE_RELAIS_URL="wss://<vps>/source" ECOUTE_JETON_SOURCE="..." \
  python3 pont_mac.py          # micro réel
python3 pont_mac.py --faux     # son de test (sinus), pour vérifier le réseau
```

## À finir

- [ ] Firmware ESP32 : commandes `ECOUTE` / `STOP` (flux PCM 16 kHz 16 bits,
      trames `A5 5A` + taille + échantillons). `pont_mac.py` sait déjà les lire.
- [ ] Déploiement VPS : route HTTPS vers le port 8787, service qui redémarre
      tout seul, pont lancé au démarrage du Mac (launchd).
