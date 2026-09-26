#!/usr/bin/env bash
set -euo pipefail
# Tests unitaires : un exécutable autonome, pas de XCTest (pas d'Xcode sur la machine).
cd "$(dirname "$0")/.."
mkdir -p .build/test-cache
swiftc -module-cache-path .build/test-cache \
    Sources/ScreenBlur/Geometry.swift Sources/ScreenBlur/Models.swift \
    Sources/ScreenBlur/ScreenBlurStore.swift Sources/ScreenBlur/ZoneRenderer.swift \
    Sources/ScreenBlur/EditorOverlay.swift Sources/ScreenBlur/MaskWindow.swift \
    Tests/ScreenBlurTests/CoreTests.swift \
    -o .build/screenblur-tests
.build/screenblur-tests
