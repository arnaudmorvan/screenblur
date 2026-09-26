import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// Relit l'écran et redessine chaque zone floutée ou pixelisée. Sert les styles « ScreenBlur
/// réglable » et « Mosaïque » ; les deux autres styles n'ont pas besoin de ce moteur et ne
/// déclenchent donc aucune demande d'autorisation.
final class CaptureBlurEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Trames par seconde. Un fond flouté n'a pas besoin de 60 images : douze suffisent pour
    /// que le masque suive ce qui bouge dessous, à coût presque nul.
    private static let framesPerSecond: Int32 = 12

    private let queue = DispatchQueue(label: "design.axolo.screenblur.capture")
    private let renderer = ZoneRenderer()
    private let lock = NSLock()

    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var zonesByDisplay: [CGDirectDisplayID: [Zone]] = [:]
    private var style: MaskStyle = .flou
    private var intensity: Intensity = .forte
    private var pending = 0

    /// Livraison d'une zone rendue, toujours sur le fil principal.
    var deliver: ((UUID, CGImage) -> Void)?
    /// Échec irrécupérable : autorisation refusée, flux interrompu. L'appelant retombe alors
    /// sur le verre dépoli plutôt que de laisser une zone découverte.
    var failed: ((String) -> Void)?

    // MARK: - Réglages

    func settings(style: MaskStyle, intensity: Intensity) {
        lock.lock()
        self.style = style
        self.intensity = intensity
        lock.unlock()
    }

    /// Les zones à rendre, groupées par écran. Changer de zone ne redémarre pas un flux :
    /// seule la liste des écrans concernés le fait.
    func update(zones: [Zone], screens: [String: CGDirectDisplayID]) {
        var grouped: [CGDirectDisplayID: [Zone]] = [:]
        for zone in zones {
            guard let id = screens[zone.displayUUID] else { continue }
            grouped[id, default: []].append(zone)
        }
        lock.lock()
        zonesByDisplay = grouped
        lock.unlock()

        let wanted = Set(grouped.keys)
        for (id, stream) in streams where !wanted.contains(id) {
            stream.stopCapture { _ in }
            streams[id] = nil
        }
        for id in wanted where streams[id] == nil {
            start(display: id)
        }
    }

    func stop() {
        for (_, stream) in streams { stream.stopCapture { _ in } }
        streams.removeAll()
        lock.lock()
        zonesByDisplay.removeAll()
        lock.unlock()
    }

    // MARK: - Flux

    private func start(display id: CGDirectDisplayID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == id }) else { return }

                // Exclure ScreenBlur de sa propre capture, par PID et non par identifiant de paquet :
                // sans cela le moteur recapturerait ses masques et flouterait du flou, indéfiniment.
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

                let config = SCStreamConfiguration()
                // Un point par pixel : sur un écran Retina c'est déjà une réduction de moitié,
                // gratuite en netteté puisque l'image finit floutée.
                config.width = display.width
                config.height = display.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
                config.queueDepth = 3
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.scalesToFit = true

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                await MainActor.run { self.streams[id] = stream }
            } catch {
                // Autorisation manquante ou flux refusé : la demande système ne prend effet
                // qu'au prochain lancement, autant le dire plutôt que de réessayer en boucle.
                CGRequestScreenCaptureAccess()
                await MainActor.run {
                    self.failed?("La relecture de l'écran a échoué : \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Rendu

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Une trame « idle » signifie que rien n'a changé : garder l'image précédente.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }

        lock.lock()
        let displayID = streams.first(where: { $0.value === stream })?.key
        let zones = displayID.flatMap { zonesByDisplay[$0] } ?? []
        let style = self.style
        let intensity = self.intensity
        let busy = pending > 1
        lock.unlock()

        // Le fil principal a déjà deux images en attente : sauter celle-ci plutôt que
        // d'engorger l'interface.
        guard !zones.isEmpty, !busy, style.needsScreenRecording else { return }

        let source = renderer.source(from: buffer)
        let size = source.extent.size

        for zone in zones {
            let crop = Geometry.cropRect(zone.rect, imageSize: size).integral
            guard let image = renderer.render(source: source, crop: crop,
                                              style: style, intensity: intensity) else { continue }
            lock.lock(); pending += 1; lock.unlock()
            let id = zone.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliver?(id, image)
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let id = self.streams.first(where: { $0.value === stream })?.key {
                self.streams[id] = nil
            }
            self.failed?("La relecture de l'écran s'est interrompue : \(error.localizedDescription)")
        }
    }
}
