#!/usr/bin/env bash
set -euo pipefail

# Construit dist/ScreenBlur.app à partir de la cible SPM du même nom.
# La signature est le seul endroit qui décide si le bundle est partageable
# hors de cette machine — voir le bloc « Signature » plus bas.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_NAME="ScreenBlur"
EXECUTABLE="ScreenBlur"
BUNDLE_ID="design.axolo.screenblur"
LOCAL_IDENTITY="SpaceNamer Dev"   # certificat auto-signé, valable sur cette machine seulement

BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --product "$EXECUTABLE"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"
chmod +x "$CONTENTS/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ROOT_DIR/Resources/$APP_NAME.icns" ]]; then
    cp "$ROOT_DIR/Resources/$APP_NAME.icns" "$CONTENTS/Resources/$APP_NAME.icns"
else
    echo "⚠️  Resources/$APP_NAME.icns absent — icône générique."
    echo "   → ./scripts/make_icns.sh --fit <icone-1024.png> $APP_NAME"
fi

# ── Signature ────────────────────────────────────────────────────────────────
# Trois cas, du meilleur au pire :
#   1. Developer ID Application → runtime durci + horodatage, notarisable,
#      s'ouvre d'un double-clic sur n'importe quel Mac.
#   2. certificat local auto-signé → l'app marche ICI et garde son autorisation
#      d'enregistrement de l'écran d'un build à l'autre, mais Gatekeeper la
#      refuse ailleurs.
#   3. ad-hoc → empreinte différente à chaque compilation : macOS révoque
#      l'autorisation SANS décocher la case, et les styles par recapture
#      cessent de fonctionner sans que rien ne l'indique.
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)

if [[ -n "$DEV_ID" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP_DIR"
    echo "Signé Developer ID : $DEV_ID"
    echo "→ Reste la notarisation : ./scripts/package.sh --notarize"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
    codesign --force --deep --sign "$LOCAL_IDENTITY" "$APP_DIR"
    echo "Signé « $LOCAL_IDENTITY » (auto-signé) — bon pour cette machine."
    echo "⚠️  Gatekeeper refusera ce bundle sur un autre Mac : voir docs/DISTRIBUTION.md."
else
    codesign --force --deep --sign - "$APP_DIR"
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Signature ad-hoc : l'autorisation d'enregistrement de l'écran est réinitialisée."
fi

codesign --verify --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/   /'
echo "Créé : $APP_DIR"
