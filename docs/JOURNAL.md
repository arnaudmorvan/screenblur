# Journal de fabrication

Écrit pendant le développement, gardé parce que trois de ces points sont des
pièges qu'on ne voit pas et que j'ai chacun payés une fois.

## Ce qui a été vérifié, et comment

Le principe de l'app — « le masque reste pendant un partage d'écran » — ne se
démontre pas par raisonnement. Tout a été vérifié **par l'image**, via le mode
diagnostic `ScreenBlur --apercu <chemin>` : il pose les masques, capture l'écran
par le même chemin qu'un partage plein écran (`SCScreenshotManager`), écrit un
PNG et décrit le plan des masques posés.

- Les quatre styles ont été photographiés sur un écran réel : le masque est bien
  présent dans la capture, et le contenu dessous illisible, pendant que le texte
  autour reste net.
- L'occlusion a été mesurée en comparant deux captures, une avec masque et une
  sans : **0 % des pixels changent dans les trous** (la fenêtre de devant est
  intacte), **100 % sur les zones masquées**.
- Le placement d'une zone rattachée a été vérifié à l'arithmétique près : zone
  `0,35 / 0,35 / 0,30 × 0,25` dans une fenêtre `1728,-326,2560,1410` → masque
  posé à `2624, 238, 768, 352`, les quatre valeurs attendues.

## Trois pièges

### `kCGWindowSharingState` ne veut plus rien dire

Sur macOS 26 il vaut 0 (« aucun partage ») pour 60 fenêtres sur 62, Centre de
contrôle compris — des fenêtres qui se partagent parfaitement. Diagnostiquer avec
ce champ mène à un faux bug. Seule une image prouve qu'un overlay passe dans la
capture. (`NSWindow.sharingType = .readWrite` est par ailleurs déprécié depuis
macOS 15 : écrire `.readOnly`.)

### Le pair-impair rebouche les trous qui se chevauchent

Percer un masque en empilant les rectangles des fenêtres de devant dans un
`NSBezierPath` en `.evenOdd` marche pour UN trou et casse dès que deux se
chevauchent : leur intersection compte deux fois et redevient pleine, donc le
masque se reforme exactement là où il fallait percer. Or deux fenêtres qui
recouvrent la même fenêtre se chevauchent presque toujours.

La région visible est donc calculée comme une liste de rectangles **disjoints**
(grille des bords, une cellule dedans ou dehors, fusion par bandes). Corollaire
de méthode : un test à un seul trou passe et ne prouve rien — `CoreTests.swift`
teste deux trous qui se chevauchent et trois empilés.

### Un overlay qui suit une fenêtre doit être vif, sinon il découvre

Trois réflexes, dans cet ordre d'importance :

1. Ne jamais détruire l'overlay d'une fenêtre devenue invisible — l'endormir. Le
   recréer quand elle revient laisse son contenu à l'air le temps de la créer.
2. Écouter `NSWorkspace.didActivateApplicationNotification` et masquer **en
   entier** tout de suite, avec un délai de grâce de 0,35 s pendant lequel on
   ignore les recouvrements : le temps que le WindowServer réordonne, un relevé
   encore basé sur l'ancien ordre rouvrirait un trou pile au mauvais moment.
3. Pour la cadence, sonder `NSEvent.mouseLocation` (quelques µs, sans
   autorisation) à 30 Hz et ne payer le relevé complet (~1,1 ms) à pleine
   cadence que pendant que ça bouge. Repos : 0,6 % d'un cœur au lieu de 3,5 %.

## Deux fausses pistes, gardées pour mémoire

- La tache grise du flou gaussien n'était **pas** une dérive colorimétrique :
  juste un flou de rayon 40 aspirant une fenêtre blanche voisine. Un test sur
  `CVPixelBuffer` le prouve — le rendu naïf et le rendu à espace fixé donnent le
  même gris 128. Les espaces sont fixés quand même, comme contrat écrit, pas
  comme correctif.
- Le relevé des fenêtres ne peut pas se limiter aux applications déjà suivies :
  sans relevé ponctuel indépendant, on ne connaît que les fenêtres des
  applications déjà rattachées, et **aucune première zone ne peut jamais
  l'être**. Et ce relevé ne doit pas écarter les fenêtres recouvertes : on y
  cherche *où est* une fenêtre, pas s'il faut la masquer.

## Durcissements du 2026-09-27

Deux réglages qui, chacun, pouvaient faire disparaître un masque en silence.

- **`canHide = false` sur les fenêtres de masque.** Par défaut une fenêtre suit le masquage de
  son application : un « Masquer les autres » (⌘⌥H), un `NSApp.hide`, ou un outil
  d'enregistrement qui fait le ménage avant de filmer effaçait les masques. Le contenu, lui,
  restait affiché.
- **Seules les fenêtres ordinaires (couche 0) comptent comme obstacles.** Le cadre d'une fenêtre
  ne dit pas qu'elle est opaque : un calque flottant plein écran — sélecteur d'enregistrement,
  outil d'annotation, HUD, bannière — recouvre tout sans rien cacher. Le compter perçait le
  masque alors que le contenu restait visible dessous. Conséquence assumée : un masque peut
  désormais recouvrir le Dock, la barre des menus ou une bannière. C'est laid et sans danger,
  alors que l'inverse était propre et dangereux.

Ajouté au passage, parce que leur absence a coûté plusieurs allers-retours :
`scripts/diagnostic_masques.sh` (journalise l'état des masques et les grandes fenêtres pendant
qu'on reproduit un problème) et un `--apercu` qui rapporte l'état **même quand la capture
échoue** — c'est justement là qu'on en a besoin. Le rapport dit maintenant ce que le suivi a reçu
comme consigne, si son minuteur tourne, et ce que donne le relevé brut du système.

**Rappel de comportement, pas un bug :** une zone rattachée à une application n'existe que tant
que cette application a une fenêtre à l'écran. Application quittée, fenêtre fermée ou réduite : le
masque disparaît, puisqu'il n'y a plus rien à cacher. Un `Claude [com.anthropic.claudefordesktop] :
aucune fenêtre à l'écran` dans `diagnostic_suivi.sh` explique à lui seul un masque absent.

## Ce qui reste à faire

- **Interface bilingue.** Tout est en français ; les autres apps de la série ont
  un `Strings.swift` avec l'anglais par défaut.
- **Notarisation**, cf. `DISTRIBUTION.md`.
- Le style est global : toutes les zones partagent le même rendu et la même
  intensité. Un style par zone se tiendrait.
- Au-delà de douze fenêtres devant celle qu'on masque, les plus petits
  recouvrements sont ignorés : le masque couvre alors un peu plus que nécessaire.
  L'erreur va dans le sens sûr, mais le plafond est arbitraire.
