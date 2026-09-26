import Foundation

/// Sauvegarde de l'état dans ~/Library/Application Support/ScreenBlur/zones.json.
/// Écriture atomique, et surtout : un fichier illisible n'est JAMAIS remplacé par un état
/// vide. Perdre ses zones sans le voir serait pire que l'erreur affichée.
final class ScreenBlurStore {
    private let fileURL: URL
    private(set) var state: ScreenBlurState
    private(set) var error: String?

    init(root: URL) {
        fileURL = root.appendingPathComponent("zones.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Uniquement pour l'emplacement réel : un dossier de test doit rester vierge.
        if root.standardizedFileURL == Self.defaultRoot.standardizedFileURL {
            Self.adoptLegacyFile(into: fileURL)
        }
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(ScreenBlurState.self, from: data) {
                state = decoded
            } else {
                state = ScreenBlurState()
                error = "Le fichier zones.json est illisible ; il n'est pas écrasé."
            }
        } else {
            state = ScreenBlurState()
        }
    }

    /// L'application s'est appelée « Flou » avant sa sortie en dépôt. Si ses zones sont encore
    /// là et que les nouvelles n'existent pas, on les reprend une fois : personne ne devrait
    /// redessiner ses zones parce que l'app a changé de nom.
    private static func adoptLegacyFile(into destination: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { return }
        let legacy = manager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flou/zones.json")
        guard manager.fileExists(atPath: legacy.path) else { return }
        try? manager.copyItem(at: legacy, to: destination)
    }

    static var defaultRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenBlur", isDirectory: true)
    }

    /// Applique une modification et l'écrit. Renvoie faux si rien n'a pu être enregistré.
    @discardableResult
    func update(_ mutate: (inout ScreenBlurState) -> Void) -> Bool {
        guard error == nil else { return false }
        var next = state
        mutate(&next)
        guard next != state else { return true }
        state = next
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            self.error = "Enregistrement impossible : \(error.localizedDescription)"
            return false
        }
    }
}
