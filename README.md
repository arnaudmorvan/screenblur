# ScreenBlur

**Blur part of your screen while you share it.** Draw a zone over what nobody
needs to see — a conversation, a dashboard, a client name — and it stays hidden
for the whole screen share. A zone can be fixed on screen, or attached to one
app and follow its window.

*Français : voir [plus bas](#français).*

---

## Download

**[→ Latest release](https://github.com/ArnaudMorvan/screenblur/releases/latest)**
— `ScreenBlur-1.0.0.dmg`, macOS 15 Sequoia or later.

> **First launch.** The app is signed but **not notarised by Apple**, so macOS
> will refuse to open it: *"cannot verify the developer"*. Dismiss the message,
> then go to **System Settings → Privacy & Security**, scroll to the bottom and
> click **Open Anyway**. The old right-click → Open trick no longer works —
> Apple removed it in Sequoia. Notarisation needs a paid Apple Developer
> account; see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

> **The interface is in French.** The code is not localised yet. Everything in
> this README maps to what you will see on screen.

## What it does

- **A zone, fixed on screen.** `⌥⇧N`, drag a rectangle, `⏎`. It is masked from
  then on, and click-through: you keep working underneath.
- **A zone attached to an app.** The same rectangle, but it only exists on that
  app's windows and follows them when you move or resize them. Use it to hide
  one corner of one app — an account name, a balance — without hiding the rest.
- **A whole app.** Every window of it, wherever they go.
- **Four styles.** Frosted glass and opaque need **no permission at all**;
  adjustable blur and pixelate reread the screen and ask for Screen Recording.
- **A preview of what the others see**, captured through the exact same path a
  screen share uses. It is the only honest way to check, and it takes three
  seconds.

### Two gestures

| | |
|---|---|
| `⌥⇧N` | Create / edit zones. Drag on empty space to draw, drag inside to move, handles to resize, `⌫` to delete, `⏎` when done. |
| `⌥⇧B` | Lift or drop every mask at once, without losing them. |

Global shortcuts go through Carbon `RegisterEventHotKey`, so they need **no
Accessibility permission**.

## The one thing to know

Sharing your **whole screen** shows the masks: a floating window is part of the
image macOS composes, like any other window.

Sharing a **single window** does not. The call then captures that window alone,
and no tool of this kind can insert itself into that capture — the content you
believe is hidden goes on air. **Share the whole screen**, or check first with
*Aperçu de ce que voient les autres…* in the menu.

## How it works

- Window tracking uses `CGWindowListCopyWindowInfo`, which gives the owner, the
  frame and the depth order of every window **without any permission** — only a
  window's *title* is protected by macOS, and ScreenBlur does not need it.
- A window in front of a masked one **punches a hole** in the mask, recomputed
  from the real depth order. Otherwise masking a background app would blur the
  window sitting on top of it.
- Masks never disappear, they fall asleep: a window hidden behind another keeps
  its mask in place, empty. Coming back to it reveals nothing, because there is
  nothing to create.
- On app activation the incoming window is masked **in full, immediately**, and
  stays that way for 0.35 s — long enough for macOS to settle the window order,
  which a poll would otherwise read stale and punch through at the worst moment.
- Cost at rest: **0.6 % of one core, 40 MB**. The full window survey costs
  ~1.1 ms, so it only runs at full rate while the mouse is moving — a window
  cannot move on its own.

## Build from source

```sh
swift build -c release --product ScreenBlur   # or:
./scripts/build.sh        # builds dist/ScreenBlur.app, signed
./scripts/package.sh      # + dmg, zip and checksums in dist/release/
./scripts/test.sh         # unit tests (a plain executable, no XCTest)
./scripts/diagnostic_suivi.sh [bundle-id…]    # what ScreenBlur sees of an app's windows
```

No dependencies. Swift 6 toolchain, Swift 5 language mode, AppKit +
ScreenCaptureKit + Core Image.

## Privacy

Nothing leaves your machine. No account, no network, no telemetry. The
recapture styles read the screen locally to redraw it blurred and keep nothing.
Zones live in `~/Library/Application Support/ScreenBlur/zones.json`.

## License

MIT — see [LICENSE](LICENSE).

---

# Français

**Flouter une partie de son écran pendant qu'on le partage.** On trace une zone
sur ce qui ne regarde personne — une conversation, un tableau de bord, un nom de
client — et elle reste masquée pendant tout le partage. Une zone peut être fixe
sur l'écran, ou rattachée à une application et suivre sa fenêtre.

## Télécharger

**[→ Dernière version](https://github.com/ArnaudMorvan/screenblur/releases/latest)**
— `ScreenBlur-1.0.0.dmg`, macOS 15 Sequoia ou plus récent.

> **Premier lancement.** L'app est signée mais **pas notarisée par Apple** :
> macOS refusera de l'ouvrir (« impossible de vérifier le développeur »). Fermez
> le message, puis **Réglages Système → Confidentialité et sécurité**, tout en
> bas, **Ouvrir quand même**. Le clic droit → Ouvrir ne marche plus depuis
> Sequoia.

## Ce qu'elle fait

- **Une zone, fixe sur l'écran.** `⌥⇧N`, on trace, `⏎`. Elle est masquée, et
  laisse passer les clics : on continue de travailler dessous.
- **Une zone rattachée à une application.** Le même rectangle, mais il n'existe
  que sur les fenêtres de cette application et les suit quand on les déplace.
  Pour cacher un coin d'une app — un nom de compte, un solde — sans cacher tout
  le reste.
- **Une application entière**, toutes ses fenêtres, où qu'elles aillent.
- **Quatre styles.** Verre dépoli et cache opaque ne demandent **aucune
  autorisation** ; flou réglable et mosaïque relisent l'écran et demandent
  l'enregistrement de l'écran.
- **Un aperçu de ce que voient les autres**, pris par le chemin exact d'un
  partage d'écran. C'est la seule vérification qui vaille, et elle prend trois
  secondes.

### Deux gestes

| | |
|---|---|
| `⌥⇧N` | Créer / modifier les zones. Glisser dans le vide pour tracer, dedans pour déplacer, les poignées pour redimensionner, `⌫` pour supprimer, `⏎` pour terminer. |
| `⌥⇧B` | Lever ou reposer tout le flou d'un coup, sans rien perdre. |

Les raccourcis passent par Carbon `RegisterEventHotKey` : **aucune autorisation
d'accessibilité**.

## La chose à savoir

Un partage de l'**écran entier** montre les masques : une fenêtre flottante fait
partie de l'image composée par macOS, comme n'importe quelle autre.

Un partage d'**une seule fenêtre** ne les montre pas. La visioconférence ne
capture alors que cette fenêtre, et aucun outil de ce type ne peut s'y insérer :
le contenu que vous croyez masqué passe à l'antenne. **Partagez l'écran
entier**, ou vérifiez d'abord avec *Aperçu de ce que voient les autres…*.

## Comment ça marche

- Le suivi des fenêtres passe par `CGWindowListCopyWindowInfo`, qui donne le
  propriétaire, le cadre et l'ordre de profondeur **sans aucune autorisation** —
  seul le *titre* d'une fenêtre est protégé, et ScreenBlur n'en a pas besoin.
- Une fenêtre placée devant celle qu'on masque **perce le masque**, recalculé
  depuis l'ordre de profondeur réel. Sinon, masquer une application d'arrière-
  plan flouterait la fenêtre posée par-dessus.
- Un masque ne disparaît jamais, il s'endort : une fenêtre cachée derrière une
  autre garde le sien, vide. Y revenir ne découvre rien, puisqu'il n'y a rien à
  recréer.
- À l'activation d'une application, sa fenêtre est masquée **en entier tout de
  suite**, et le reste 0,35 s — le temps que macOS réordonne les fenêtres, qu'un
  relevé lirait encore périmées et percerait au pire moment.
- Coût au repos : **0,6 % d'un cœur, 40 Mo**. Le relevé complet coûte ~1,1 ms :
  il ne tourne à pleine cadence que pendant que la souris bouge — une fenêtre ne
  se déplace pas toute seule.

## Compiler

```sh
./scripts/build.sh        # dist/ScreenBlur.app, signée
./scripts/package.sh      # + dmg, zip et sommes de contrôle dans dist/release/
./scripts/test.sh         # tests unitaires (un exécutable, pas de XCTest)
./scripts/diagnostic_suivi.sh [identifiant…]   # ce que ScreenBlur voit d'une app
```

Aucune dépendance. Chaîne Swift 6 en mode langage 5, AppKit + ScreenCaptureKit
+ Core Image.

## Vie privée

Rien ne sort de votre machine. Aucun compte, aucun réseau, aucune télémétrie.
Les zones vivent dans `~/Library/Application Support/ScreenBlur/zones.json`.

## Licence

MIT — voir [LICENSE](LICENSE).
