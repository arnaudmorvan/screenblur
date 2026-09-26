import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// « Est-ce que mes masques passent vraiment à l'antenne ? » — la seule réponse qui vaille est
/// une image de l'écran composé, prise par le même chemin qu'une visioconférence qui partage
/// l'écran entier. Ici, et contrairement au moteur de flou, on n'exclut RIEN : l'aperçu doit
/// montrer les masques, puisque c'est ce qu'on vérifie.
@MainActor
enum SharePreview {
    enum Failure: LocalizedError {
        case noScreen
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .noScreen: return "Écran introuvable."
            case .refused(let reason):
                return "La relecture de l'écran a été refusée : \(reason)"
            }
        }
    }

    /// Capture un écran tel qu'un partage d'écran le verrait, et renvoie le PNG écrit sur disque.
    static func capture(screen: NSScreen, to url: URL) async throws -> URL {
        // Ne pas présumer de l'autorisation : CGPreflightScreenCaptureAccess() répond non dans
        // des cas où la capture fonctionne. ScreenCaptureKit est la seule autorité — sa première
        // tentative déclenche aussi la demande système.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            CGRequestScreenCaptureAccess()
            throw Failure.refused(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw Failure.noScreen
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.noScreen
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func temporaryURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screenblur-apercu-\(stamp).png")
    }
}
