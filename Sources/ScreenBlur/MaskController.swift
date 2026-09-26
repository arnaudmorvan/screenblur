import AppKit

/// Le chef d'orchestre : il tient les zones fixes, les applications suivies, leurs fenêtres de
/// masque, le moteur de recapture et le mode édition. Toute modification passe par lui et se
/// termine par un refresh().
@MainActor
final class MaskController: EditorOverlayDelegate {
    /// Un masque à poser. Qu'il vienne d'une zone dessinée ou d'une fenêtre suivie, il se décrit
    /// de la même façon — c'est ce qui permet aux deux de partager tout le reste du chemin.
    private struct PlannedMask {
        let id: UUID
        let frame: CGRect
        let screen: NSScreen
        let holes: [CGRect]
        /// D'où vient ce masque : une zone dessinée, ou l'application suivie qu'il couvre.
        let origin: String
        /// La zone dont il découle, s'il y en a une : c'est par là que l'éditeur le retrouve.
        let source: UUID?
    }

    let store: ScreenBlurStore
    private var windows: [UUID: MaskWindow] = [:]
    private var editors: [EditorWindow] = []
    private let engine = CaptureBlurEngine()
    private let tracker = AppWindowTracker()
    /// Identité stable d'un masque de fenêtre, pour ne pas recréer la fenêtre à chaque relevé.
    private var appMaskIDs: [CGWindowID: UUID] = [:]
    /// Idem pour une zone attachée : une identité par couple (zone, fenêtre).
    private var scopedMaskIDs: [String: UUID] = [:]
    /// Dernier emplacement connu de chaque zone, en coordonnées d'écran. Sert à détacher une
    /// zone dont l'application vient d'être fermée sans la faire disparaître.
    private var lastPlacement: [UUID: CGRect] = [:]
    private var trackedWindows: [TrackedWindow] = []

    private(set) var isHidden = false
    private(set) var isEditing = false

    /// Appelé après tout changement, pour que la barre des menus reflète l'état.
    var onChange: (() -> Void)?

    init(store: ScreenBlurStore) {
        self.store = store
        engine.deliver = { [weak self] id, image in
            self?.windows[id]?.show(image: image)
        }
        engine.failed = { [weak self] message in
            self?.fallBackToGlass(because: message)
        }
        tracker.onChange = { [weak self] windows in
            self?.trackedWindows = windows
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    var state: ScreenBlurState { store.state }

    /// Les zones dessinées dont l'écran est effectivement branché. Les autres restent en réserve.
    var activeZones: [Zone] {
        let connected = Set(NSScreen.screens.compactMap(\.stableIdentifier))
        return store.state.zones.filter { connected.contains($0.displayUUID) }
    }

    /// Les fenêtres actuellement masquées au titre d'une application suivie.
    var maskedWindowCount: Int { trackedWindows.count }

    var hasSomethingToMask: Bool { !activeZones.isEmpty || !trackedWindows.isEmpty }

    /// L'écran qui porte le plus de masques : celui qu'on a envie de vérifier en aperçu.
    var busiestScreen: NSScreen? {
        var tally: [String: Int] = [:]
        for zone in activeZones { tally[zone.displayUUID, default: 0] += 1 }
        for window in trackedWindows {
            guard let uuid = bestScreen(for: window.frame)?.stableIdentifier else { continue }
            tally[uuid, default: 0] += 1
        }
        if let best = tally.max(by: { $0.value < $1.value })?.key,
           let screen = NSScreen.screen(withIdentifier: best) {
            return screen
        }
        return NSScreen.main
    }

    // MARK: - Cycle d'affichage

    @objc private func screensChanged() {
        // Résolution, agencement, écran débranché : les cadres normalisés se reposent seuls.
        refresh()
        pushToEditors()
    }

    /// Le plan des masques à poser, les deux sources confondues.
    private func plan(screens: [String: NSScreen]) -> [PlannedMask] {
        var planned: [PlannedMask] = []

        for zone in store.state.zones {
            switch zone.scope {
            case .everywhere:
                guard let screen = screens[zone.displayUUID] else { continue }
                planned.append(PlannedMask(id: zone.id,
                                           frame: Geometry.denormalize(zone.rect, in: screen.frame),
                                           screen: screen,
                                           holes: [],
                                           origin: "zone",
                                           source: zone.id))

            case .app(let bundleID, let name):
                // Le cadre de la zone est exprimé DANS la fenêtre : il la suit, et se répète
                // sur chacune de ses fenêtres — le même bout d'interface s'y trouve.
                for window in trackedWindows where window.bundleID == bundleID {
                    let frame = Geometry.denormalize(zone.rect, in: window.frame)
                    guard let screen = bestScreen(for: frame) else { continue }
                    let key = "\(zone.id)-\(window.id)"
                    let id = scopedMaskIDs[key] ?? {
                        let created = UUID()
                        scopedMaskIDs[key] = created
                        return created
                    }()
                    planned.append(PlannedMask(id: id, frame: frame, screen: screen,
                                               holes: Geometry.holes(in: frame, coveredBy: window.holes),
                                               origin: "zone sur \(name)",
                                               source: zone.id))
                }
            }
        }

        // Les applications masquées en entier.
        let whole = store.state.targetedWholeApps
        for window in trackedWindows where whole.contains(window.bundleID) {
            guard let screen = bestScreen(for: window.frame) else { continue }
            let id = appMaskIDs[window.id] ?? {
                let created = UUID()
                appMaskIDs[window.id] = created
                return created
            }()
            planned.append(PlannedMask(id: id, frame: window.frame, screen: screen,
                                       holes: window.holes, origin: window.bundleID, source: nil))
        }

        let live = Set(trackedWindows.map(\.id))
        appMaskIDs = appMaskIDs.filter { live.contains($0.key) }
        let liveKeys = Set(planned.compactMap { mask -> String? in
            guard mask.source != nil else { return nil }
            return scopedMaskIDs.first { $0.value == mask.id }?.key
        })
        scopedMaskIDs = scopedMaskIDs.filter { liveKeys.contains($0.key) }
        return planned
    }

    /// L'écran qui porte le plus de la fenêtre. Une fenêtre à cheval est rattachée au principal
    /// de ses écrans ; son masque, lui, couvre bien toute sa largeur.
    private func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.frame.intersection(frame)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { a, b in a.1.width * a.1.height < b.1.width * b.1.height }?.0
    }

    func refresh() {
        let state = store.state
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            guard let id = screen.stableIdentifier else { return nil }
            return (id, screen)
        })

