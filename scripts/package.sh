#!/usr/bin/env bash
set -euo pipefail

# Emballe dist/ScreenBlur.app en un .dmg et un .zip prêts à envoyer, dans
# dist/release/. Reconstruit l'app d'abord — on ne fabrique jamais une archive
# à partir d'un bundle dont on ignore l'âge.
#
#   ./scripts/package.sh              # dmg + zip
#   ./scripts/package.sh --notarize   # + notarisation Apple (Developer ID requis)

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_NAME="ScreenBlur"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
OUT_DIR="$ROOT_DIR/dist/release"
NOTARY_PROFILE="AXOLO_NOTARY"
NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

"$ROOT_DIR/scripts/build.sh"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
BASENAME="$APP_NAME-$VERSION"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# ── Contenu du disque ────────────────────────────────────────────────────────
STAGE=$(mktemp -d)/"$APP_NAME"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT_DIR/Resources/readme-en.txt" "$STAGE/Read me — install.txt"
cp "$ROOT_DIR/Resources/readme-fr.txt" "$STAGE/À lire — installation.txt"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
    -quiet "$OUT_DIR/$BASENAME.dmg"
rm -rf "$(dirname "$STAGE")"

# ── Zip ──────────────────────────────────────────────────────────────────────
# ditto préserve la signature du bundle, ce que `zip` ne garantit pas.
ditto -c -k --keepParent --sequesterRsrc "$APP_DIR" "$OUT_DIR/$BASENAME.zip"

if $NOTARIZE; then
    if ! codesign -dv "$APP_DIR" 2>&1 | grep -q "Developer ID Application"; then
        echo "✗ Notarisation impossible : le bundle n'est pas signé Developer ID." >&2
        echo "  Voir docs/DISTRIBUTION.md." >&2
        exit 1
    fi
    xcrun notarytool submit "$OUT_DIR/$BASENAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT_DIR/$BASENAME.dmg"
    xcrun stapler validate "$OUT_DIR/$BASENAME.dmg"
fi

cd "$OUT_DIR"
shasum -a 256 "$BASENAME.dmg" "$BASENAME.zip" > SHA256SUMS.txt

echo
echo "Prêt dans dist/release/ :"
ls -lh "$OUT_DIR" | sed 's/^/   /'
echo
spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/   verdict Gatekeeper : /' || true
