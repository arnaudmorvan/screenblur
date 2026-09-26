#!/usr/bin/env bash
# Montre ce que Flou voit des fenêtres d'une application : son cadre, ses recouvrements.
# Sert quand une zone refuse de se rattacher, ou qu'un masque n'apparaît pas.
#   ./scripts/diagnostic_suivi.sh com.anthropic.claudefordesktop com.apple.finder
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/suivi-cache
cat > .build/suivi-main.swift <<'SWIFT'
import AppKit

@main
struct DiagnosticSuivi {
    @MainActor
    static func main() {
        let demandes = Array(CommandLine.arguments.dropFirst())
        let bundleIDs = demandes.isEmpty
            ? NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
            : demandes
        let tracker = AppWindowTracker()
        for bundleID in bundleIDs {
            let nom = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            let fenetres = tracker.snapshot(of: [bundleID])
            guard let premiere = fenetres.first else {
                print("\(nom ?? bundleID) [\(bundleID)] : aucune fenêtre à l'écran — impossible d'y rattacher une zone")
                continue
            }
            let recouvert = Geometry.isFullyCovered(premiere.frame, by: premiere.holes)
            print("\(nom ?? bundleID) [\(bundleID)] : \(fenetres.count) fenêtre(s)")
            for fenetre in fenetres {
                let etat = Geometry.isFullyCovered(fenetre.frame, by: fenetre.holes)
                    ? "entièrement derrière une autre fenêtre : aucun masque posé"
                    : "\(fenetre.holes.count) recouvrement(s) percé(s) dans le masque"
                print("   cadre \(fenetre.frame) — \(etat)")
            }
            if recouvert {
                print("   → une zone peut quand même y être rattachée ; elle apparaîtra dès que la fenêtre sera visible")
            }
        }
    }
}
SWIFT
swiftc -module-cache-path .build/suivi-cache \
    Sources/ScreenBlur/Geometry.swift Sources/ScreenBlur/Models.swift Sources/ScreenBlur/AppWindowTracker.swift \
    .build/suivi-main.swift -o .build/diagnostic-suivi
.build/diagnostic-suivi "$@"
