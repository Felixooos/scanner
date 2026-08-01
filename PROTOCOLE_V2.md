# Protocole V2 — moteur_live.py ↔ app Swift « Empreinte »

Contrat entre le moteur Python et l'app SwiftUI. Le moteur implémente
EXACTEMENT ceci ; l'app consomme EXACTEMENT ceci. Toutes les commandes
existantes (PORTS, CONNECT, SCAN, RESET, EMPREINTE, VALIDER, SUPPRIMER,
RECADRER, APERCU, ENREGISTRER, LED, QUIT) restent valables.

## Configuration persistante

Fichier `~/.empreinte_mmd.json` :
```json
{"dossier_commandes": "/Users/xxx/Documents/Empreintes MMD"}
```
Défaut si absent : `~/Documents/Empreintes MMD` (créé au démarrage).
L'ancien dossier `commandes/` du projet n'est plus utilisé pour le neuf.

## Arborescence d'une commande sur disque

```
<dossier_commandes>/<id>/            id = AAAAMMJJ_HHMMSS_<slug-nom>
    commande.json
    vignette.png                     aperçu du dernier rendu (fond blanc)
    empreintes/01_<slug-prenom>/
        mosaique.png                 mosaïque brute niveaux de gris (source de vérité)
        photo.png                    photo normalisée recadrée (pour affichage)
    rendus/<forme>_<style>.svg       rendus enregistrés
    rendus/<forme>_<style>.png
```

`commande.json` :
```json
{
  "id": "20260801_143000_dupont",
  "nom": "Dupont",
  "cree_le": "2026-08-01T14:30:00",
  "modifie_le": "2026-08-01T15:02:11",
  "forme": "coeur",
  "style": "traits",
  "empreintes": [
    {"nom": "Louis",
     "dossier": "empreintes/01_louis",
     "crop": [0.5, 0.5, 0.5, 0.5],
     "completer": true,
     "ajust": {"dx": 0.0, "dy": 0.0, "angle": 0.0}}
  ]
}
```
`ajust` : décalage du placement de l'empreinte DANS son lobe de la forme
composée — dx, dy en fraction du rayon de lobe (−1..1), angle en degrés
(rotation de l'empreinte sur elle-même, en plus de la rotation de forme).

## Commandes nouvelles / modifiées

| Commande | Effet | Événement(s) |
|---|---|---|
| `DOSSIER` | renvoie le dossier de stockage actuel | `dossier {chemin}` |
| `DOSSIER <chemin>` | change + persiste le dossier, recharge la liste | `dossier {chemin}` puis `commandes {…}` |
| `COMMANDES` | liste les commandes sauvées (tri : modifiées récentes d'abord) | `commandes {liste:[{id, nom, date, nb, forme, style, vignette}]}` (`vignette` = chemin absolu ou null, `date` = modifie_le ISO) |
| `COMMANDE <nom>` | crée une NOUVELLE commande, dossier créé immédiatement | `commande {id, nom, empreintes:[]}` |
| `OUVRIR <id>` | charge une commande existante en mémoire (mosaïques relues des PNG) | `commande {id, nom, forme, style, empreintes:[{nom, crop, completer, ajust, photo}]}` (`photo` = chemin absolu de photo.png) |
| `RENOMMER <nom>` | renomme la commande courante (json seulement, dossier inchangé) | `commande {…}` rafraîchi |
| `RENOMMER_EMPREINTE <i> <nom>` | renomme l'empreinte i | `commande {…}` rafraîchi |
| `SUPPRIMER_COMMANDE <id>` | déplace le dossier vers `<dossier_commandes>/.corbeille/` | `commandes {…}` rafraîchi |
| `AJUSTER <i> <dx> <dy> <angle>` | règle `ajust` de l'empreinte i, vide le cache d'aperçus, persiste | `ajuste {index, ajust}` |
| `EMPREINTE_APERCU <i>` | écrit la photo normalisée de l'empreinte i (avec son crop appliqué) dans un PNG temporaire | `empreinte_apercu {index, png, horodatage}` |
| `EXPORTER` | zippe le dossier de la commande courante → `<dossier_commandes>/<id>.zip` + texte récapitulatif | `exporte {dossier, zip, resume}` (`resume` = texte lisible : nom, date, prénoms, forme, style) |

## Comportements modifiés

- `VALIDER …` : en plus du comportement actuel, écrit mosaique.png,
  photo.png et commande.json sur disque. Événement `empreinte_validee`
  enrichi : `{noms, total, photos:[chemins photo.png],
  empreintes:[{nom, crop, completer, ajust, photo}]}` — `empreintes` est
  l'état complet, à relire tel quel (après `SUPPRIMER <i>` les index
  glissent : reprendre les réglages position par position les décalerait).
- `SUPPRIMER <i>` : met aussi le disque à jour (renumérote les dossiers
  d'empreintes ou garde les numéros, au choix, mais commande.json fait foi).
- `APERCU <forme> <style>` : inchangé côté appel ; applique les `ajust`,
  persiste forme/style dans commande.json, régénère `vignette.png`.
- `ENREGISTRER <forme> <style>` : écrit dans `<id>/rendus/` (plus dans
  l'ancien dossier), met à jour la vignette. Événement `compose
  {svg, png, dossier}` (`dossier` = dossier de la commande).
- Cache d'aperçus vidé à chaque changement de crop / ajust / suppression /
  renommage n'est pas nécessaire pour renommage (ne change pas l'image).

## Notes

- Tous les chemins renvoyés sont ABSOLUS.
- `formes.composer(...)` gagne un paramètre `ajusts=None`
  (liste de dicts {dx, dy, angle} ou None) — rétrocompatible.
- Le moteur ne doit JAMAIS écrire de non-JSON sur stdout.
