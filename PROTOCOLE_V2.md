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
    rendus/<forme>_<style>.svg       rendus enregistrés (formes assemblées)
    rendus/<forme>_<style>.png
    rendus/separees_<style>/<NN_prenom>.svg|.png   empreintes séparées : un
                                     rendu par empreinte (NN_prenom = nom du
                                     dossier de l'empreinte, ex. 01_louis)

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
Pour l'ovale coupé et le tête-bêche, la rotation se fait autour du centre
de l'ovale (là où l'empreinte est posée) ; en tête-bêche l'`angle` de
l'empreinte 2 s'ajoute à ses 180°.

## Formes

| `forme` | Libellé app | Empreintes | Rendu |
|---|---|---|---|
| `separees` | Séparées | toutes | PAS de composition : chaque empreinte est rendue SEULE (comme une commande d'une empreinte : son ovale, son cadrage, sa complétion, sans `ajust`) ; l'aperçu est une planche qui les pose côte à côte |
| `coeur` | Cœur | 2 | inchangé |
| `trefle` | Trèfle 3 / Trèfle 4 | 3 ou 4 | inchangé |
| `ovale_lr` | Ovale coupé | exactement 2 | UN ovale (celui d'une empreinte seule) coupé verticalement par un fin espace vide (22 px, comme le milieu du cœur, rien n'y est gravé) : empreinte 1 dans la moitié GAUCHE, empreinte 2 dans la moitié DROITE |
| `tete_beche` | Tête-bêche | exactement 2 | le même ovale coupé HORIZONTALEMENT : empreinte 1 droite dans la moitié du HAUT, empreinte 2 tournée de 180° dans la moitié du BAS (on voit le haut de chacune, symétriques) |
| `simple` | (ancien) | toutes | rétro-compatibilité : n ovales côte à côte, rendu inchangé ; l'app le traite comme `separees` (l'export aussi : pas de rendu assemblé) |

Ovale coupé / tête-bêche : chaque empreinte est mise à l'échelle comme si
elle remplissait TOUT l'ovale (même échelle qu'une empreinte seule), centrée
sur le centre de l'ovale (le centre du cadrage ≈ le noyau, la coupure passe
donc par le noyau), puis découpée par sa moitié ; la complétion remplit la
demi-zone jusqu'à son bord et les traits s'arrêtent net le long de la
coupure (aucun bout de crête ne court le long du bord, pas de miettes).
Tous les styles marchent (`contact`/`traits`, `sans`, `gabor`, `photo`).

Synonymes acceptés : `ovale_coupe` → `ovale_lr` ; `tete-beche`, `tête-bêche`
→ `tete_beche` ; `separee`, `séparées` → `separees` (+ ceux de toujours :
`trefle3`, `trefle4`, `cœur`…).

Mauvais nombre d'empreintes pour `ovale_lr` / `tete_beche` (APERCU,
ENREGISTRER) → `error {raison: "La forme « Ovale coupé » demande exactement
2 empreintes."}` (« Tête-bêche » pour l'autre), rien n'est calculé.

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
| `RENDU_EMPREINTE <i> <style>` | l'empreinte i SEULE dans le style (le même rendu que dans l'export : son crop, son completer, sans ajust). Ne change rien à la commande (ni forme, ni style, ni vignette) | `rendu_empreinte {index, style, png, svg, largeur_forme, horodatage}` ; erreur → `error {raison, index}` |
| `EXPORTER` | prépare l'envoi de la commande courante : dossier lisible au nom du client + zip (détail ci-dessous) | 0..n × `export_progres {etape, total, texte}` puis `exporte {dossier, zip, resume, …}` |

## EXPORTER en détail

Arborescence produite (et contenu EXACT du zip, qui a un seul dossier racine) :
```
<dossier_commandes>/Exports/<Nom client>.zip
└── <Nom client>/
    ├── Récapitulatif.txt                       résumé (= `resume`) + détail des fichiers
    ├── <Nom client> – <Forme> <Style>.svg      rendu final assemblé (forme assemblée,
    ├── <Nom client> – <Forme> <Style>.png       compatible avec le nombre d'empreintes)
    └── <Prénom>/                               un dossier par empreinte, dans l'ordre
        ├── <Prénom> – photo.png                photo normalisée, recadrée
        ├── <Prénom> – <Style>.svg              l'empreinte SEULE dans le style choisi
        └── <Prénom> – <Style>.png              (SVG vectoriel à graver, PNG pour regarder)
```
- Noms lisibles : accents, espaces et majuscules gardés ; `/ \ : * ? " < > |`
  retirés ; jamais de point en tête. Prénoms en double → `Louis`, `Louis (2)`…
  (comparaison sans casse). Prénom vide → `Empreinte N`. Séparateur « – »
  (tiret demi-cadratin entouré d'espaces).
- `<Forme>` / `<Style>` = libellés de l'app : `Cœur`, `Trèfle 3`,
  `Trèfle 4`, `Ovale coupé`, `Tête-bêche` (ex. « Dupont – Ovale coupé
  Traits soudés.svg ») ; `Gabor`, `Traits` (sans), `Traits soudés`
  (contact), `Photo`.
  Pour le style photo, le fichier de l'empreinte s'appelle
  `<Prénom> – Photo découpée.svg/.png` (sinon il écraserait `– photo.png`,
  le Mac ignorant la casse).
- Empreinte seule = `formes.composer([mosaïque], "simple", style, crops=[crop],
  completions=[completer])` : l'ovale à un lobe, cadrage et complétion
  respectés, `ajust` ignoré (il ne concerne que les lobes cœur/trèfle).
- Rendu final : repris tel quel du cache d'aperçus du moteur s'il existe pour
  la forme/le style de la commande (donc après un `APERCU`, l'export ne refait
  que les empreintes seules), sinon recalculé avec les `ajust`. Seules les
  formes ASSEMBLÉES en ont un (`coeur`, `trefle`, `ovale_lr`, `tete_beche`) :
  forme `separees`, `simple` ou pas de forme → seulement les empreintes
  seules, et le récapitulatif dit « Empreintes séparées : une médaille par
  empreinte. ». Pas de rendu final non plus si la forme ne convient plus au
  nombre d'empreintes (cœur, ovale coupé, tête-bêche = 2, trèfle = 3 ou 4)
  — dit dans le récapitulatif et dans `avertissements`.
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
  du zip) ; `forme` = forme du rendu final ou null (toujours null pour
  `separees` / `simple`) ; `style` = style
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
  Pour `separees` : rend chaque empreinte seule (mémoire de RENDU_EMPREINTE)
  et fabrique une planche propre (les empreintes côte à côte sur fond blanc,
  sans texte, au plus 2200 px de large) qui sert d'aperçu et de vignette.
  Événement `apercu_pret {png, forme, style, cache, horodatage,
  largeur_forme, lobes}` (voir « Disposition » plus bas).