        let planned = plan(screens: screens)
        var alive = Set<UUID>()
        var renderTargets: [Zone] = []

        for mask in planned {
            alive.insert(mask.id)
            let window = windows[mask.id] ?? {
                let created = MaskWindow(zoneID: mask.id)
                windows[mask.id] = created
                return created
            }()
            window.place(at: mask.frame)
            window.apply(style: state.style, intensity: state.intensity)
            // Les parties visibles se calculent une fois, ici, dans le repère de la fenêtre :
            // la vue les peint telles quelles, et leur absence met le masque en sommeil.
            let local = CGRect(origin: .zero, size: mask.frame.size)
            let holes = mask.holes.map { $0.offsetBy(dx: -mask.frame.minX, dy: -mask.frame.minY) }
            window.setVisible(holes.isEmpty ? [local] : Geometry.visibleRectangles(in: local, holes: holes))
            if isHidden {
                window.orderOut(nil)
            } else {
                // orderFrontRegardless : ScreenBlur n'est pas l'application active, et ne doit
                // surtout pas le devenir pour poser son masque.
                window.orderFrontRegardless()
            }
            if let source = mask.source, lastPlacement[source] == nil || mask.origin == "zone" {
                lastPlacement[source] = mask.frame
            }
            if let uuid = mask.screen.stableIdentifier {
                renderTargets.append(Zone(id: mask.id, displayUUID: uuid,
                                          rect: Geometry.clamp(Geometry.normalize(mask.frame, in: mask.screen.frame))))
            }
        }

