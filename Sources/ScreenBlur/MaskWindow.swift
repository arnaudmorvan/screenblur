import AppKit

/// La couche qui dessine tout ce qui n'est pas le verre du système : la teinte, l'aplat,
/// l'image recapturée et le liseré — le tout DÉCOUPÉ à la forme du masque.
///
/// Le découpage se fait au dessin, pas par un calque de masque : `layer.mask` posé sur une vue
/// gérée par AppKit ne découpe rien ici (mesuré — les trous restaient bouchés), alors qu'un
/// `addClip()` sur le chemin est le comportement de base de Cocoa.
private final class MaskOverlayView: NSView {
    /// Les parties à peindre, en coordonnées de la vue. Le contrôleur les calcule déjà pour
    /// savoir s'il reste quelque chose à montrer : les recalculer ici serait du travail en
    /// double, trente fois par seconde.
    var visible: [CGRect] = [] { didSet { if visible != oldValue { needsDisplay = true } } }
    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var image: CGImage? { didSet { needsDisplay = true } }
    var smooth = true
    var border = NSColor.white.withAlphaComponent(0.16)

    var cornerRadius: CGFloat { min(12, min(bounds.width, bounds.height) * 0.2) }

    override func draw(_ dirtyRect: NSRect) {
        guard !visible.isEmpty else { return }
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        // Deux découpes successives se croisent : le coin arrondi d'abord, les parties
        // réellement visibles ensuite.
        rounded.addClip()
        if visible != [bounds] {
            let path = NSBezierPath()
            for rect in visible { path.appendRect(rect) }
            path.addClip()
        }
        if let image {
            // Sans lissage, les gros pixels de la mosaïque restent des carrés nets.
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        }
        if let fill {
            fill.setFill()
            bounds.fill()
        }
        border.setStroke()
        rounded.lineWidth = 2
        rounded.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Le contenu d'un masque : le verre du système, et par-dessus la couche dessinée.
final class MaskContentView: NSView {
    private let glass = NSVisualEffectView()
    private let overlay = MaskOverlayView()
    private var visible: [CGRect] = []
    private var style: MaskStyle = .verre
    private var intensity: Intensity = .forte
    /// Fenêtre cachée derrière une autre : plus rien à peindre, mais le masque reste EN PLACE,
    /// prêt. Le détruire obligerait à en recréer un quand la fenêtre revient devant, et son
    /// contenu s'afficherait pendant ce temps-là.
    private var dormant = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        // .active : le flou reste calculé même quand ScreenBlur n'est pas l'application active —
        // sans cela le masque se lèverait dès qu'on retourne travailler.
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.material = .hudWindow
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) inutilisé") }

    func apply(style: MaskStyle, intensity: Intensity) {
        guard style != self.style || intensity != self.intensity else { return }
        self.style = style
        self.intensity = intensity
        switch style {
        case .verre:
            glass.isHidden = false
            overlay.image = nil
            overlay.fill = intensity.tintAlpha == 0 ? nil : NSColor.black.withAlphaComponent(intensity.tintAlpha)
        case .flou, .mosaique:
            // Le verre reste visible sous l'image : tant que la première trame n'est pas
            // arrivée, la zone est déjà floutée. À aucun moment elle ne montre le contenu.
            glass.isHidden = false
            overlay.fill = nil
            overlay.smooth = style != .mosaique
        case .opaque:
            glass.isHidden = true
            overlay.image = nil
            overlay.fill = NSColor(calibratedWhite: 0.11, alpha: 1)
        }
        overlay.border = NSColor.white.withAlphaComponent(style == .opaque ? 0.10 : 0.16)
        updateVisibility()
    }

    func show(image: CGImage) {
        overlay.image = image
    }

    func clearImage() {
        overlay.image = nil
    }

    /// Les parties du masque à peindre, en coordonnées de la vue. Vide = la fenêtre couverte
    /// est entièrement cachée : on s'endort sans disparaître.
    func setVisible(_ rects: [CGRect]) {
        guard rects != visible else { return }
        visible = rects
        overlay.visible = rects
        applyGlassMask()
        updateVisibility()
    }

    private func updateVisibility() {
        dormant = visible.isEmpty
        // Le verre coûte un flou au WindowServer : l'éteindre quand il n'y a rien à montrer.
        glass.isHidden = dormant || style == .opaque
        overlay.isHidden = dormant
    }

    private func applyGlassMask() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let frame = CGRect(origin: .zero, size: size)
        guard visible != [frame], !visible.isEmpty else {
            glass.maskImage = nil
            return
        }
        let radius = overlay.cornerRadius
        let parts = visible
        glass.maskImage = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
            NSColor.black.setFill()
            for rect in parts { rect.fill() }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    override func layout() {
        super.layout()
        // Un coin arrondi dit « c'est voulu » ; sur une zone étroite il doit s'effacer.
        layer?.cornerRadius = overlay.cornerRadius
        // Le masque du verre dépend de la taille : le refaire au changement de cadre.
        applyGlassMask()
    }
}

/// La fenêtre qui couvre la zone. Tout ce qui compte pour le partage d'écran est ici.
final class MaskWindow: NSPanel {
    let zoneID: UUID
    private let content = MaskContentView(frame: .zero)

    init(zoneID: UUID) {
        self.zoneID = zoneID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Au-dessus de tout, y compris des applications en plein écran : un masque qui passe
        // derrière une fenêtre ne masque plus rien.
        level = .screenSaver
        // Présent sur tous les bureaux et immobile : changer d'espace ne découvre pas la zone.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // LE point crucial de cette application : .readOnly laisse la fenêtre entrer dans la
        // capture d'écran. En .none elle serait absente de Zoom, Meet ou Teams — c'est-à-dire
        // que le contenu dessous passerait à l'antenne, masque posé et aucun avertissement.
        // .readWrite est déprécié depuis macOS 15 et vaut désormais .readOnly ; autant l'écrire.
        // À ne pas diagnostiquer avec kCGWindowSharingState : sur macOS 26 ce champ vaut 0 pour
        // presque toutes les fenêtres du système, y compris celles qui se partagent très bien.
        // La seule preuve est une image : voir SharePreview et « Aperçu de ce que voient les autres ».
        sharingType = .readOnly
        // Clics traversants : on continue de travailler sous le masque.
        ignoresMouseEvents = true
        contentView = content
    }

    func place(at frame: CGRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
    }

    func apply(style: MaskStyle, intensity: Intensity) {
        content.apply(style: style, intensity: intensity)
    }

    func show(image: CGImage) {
        content.show(image: image)
    }

    func clearImage() {
        content.clearImage()
    }

    func setVisible(_ rects: [CGRect]) {
        content.setVisible(rects)
    }
}