- `ENREGISTRER <forme> <style>` : écrit dans `<id>/rendus/` (plus dans
  l'ancien dossier), met à jour la vignette. Événement `compose
  {svg, png, dossier, forme, style, nom, id, fichiers}` (`dossier` = dossier
  de la commande, `fichiers` = tous les fichiers écrits, chemins absolus).
  `ENREGISTRER separees <style>` écrit `rendus/separees_<style>/<NN_prenom>.svg`
  et `.png` pour chaque empreinte (le dossier est vidé avant : aucun reste
  d'une empreinte supprimée) ; `svg`/`png` = ceux de la 1re empreinte,
  `fichiers` = [svg 1, png 1, svg 2, png 2, …].
- `RENDU_EMPREINTE <i> <style>` : rendu gardé en mémoire selon le CONTENU
  (mosaïque, crop, completer, style) — il n'est donc jamais périmé : un
  recadrage, un changement de complétion ou une suppression (qui renumérote
  les index) donne simplement un autre rendu. Les 4 styles d'une empreinte
  enchaînés : ~1 s pour le premier, ~0,05–0,15 s pour les suivants ; déjà
  calculé : ~0,01 s. `style` est renvoyé tel que demandé ; `png` (aperçu,
  fond blanc) et `svg` (à graver) sont des chemins absolus qui changent
  quand le rendu change ; `largeur_forme` comme ci-dessous (ovale d'une
  empreinte seule ≈ 0,856).

## Disposition (`apercu_pret.largeur_forme`, `apercu_pret.lobes`)

Toutes les valeurs sont des FRACTIONS de la largeur (x) et de la hauteur
(y) du PNG d'aperçu, pour toutes les formes :

- `largeur_forme` : part de la largeur du PNG occupée par la forme gravée
  (pour l'affichage « taille réelle 1 cm ») ; pour `separees`, la largeur
  d'UNE médaille (un ovale) rapportée à la largeur de la planche.
- `lobes` = `[{index, cx, cy, rx, ry, angle, zone}]`, un par empreinte, dans
  l'ordre des empreintes :
  - `cx`, `cy` : centre ACTUEL de l'empreinte i, `ajust` compris (pour
    l'ovale coupé et le tête-bêche, les deux empreintes sont centrées sur le
    centre de l'ovale : leurs centres coïncident tant qu'aucune n'est
    décalée) ;
  - `rx`, `ry` : demi-axes de son cadre de placement (l'ovale entier pour
    les formes coupées, le lobe pour cœur / trèfle, l'ovale pour separees) ;
  - `angle` : rotation affichée de l'empreinte, en degrés, sens HORAIRE
    comme `ajust.angle`, rotation de la forme comprise (±20° du cœur,
    rotation des feuilles du trèfle, +180° pour l'empreinte 2 en
    tête-bêche), ramenée dans ]−180, 180] (tête-bêche sans ajust : 0 et 180) ;
  - `zone` : `[x0, y0, x1, y1]`, rectangle de la partie VISIBLE de
    l'empreinte (sa demi-zone, son lobe, son ovale dans la planche) — pour
    poser l'étiquette « 1 · Louis » dessous et le cadre de sélection.
- Cache d'aperçus vidé à chaque changement de crop / ajust / suppression /
  renommage n'est pas nécessaire pour renommage (ne change pas l'image).

## Notes

- Tous les chemins renvoyés sont ABSOLUS.
- `formes.composer(...)` gagne un paramètre `ajusts=None`
  (liste de dicts {dx, dy, angle} ou None) — rétrocompatible. Il lève
  `ValueError` (message prêt à afficher) si `ovale_lr` / `tete_beche` ne
  reçoivent pas 2 empreintes. `formes.rendre_seule(...)` rend une empreinte
  seule, `formes.disposition(forme, n, ajusts)` donne `largeur_forme` /
  `lobes`, `formes.planche(pngs, sortie)` fabrique la planche `separees`.
- Le moteur ne doit JAMAIS écrire de non-JSON sur stdout.