        for (id, window) in windows where !alive.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }

        updateEngine(targets: renderTargets, screens: screens.mapValues { $0.displayID ?? 0 })
        onChange?()
    }

    private func updateEngine(targets: [Zone], screens: [String: CGDirectDisplayID]) {
        let state = store.state
        guard state.style.needsScreenRecording, !isHidden, !targets.isEmpty else {
            engine.stop()
            for window in windows.values { window.clearImage() }
            return
        }
        engine.settings(style: state.style, intensity: state.intensity)
        engine.update(zones: targets, screens: screens)
    }

    private func fallBackToGlass(because message: String) {
        guard store.state.style.needsScreenRecording else { return }
        store.update { $0.style = .verre }
        refresh()
        Alerts.askScreenRecording(detail: message + "\n\nEn attendant, les masques utilisent le verre dépoli — rien n'est découvert.")
    }

    /// Ce qui est masqué en ce moment, cadre par cadre, trous compris. Sert au diagnostic
    /// `--apercu` : c'est la seule description fiable, puisqu'elle vient de la pose elle-même
    /// et non d'un relevé des fenêtres refait après coup.
    var maskPlanDescription: [String] {
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            guard let id = screen.stableIdentifier else { return nil }
            return (id, screen)
        })
        return plan(screens: screens).map { mask in
            let holes = mask.holes
                .map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                .joined(separator: " ")
            return "MASQUE \(mask.origin) ECRAN \(mask.screen.localizedName) CADRE \(Int(mask.frame.minX)),\(Int(mask.frame.minY)),\(Int(mask.frame.width)),\(Int(mask.frame.height)) TROUS \(mask.holes.count) \(holes)"
        }
    }

    /// Les fenêtres actuellement suivies, avec leurs recouvrements. Complète le plan des
    /// masques : une zone attachée peut n'avoir aucun masque simplement parce que la partie
    /// qu'elle vise est cachée derrière une autre fenêtre.
    var trackingDescription: [String] {
        let consigne = tracker.currentTargets.sorted().joined(separator: ", ")
        return ["CIBLES \(consigne.isEmpty ? "aucune" : consigne) MINUTEUR \(tracker.isRunning ? "actif" : "arrêté")",
                tracker.rawScanSummary] + windowLines
    }

    private var windowLines: [String] {
        trackedWindows.map { window in
            let holes = window.holes
                .map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                .joined(separator: " ")
            return "SUIVI \(window.bundleID) CADRE \(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width)),\(Int(window.frame.height)) TROUS \(window.holes.count) \(holes)"
        }
    }

    // MARK: - Actions

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        refresh()
    }

    func toggleHidden() {
        setHidden(!isHidden)
    }

    func set(style: MaskStyle) {
        store.update { $0.style = style }
        // Un masque ne doit pas se lever pour changer de style : les fenêtres restent en place.
        refresh()
    }

    func set(intensity: Intensity) {
        store.update { $0.intensity = intensity }
        refresh()
    }

    func delete(zone id: UUID) {
        store.update { $0.zones.removeAll { $0.id == id } }
        refresh()
        pushToEditors()
    }

    func deleteAllZones() {
        store.update { $0.zones.removeAll() }
        refresh()
        pushToEditors()
    }

    // MARK: - Applications masquées

    func toggleApp(bundleID: String, name: String) {
        store.update { state in
            if let index = state.apps.firstIndex(where: { $0.bundleID == bundleID }) {
                state.apps.remove(at: index)
            } else {
                state.apps.append(AppTarget(bundleID: bundleID, name: name))
            }
        }
        syncTracker()
    }

    func unmaskAllApps() {
        store.update { $0.apps.removeAll() }
        syncTracker()
    }

    func isMasked(bundleID: String) -> Bool {
        store.state.apps.contains { $0.bundleID == bundleID }
    }

    /// Le suivi ne tourne que s'il y a quelque chose à suivre.
    func syncTracker() {
        tracker.setTargets(store.state.targetedBundleIDs)
        refresh()
    }

    // MARK: - Édition

    func beginEditing() {
        guard editors.isEmpty else { return }
        setHidden(false)
        isEditing = true
        for screen in NSScreen.screens {
            guard let uuid = screen.stableIdentifier else { continue }
            let editor = EditorWindow(screen: screen, displayUUID: uuid, delegate: self)
            editors.append(editor)
            editor.orderFrontRegardless()
        }
        // Sans activation, l'éditeur ne reçoit ni Échap ni Suppr. : l'app est accessoire,
        // elle n'a pas le focus par défaut.
        NSApp.activate(ignoringOtherApps: true)
        editors.first?.makeKeyAndOrderFront(nil)
        editors.first?.makeFirstResponder(editors.first?.view)
        pushToEditors()
        onChange?()
    }

    func endEditing() {
        for editor in editors { editor.orderOut(nil) }
        editors.removeAll()
        isEditing = false
        NSApp.hide(nil)
        onChange?()
    }

    func toggleEditing() {
        isEditing ? endEditing() : beginEditing()
    }

    private func pushToEditors() {
        guard !editors.isEmpty else { return }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            guard let id = screen.stableIdentifier else { return nil }
            return (id, screen)
        })
        // Une zone est montrée là où elle est POSÉE, pas là où elle est mémorisée : une zone
        // attachée à une application suit sa fenêtre, éventuellement sur un autre écran.
        var byScreen: [String: [EditorZone]] = [:]
        var shown = Set<UUID>()
        for mask in plan(screens: screens) {
            guard let source = mask.source, !shown.contains(source),
                  let zone = store.state.zones.first(where: { $0.id == source }),
                  let uuid = mask.screen.stableIdentifier else { continue }
            // Une zone attachée à une application à plusieurs fenêtres pose plusieurs masques,
            // mais reste UNE zone : l'éditeur n'en montre qu'une, sinon on déplacerait un double.
            shown.insert(source)
            byScreen[uuid, default: []].append(EditorZone(id: zone.id, frame: mask.frame, label: zone.scope.label))
        }
        for editor in editors {
            editor.view.update(zones: byScreen[editor.view.displayUUID] ?? [])
        }
    }

    /// Où une zone est posée en ce moment, en coordonnées d'écran — pour l'affichage du menu.
    func placedFrame(of id: UUID) -> CGRect? {
        guard let zone = store.state.zones.first(where: { $0.id == id }) else { return nil }
        return currentFrame(of: zone)
    }

    /// Où la zone est posée en ce moment, en coordonnées d'écran.
    private func currentFrame(of zone: Zone) -> CGRect? {
        switch zone.scope {
        case .everywhere:
            guard let screen = NSScreen.screen(withIdentifier: zone.displayUUID) else { return lastPlacement[zone.id] }
            return Geometry.denormalize(zone.rect, in: screen.frame)
        case .app(let bundleID, _):
            guard let window = trackedWindows.first(where: { $0.bundleID == bundleID }) else { return lastPlacement[zone.id] }
            return Geometry.denormalize(zone.rect, in: window.frame)
        }
    }

    /// Rattache une zone à une application, ou la détache. Le cadre ne bouge pas à l'écran :
    /// seul son repère de mémorisation change.
    func setScope(zone id: UUID, to scope: ZoneScope) {
        guard let zone = store.state.zones.first(where: { $0.id == id }), zone.scope != scope else { return }
        let placed = currentFrame(of: zone)

        switch scope {
        case .app(let bundleID, let name):
            // Relevé ponctuel : l'application n'est pas encore suivie, puisque c'est
            // précisément ce rattachement qui va la faire suivre.
            guard let window = tracker.snapshot(of: [bundleID]).first else {
                Alerts.inform("\(name) n'a pas de fenêtre à l'écran",
                              detail: "Une zone s'attache à une fenêtre : ouvrez \(name), placez sa fenêtre, puis rattachez la zone.")
                return
            }
            let frame = placed ?? window.frame.insetBy(dx: window.frame.width / 4, dy: window.frame.height / 4)
            store.update { state in
                guard let index = state.zones.firstIndex(where: { $0.id == id }) else { return }
                state.zones[index].rect = Geometry.clamp(Geometry.normalize(frame, in: window.frame))
                state.zones[index].scope = scope
            }

        case .everywhere:
            let frame = placed ?? NSScreen.main.map { $0.frame.insetBy(dx: $0.frame.width / 3, dy: $0.frame.height / 3) }
            guard let frame, let screen = bestScreen(for: frame) ?? NSScreen.main else { return }
            store.update { state in
                guard let index = state.zones.firstIndex(where: { $0.id == id }) else { return }
                state.zones[index].displayUUID = screen.stableIdentifier ?? state.zones[index].displayUUID
                state.zones[index].rect = Geometry.clamp(Geometry.normalize(frame, in: screen.frame))
                state.zones[index].scope = .everywhere
            }
        }
        // La liste des applications à suivre vient de changer.
        syncTracker()
        pushToEditors()
    }

    // MARK: - EditorOverlayDelegate

    func editorDidCreate(frame: CGRect, onDisplay uuid: String) {
        guard let screen = NSScreen.screen(withIdentifier: uuid) else { return }
        // Une zone naît toujours fixe ; on la rattache ensuite depuis le menu.
        let rect = Geometry.clamp(Geometry.normalize(frame, in: screen.frame))
        store.update { $0.zones.append(Zone(displayUUID: uuid, rect: rect)) }
        refresh()
        pushToEditors()
    }

    func editorDidMove(zone id: UUID, toFrame frame: CGRect) {
        store.update { state in
            guard let index = state.zones.firstIndex(where: { $0.id == id }) else { return }
            switch state.zones[index].scope {
            case .everywhere:
                // Glisser une zone d'un écran à l'autre la change d'écran, au lieu de la coincer.
                guard let screen = self.bestScreen(for: frame) ?? NSScreen.screen(withIdentifier: state.zones[index].displayUUID) else { return }
                state.zones[index].displayUUID = screen.stableIdentifier ?? state.zones[index].displayUUID
                state.zones[index].rect = Geometry.clamp(Geometry.normalize(frame, in: screen.frame))
            case .app(let bundleID, _):
                guard let window = self.trackedWindows.first(where: { $0.bundleID == bundleID }) else { return }
                state.zones[index].rect = Geometry.clamp(Geometry.normalize(frame, in: window.frame))
            }
        }
        refresh()
        pushToEditors()
    }

    func editorDidDelete(zone id: UUID) {
        delete(zone: id)
    }

    func editorDidFinish() {
        endEditing()
    }
}
