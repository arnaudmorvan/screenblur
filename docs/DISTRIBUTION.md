# Sortir de cette machine

## L'état actuel

Le bundle est signé avec **`SpaceNamer Dev`**, un certificat auto-signé local.
Conséquences, dans l'ordre d'importance :

1. **Gatekeeper refuse l'app sur tout autre Mac.** L'utilisateur doit passer par
   Réglages Système → Confidentialité et sécurité → « Ouvrir quand même ». Le
   contournement par clic droit → Ouvrir a été retiré dans Sequoia.
2. **Sur cette machine, l'autorisation d'enregistrement de l'écran survit aux
   recompilations.** C'est la raison d'être de ce certificat : l'exigence
   désignée est `identifier "design.axolo.screenblur" and certificate leaf =
   H"…"` (vérifiable avec `codesign -d -r- dist/ScreenBlur.app`), donc elle ne
   dépend pas de l'empreinte du binaire. Une signature **ad-hoc**, elle, change
   à chaque compilation : macOS révoque l'autorisation **sans décocher la case**,
   et les styles par recapture cessent de fonctionner sans que rien ne l'indique.

## Ce qu'il faudrait pour un double-clic qui marche partout

Un compte Apple Developer payant (99 $/an), puis :

1. Créer un certificat **Developer ID Application** et l'installer dans le
   trousseau. `scripts/build.sh` le détecte tout seul et bascule dessus, avec
   runtime durci et horodatage.
2. Enregistrer un profil de notarisation, une fois :
   ```sh
   xcrun notarytool store-credentials "AXOLO_NOTARY" \
       --apple-id "morvan.arn@gmail.com" --team-id "XXXXXXXXXX" \
       --password "<mot de passe d'application>"
   ```
3. `./scripts/package.sh --notarize` — le script envoie le `.dmg` à Apple,
   attend le verdict, agrafe le ticket au disque (l'app s'ouvre ensuite même
   hors ligne) et vérifie l'agrafage.

`package.sh --notarize` refuse de partir si le bundle n'est pas signé Developer
ID : mieux vaut un échec net qu'une archive qu'on croit notarisée.

## Vérifier avant d'envoyer

```sh
codesign --verify --deep --strict --verbose=2 dist/ScreenBlur.app
spctl --assess --type execute --verbose=2 dist/ScreenBlur.app
shasum -a 256 -c dist/release/SHA256SUMS.txt
```

`spctl` répondra `rejected` tant qu'il n'y a pas de notarisation. C'est attendu,
et c'est exactement ce que verra la personne qui télécharge.

## Les binaires ne sont pas versionnés

`dist/` est ignoré par git. Les archives vivent dans les Releases GitHub, où
elles portent une version, une date et une somme de contrôle.
