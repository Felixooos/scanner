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
        poses/pose_01.png …          captures brutes acceptées pendant le scan
                                     (PNG sans perte, ordre d'acceptation) — pour
                                     re-fusionner plus tard ; OPTIONNEL (absent
                                     des empreintes plus anciennes)
    rendus/<forme>_<style>.svg       rendus enregistrés
    rendus/<forme>_<style>.png

<dossier_commandes>/Exports/                 exports prêts à envoyer (voir EXPORTER)
    <Nom client>/                            le dossier dézippé (pratique dans le Finder)
    <Nom client>.zip                         le même, à joindre à un mail
<dossier_commandes>/.corbeille/              commandes supprimées
```
`Exports/` et `.corbeille/` ne sont jamais listés par `COMMANDES`.
Les poses et les mosaïques ne quittent jamais le dossier de la commande :
elles ne partent PAS dans les exports.

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
| `EXPORTER` | prépare l'envoi de la commande courante : dossier lisible au nom du client + zip (détail ci-dessous) | 0..n × `export_progres {etape, total, texte}` puis `exporte {dossier, zip, resume, …}` |

## EXPORTER en détail

Arborescence produite (et contenu EXACT du zip, qui a un seul dossier racine) :
```
<dossier_commandes>/Exports/<Nom client>.zip
└── <Nom client>/
    ├── Récapitulatif.txt                       résumé (= `resume`) + détail des fichiers
    ├── <Nom client> – <Forme> <Style>.svg      rendu final assemblé (si forme choisie
    ├── <Nom client> – <Forme> <Style>.png       et compatible avec le nombre d'empreintes)
    └── <Prénom>/                               un dossier par empreinte, dans l'ordre
        ├── <Prénom> – photo.png                photo normalisée, recadrée
        ├── <Prénom> – <Style>.svg              l'empreinte SEULE dans le style choisi
        └── <Prénom> – <Style>.png              (SVG vectoriel à graver, PNG pour regarder)
```
- Noms lisibles : accents, espaces et majuscules gardés ; `/ \ : * ? " < > |`
  retirés ; jamais de point en tête. Prénoms en double → `Louis`, `Louis (2)`…
  (comparaison sans casse). Prénom vide → `Empreinte N`. Séparateur « – »
  (tiret demi-cadratin entouré d'espaces).
- `<Forme>` / `<Style>` = libellés de l'app : `Simple`, `Cœur`, `Trèfle 3`,
  `Trèfle 4` ; `Gabor`, `Traits` (sans), `Traits soudés` (contact), `Photo`.
  Pour le style photo, le fichier de l'empreinte s'appelle
  `<Prénom> – Photo découpée.svg/.png` (sinon il écraserait `– photo.png`,
  le Mac ignorant la casse).
- Empreinte seule = `formes.composer([mosaïque], "simple", style, crops=[crop],
  completions=[completer])` : l'ovale à un lobe, cadrage et complétion
  respectés, `ajust` ignoré (il ne concerne que les lobes cœur/trèfle).
- Rendu final : repris tel quel du cache d'aperçus du moteur s'il existe pour
  la forme/le style de la commande (donc après un `APERCU`, l'export ne refait
  que les empreintes seules), sinon recalculé avec les `ajust`. Pas de rendu
  final si aucune forme n'est choisie, ni si la forme ne convient plus au
  nombre d'empreintes (cœur = 2, trèfle = 3 ou 4) — dit dans le récapitulatif
  et dans `avertissements`.
- Aucun style choisi → style par défaut de l'app, `contact` (« Traits
  soudés »), signalé dans `resume` et le récapitulatif (`style_defaut: true`).
- Un nouvel export remplace l'ancien du même client (dossier ET zip). Tout est
  préparé à côté puis mis en place à la fin : un export raté laisse l'ancien
  intact. Le zip est construit à partir de la liste des fichiers produits :
  aucun fichier caché (.DS_Store…), ni mosaïque, ni pose brute.
- Récapitulatif.txt : UTF-8 avec BOM, fins de ligne CRLF (s'ouvre bien sur
  Mac comme sur Windows).
- Durée : ~7 s par empreinte sur un Mac récent (2 tracés calculés en
  parallèle), beaucoup plus si la complétion est désactivée (~1 min par
  empreinte), + le rendu final s'il n'est pas en cache.

Événements :
- `export_progres {etape, total, texte}` — `etape` = numéro de l'étape EN
  COURS (1..`total`) = étapes terminées + 1, donc fraction accomplie =
  `(etape − 1) / total`. Une étape = le tracé d'une empreinte, le rendu
  final (s'il y en a un), le zip. Émis au départ (`etape` 1, « Préparation
  de l'export… »), à chaque tracé terminé, puis avant le zip (`etape` =
  `total`, « Création du zip… ») ; `etape` peut se répéter, jamais
  reculer. `texte` = libellé lisible (« Louis : tracé Traits soudés prêt »).
  Les tracés finissant dans le désordre, ne pas en déduire quelle empreinte
  est en cours. `exporte` (ou `error`) clôt toujours la série.
- `exporte {dossier, zip, resume, nom, id, nom_export, fichiers, forme,
  style, style_defaut, avertissements, dossier_commande}` :
  `dossier` = le dossier d'export DÉZIPPÉ (`…/Exports/<Nom client>`) — ce
  n'est plus le dossier de la commande, qui est dans `dossier_commande` ;
  `zip` = `…/Exports/<Nom client>.zip` ; `resume` = texte du mail ;
  `nom` = nom de la commande tel quel, `nom_export` = nom de dossier/zip
  nettoyé ; `fichiers` = chemins absolus de tous les fichiers exportés (ordre
  du zip) ; `forme` = forme du rendu final ou null ; `style` = style
  canonique exporté (`gabor|sans|contact|photo`) ; `avertissements` = liste
  de phrases (vide si tout va bien).
- Si `avertissements` n'est pas vide, le moteur envoie EN PLUS, juste après
  `exporte`, un `error {raison: "Export incomplet : …"}` pour que l'app
  actuelle l'affiche.

## Comportements modifiés

- `VALIDER …` : en plus du comportement actuel, écrit mosaique.png,
  photo.png et commande.json sur disque, et les poses brutes de la session
  (`SessionFusion.captures`, si l'attribut existe et n'est pas vide) dans
  `empreintes/NN_prenom/poses/pose_01.png…` ; elles suivent ensuite les
  renumérotations/renommages du dossier. Rien ne change dans commande.json
  ni dans les événements. Événement `empreinte_validee`
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
