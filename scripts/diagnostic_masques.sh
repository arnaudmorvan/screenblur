#!/usr/bin/env bash
# Journalise l'état des masques de ScreenBlur et les grandes fenêtres présentes, pour
# comprendre pourquoi un masque disparaît. Aucune autorisation nécessaire.
#
#   ./scripts/diagnostic_masques.sh            # 60 s
#   ./scripts/diagnostic_masques.sh 180        # 3 min
#
# Lancez-le, puis reproduisez le problème (démarrez votre enregistrement, changez
# d'application…). Chaque CHANGEMENT d'état est daté. Le journal s'écrit aussi dans
# /tmp/screenblur-masques.log.
set -euo pipefail
cd "$(dirname "$0")/.."
DUREE=${1:-60}
mkdir -p .build/diag-cache
cat > .build/diag-masques.swift <<SWIFT
import AppKit

MainActor.assumeIsolated {
    let duree = Double($DUREE)
    let debut = Date()
    var precedent = ""
    print("observation pendant \(Int(duree)) s — reproduisez le problème maintenant\n")
    while Date().timeIntervalSince(debut) < duree {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var masques: [String] = []
        var grandes: [String] = []
        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let niveau = info[kCGWindowLayer as String] as? Int ?? 0
            let b = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
            let taille = "\(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0))@\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0))"
            if owner == "ScreenBlur" {
                masques.append("couche \(niveau) alpha \(String(format: "%.1f", alpha)) \(taille)")
            } else if (b["Width"] ?? 0) >= 600, (b["Height"] ?? 0) >= 400 {
                grandes.append("\(owner) c\(niveau) a\(String(format: "%.1f", alpha)) \(taille)")
            }
        }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "design.axolo.screenblur").first
        let ecrans = NSScreen.screens.map { "\(Int(\$0.frame.width))×\(Int(\$0.frame.height))" }.joined(separator: " + ")
        let etat = """
        masques : \(masques.isEmpty ? "AUCUN" : masques.joined(separator: " | "))
            app masquée : \(app?.isHidden ?? false) — écrans : \(ecrans)
            grandes fenêtres : \(grandes.isEmpty ? "aucune" : grandes.joined(separator: " ; "))
        """
        if etat != precedent {
            print(String(format: "%6.1fs  %@", Date().timeIntervalSince(debut), etat))
            precedent = etat
        }
        usleep(300_000)
    }
    print("\nfin de l'observation")
}
SWIFT
swiftc -module-cache-path .build/diag-cache .build/diag-masques.swift -o .build/diag-masques
.build/diag-masques | tee /tmp/screenblur-masques.log
echo
echo "Journal gardé dans /tmp/screenblur-masques.log"
