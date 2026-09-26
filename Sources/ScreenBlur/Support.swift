import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Identité stable de l'écran. Le numéro d'affichage change d'un branchement à l'autre,
    /// l'UUID non : c'est lui qu'on mémorise avec la zone.
    var stableIdentifier: String? {
        guard let id = displayID else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Nom lisible dans le menu : « Écran intégré », « Studio Display »…
    var shortName: String { localizedName }

    static func screen(withIdentifier uuid: String) -> NSScreen? {
        screens.first { $0.stableIdentifier == uuid }
    }
}

enum Alerts {
    @MainActor
    static func inform(_ message: String, detail: String, button: String = "D'accord") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Autorisation refusée : mieux vaut ouvrir directement le bon panneau des réglages que
    /// décrire un chemin que personne ne suit.
    @MainActor
    static func askScreenRecording(detail: String) {
        let alert = NSAlert()
        alert.messageText = "ScreenBlur a besoin de l'autorisation d'enregistrement de l'écran"
        alert.informativeText = detail
        alert.addButton(withTitle: "Ouvrir les réglages")
        alert.addButton(withTitle: "Utiliser le verre dépoli")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
