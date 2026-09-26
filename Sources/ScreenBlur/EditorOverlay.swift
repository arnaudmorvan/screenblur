import AppKit

/// Une zone telle que l'éditeur la manipule : un cadre en coordonnées d'écran globales, et le
/// nom de l'application à laquelle elle est attachée, s'il y en a une. L'éditeur ignore comment
/// le cadre est mémorisé — c'est le contrôleur qui le sait.
struct EditorZone: Equatable {
    let id: UUID
    let frame: CGRect
    let label: String?
}

/// Les vues d'édition vivent sur le fil principal : la conformité y est isolée aussi.
@MainActor
protocol EditorOverlayDelegate: AnyObject {
    func editorDidCreate(frame: CGRect, onDisplay uuid: String)
    func editorDidMove(zone id: UUID, toFrame frame: CGRect)
    func editorDidDelete(zone id: UUID)
    func editorDidFinish()
}

/// Les huit poignées d'un cadre.
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Applique le déplacement d'une poignée au cadre, en gardant les bords opposés fixes.
    func resize(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var r = rect
        switch self {
        case .topLeft: r.origin.x += delta.width; r.size.width -= delta.width; r.size.height += delta.height
        case .top: r.size.height += delta.height
        case .topRight: r.size.width += delta.width; r.size.height += delta.height
        case .right: r.size.width += delta.width
        case .bottomRight: r.size.width += delta.width; r.origin.y += delta.height; r.size.height -= delta.height
        case .bottom: r.origin.y += delta.height; r.size.height -= delta.height
        case .bottomLeft: r.origin.x += delta.width; r.size.width -= delta.width
                          r.origin.y += delta.height; r.size.height -= delta.height
        case .left: r.origin.x += delta.width; r.size.width -= delta.width
        }
        // Un cadre retourné par un geste trop ample est remis d'aplomb, pas jeté.
        return CGRect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
                      width: max(abs(r.width), 24), height: max(abs(r.height), 24))
    }
}

/// La surface d'édition d'un écran : cliquer-glisser dans le vide crée une zone, dans une zone
/// la déplace, sur une poignée la redimensionne.
final class EditorView: NSView {
    private enum Drag {
        case none
        case creating(start: CGPoint, current: CGPoint)
        case moving(id: UUID, origin: CGRect, start: CGPoint)
        case resizing(id: UUID, handle: Handle, origin: CGRect, start: CGPoint)
    }

    private static let handleSide: CGFloat = 12

    weak var delegate: EditorOverlayDelegate?
    let displayUUID: String
    private let screenOrigin: CGPoint
    private var zones: [EditorZone] = []
    private var selected: UUID?
    private var drag: Drag = .none

    init(displayUUID: String, screenOrigin: CGPoint) {
        self.displayUUID = displayUUID
        self.screenOrigin = screenOrigin
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) inutilisé") }

