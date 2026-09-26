#!/usr/bin/env bash
set -euo pipefail

# Fabrique Resources/<App>.icns à partir d'un PNG carré de 1024×1024.
# L'app vaut FastPaste par défaut ; tout autre nom en deuxième argument.
#
#   ./scripts/make_icns.sh --fit Resources/FastPaste-1024.png
#   ./scripts/make_icns.sh --fit ~/Downloads/keyfigma-1024.png KeyFigma
#
# --fit recale le dessin sur la grille d'Apple. Une icône d'app macOS n'occupe
# pas tout le carré : mesuré sur Notes, Rappels et Aperçu, la forme pleine fait
# 814 px dans 1024, soit 105 px de marge de chaque côté. Le script mesure la
# boîte opaque de la source et la ramène à cette taille, centrée — une icône
# même légèrement plus grande paraît plus grosse que ses voisines dans le Dock.
# À utiliser sur toute image générée : les générateurs ne connaissent pas cette
# grille.
#
# Les 10 tailles sont dérivées du même fichier : le motif doit rester lisible
# à 16 pt (Finder en liste), pas seulement à 1024.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIT=false
if [[ "${1:-}" == "--fit" ]]; then FIT=true; shift; fi
SRC=${1:-}
APP=${2:-FastPaste}
OUT="$ROOT_DIR/Resources/$APP.icns"

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "usage: $0 [--fit] <icone-1024x1024.png> [NomDeLApp]" >&2
    exit 1
fi

DIMS=$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel/ {print $2}' | paste -sd× -)
[[ "$DIMS" == "1024×1024" ]] || echo "⚠️  source en $DIMS — 1024×1024 attendu, le rendu sera mou."

TMP=$(mktemp -d)
ART="$SRC"

if $FIT; then
    # sips ne sait pas composer en gardant la transparence : on passe par
    # AppKit, quelques lignes suffisent.
    cat > "$TMP/fit.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let data = NSData(contentsOfFile: args[1]),
      let rep = NSBitmapImageRep(data: data as Data) else { exit(1) }

// La boîte réellement dessinée : une source arrive avec sa propre marge, qu'on
// ne peut pas deviner. Seuil bas pour englober l'ombre portée.
let w = rep.pixelsWide, h = rep.pixelsHigh
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX else { exit(1) }
let boxW = CGFloat(maxX - minX + 1), boxH = CGFloat(maxY - minY + 1)

let canvas: CGFloat = 1024
let target: CGFloat = 814          // relevé sur les apps d'Apple
let scale = target / max(boxW, boxH)

// Le repère de NSImage part du bas : la marge haute mesurée devient l'offset bas.
let src = NSImage(size: NSSize(width: CGFloat(w), height: CGFloat(h)))
src.addRepresentation(rep)
let drawn = NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
let boxCenterX = (CGFloat(minX) + boxW / 2) * scale
let boxCenterY = (CGFloat(h) - (CGFloat(minY) + boxH / 2)) * scale

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(x: canvas / 2 - boxCenterX, y: canvas / 2 - boxCenterY,
                    width: drawn.width, height: drawn.height))
out.unlockFocus()
guard let tiff = out.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
print("  forme ramenée de \(Int(max(boxW, boxH))) à \(Int(target)) px dans 1024")
SWIFT
    swift "$TMP/fit.swift" "$SRC" "$TMP/fitted.png"
    ART="$TMP/fitted.png"
    echo "Recalé sur la grille Apple (814 dans 1024)."
fi

WORK="$TMP/$APP.iconset"
mkdir -p "$WORK"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE             "$ART" --out "$WORK/icon_${SIZE}x${SIZE}.png"    >/dev/null
    sips -z $((SIZE*2)) $((SIZE*2)) "$ART" --out "$WORK/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$WORK" -o "$OUT"
rm -rf "$TMP"
echo "Créé : $OUT"
echo "→ ./scripts/package_$(echo "$APP" | tr '[:upper:]' '[:lower:]').sh pour refaire le .dmg avec l'icône."