    func update(zones: [EditorZone]) {
        self.zones = zones
        if let selected, !zones.contains(where: { $0.id == selected }) { self.selected = nil }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Géométrie locale

    private var localFrame: CGRect { CGRect(origin: .zero, size: bounds.size) }

    private func rect(of zone: EditorZone) -> CGRect {
        zone.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    /// De la vue vers l'écran : c'est le contrôleur qui décide ensuite comment mémoriser ce cadre.
    private func global(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
    }

    private func hitHandle(at point: CGPoint) -> (UUID, Handle)? {
        // La zone sélectionnée d'abord : ses poignées ont la priorité sur celles d'une voisine.
        let ordered = zones.sorted { a, _ in a.id == selected }
        for zone in ordered {
            let frame = rect(of: zone)
            for handle in Handle.allCases {
                let center = handle.point(in: frame)
                let box = CGRect(x: center.x - Self.handleSide, y: center.y - Self.handleSide,
                                 width: Self.handleSide * 2, height: Self.handleSide * 2)
                if box.contains(point) { return (zone.id, handle) }
            }
        }
        return nil
    }

    private func hitZone(at point: CGPoint) -> EditorZone? {
        // La dernière créée est au-dessus : on la teste en premier.
        zones.reversed().first { rect(of: $0).contains(point) }
    }

    // MARK: - Souris

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, handle) = hitHandle(at: point), let zone = zones.first(where: { $0.id == id }) {
            selected = id
            drag = .resizing(id: id, handle: handle, origin: rect(of: zone), start: point)
        } else if let zone = hitZone(at: point) {
            selected = zone.id
            drag = .moving(id: zone.id, origin: rect(of: zone), start: point)
        } else {
            selected = nil
            drag = .creating(start: point, current: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .creating(let start, _):
            drag = .creating(start: start, current: point)
        case .moving(let id, let origin, let start):
            let moved = origin.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            delegate?.editorDidMove(zone: id, toFrame: global(moved))
            drag = .moving(id: id, origin: origin, start: start)
        case .resizing(let id, let handle, let origin, let start):
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            delegate?.editorDidMove(zone: id, toFrame: global(handle.resize(origin, by: delta)))
            drag = .resizing(id: id, handle: handle, origin: origin, start: start)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating(let start, let current) = drag {
            let candidate = Geometry.rect(from: start, to: current, in: localFrame)
            // Un simple clic n'est pas une zone : sans ce garde-fou, chaque clic hors zone
            // en déposerait une, minuscule et introuvable.
            if !Geometry.isNegligible(candidate) {
                let frame = Geometry.denormalize(Geometry.clamp(candidate), in: localFrame)
                delegate?.editorDidCreate(frame: global(frame), onDisplay: displayUUID)
            }
        }
        drag = .none
        needsDisplay = true
    }

    // MARK: - Clavier

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: // Échap, Entrée, Entrée du pavé numérique
            delegate?.editorDidFinish()
        case 51, 117: // Retour arrière, Suppr.
            if let selected { delegate?.editorDidDelete(zone: selected) }
        case 123, 124, 125, 126: // Flèches
            nudge(keyCode: event.keyCode, fast: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(keyCode: UInt16, fast: Bool) {
        guard let selected, let zone = zones.first(where: { $0.id == selected }) else { return }
        let step: CGFloat = fast ? 10 : 1
        var frame = rect(of: zone)
        switch keyCode {
        case 123: frame.origin.x -= step
        case 124: frame.origin.x += step
        case 125: frame.origin.y -= step
        case 126: frame.origin.y += step
        default: break
        }
        delegate?.editorDidMove(zone: selected, toFrame: global(frame))
    }

    // MARK: - Dessin

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        for zone in zones { addCursorRect(rect(of: zone), cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Un voile léger : il signale le mode édition sans travestir le rendu des masques,
        // qui restent visibles dessous.
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()

        let accent = NSColor.controlAccentColor
        for zone in zones {
            let frame = rect(of: zone)
            let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            (zone.id == selected ? accent : NSColor.white.withAlphaComponent(0.55)).setStroke()
            path.lineWidth = zone.id == selected ? 2.5 : 1.5
            path.stroke()
            drawSize(of: frame, label: zone.label)
            if zone.id == selected { drawHandles(in: frame) }
        }

        if case .creating(let start, let current) = drag {
            let frame = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                               width: abs(current.x - start.x), height: abs(current.y - start.y))
            let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            path.setLineDash([6, 4], count: 2, phase: 0)
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
            accent.withAlphaComponent(0.12).setFill()
            frame.fill()
            drawSize(of: frame)
        }

        drawHint()
    }

    private func drawHandles(in frame: CGRect) {
        for handle in Handle.allCases {
            let center = handle.point(in: frame)
            let box = CGRect(x: center.x - Self.handleSide / 2, y: center.y - Self.handleSide / 2,
                             width: Self.handleSide, height: Self.handleSide)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).stroke()
        }
    }

    private func drawSize(of frame: CGRect, label: String? = nil) {
        guard frame.width > 60, frame.height > 30 else { return }
        var text = "\(Int(frame.width)) × \(Int(frame.height))"
        // Une zone attachée dit à quoi : sans cela, rien ne la distingue d'une zone fixe.
        if let label { text = "\(label)   ·   " + text }
        draw(label: text, centeredAt: CGPoint(x: frame.midX, y: frame.midY), fontSize: 13)
    }

    private func drawHint() {
        let text = "Glisser pour créer une zone   ·   déplacer et redimensionner   ·   ⌫ supprimer   ·   ⏎ terminer"
        draw(label: text, centeredAt: CGPoint(x: bounds.midX, y: 64), fontSize: 14)
    }

    private func draw(label: String, centeredAt center: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 12, y: center.y - size.height / 2 - 7,
                         width: size.width + 24, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

/// La fenêtre d'édition d'un écran. Elle doit pouvoir devenir fenêtre clé, sinon Échap et
/// Suppr. ne lui parviennent jamais.
final class EditorWindow: NSPanel {
    let view: EditorView

    init(screen: NSScreen, displayUUID: String, delegate: EditorOverlayDelegate) {
        view = EditorView(displayUUID: displayUUID, screenOrigin: screen.frame.origin)
        view.delegate = delegate
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Juste au-dessus des masques, pour dessiner les cadres par-dessus le flou.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // L'éditeur, lui, n'a rien à faire dans un partage d'écran.
        sharingType = .none
        setFrame(screen.frame, display: false)
        contentView = view
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
    }

    override var canBecomeKey: Bool { true }
}
