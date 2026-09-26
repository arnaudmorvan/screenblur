import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = MaskController(store: ScreenBlurStore(root: ScreenBlurStore.defaultRoot))
    private let menu = NSMenu()
    /// Mode diagnostic : poser les masques, écrire un aperçu du partage à ce chemin, sortir.
    private let previewPath: String?

    init(previewPath: String? = nil) {
        self.previewPath = previewPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Application accessoire : pas d'icône dans le Dock, pas de fenêtre principale.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        controller.onChange = { [weak self] in self?.updateStatusIcon() }
        controller.syncTracker()
        controller.refresh()
        updateStatusIcon()

        registerHotKeys()

        if let path = previewPath {
            runPreviewDiagnostic(path: path)
            return
        }

        if let error = controller.store.error {
            Alerts.inform("Les zones enregistrées n'ont pas pu être relues", detail: error)
        }
        showWelcomeIfNeeded()
    }

    // MARK: - Barre des menus

    private func updateStatusIcon() {
        let active = !controller.isHidden && controller.hasSomethingToMask
        let symbol = active ? "eye.slash.fill" : "eye"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: active ? "Zones masquées" : "Zones levées")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = active
            ? "ScreenBlur — \(controller.activeZones.count) zone(s), \(controller.maskedWindowCount) fenêtre(s)"
            : "ScreenBlur — rien de masqué"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = controller.state
        let active = controller.activeZones.count

        let header = NSMenuItem(title: summary(active: active, state: state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(to: menu, title: controller.isEditing ? "Terminer la modification" : "Créer / modifier les zones…",
            key: "n", action: #selector(toggleEditing))
        let hideItem = add(to: menu, title: controller.isHidden ? "Afficher le flou" : "Masquer le flou",
                           key: "b", action: #selector(toggleHidden))
        hideItem.isEnabled = controller.hasSomethingToMask || !state.zones.isEmpty

        menu.addItem(appsMenuItem(state: state))

        menu.addItem(.separator())
        menu.addItem(styleMenuItem(state: state))
        menu.addItem(intensityMenuItem(state: state))

        let preview = add(to: menu, title: "Aperçu de ce que voient les autres…", key: "",
                          action: #selector(showSharePreview))
        preview.isEnabled = controller.hasSomethingToMask
        preview.toolTip = "Capture l'écran comme le ferait un partage d'écran, masques compris."

        if !state.zones.isEmpty {
            menu.addItem(.separator())
            menu.addItem(zonesMenuItem(state: state))
            add(to: menu, title: "Supprimer toutes les zones", key: "", action: #selector(deleteAll))
        }

        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Ouvrir à la connexion", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        add(to: menu, title: "Aide…", key: "", action: #selector(showHelp))
        add(to: menu, title: "Quitter ScreenBlur", key: "q", action: #selector(quit))
    }

    private func summary(active: Int, state: ScreenBlurState) -> String {
        let windows = controller.maskedWindowCount
        var parts: [String] = []
        if active > 0 { parts.append("\(active) zone\(active > 1 ? "s" : "")") }
        if windows > 0 { parts.append("\(windows) fenêtre\(windows > 1 ? "s" : "")") }
        guard !parts.isEmpty else {
            return state.apps.isEmpty ? "Rien de masqué" : "Rien à l'écran pour \(state.apps.count) app suivie(s)"
        }
        var text = parts.joined(separator: " + ") + " · " + state.style.title
        let reserve = state.zones.count - active
        if reserve > 0 { text += " · \(reserve) en réserve" }
        if controller.isHidden { text += " · flou levé" }
        return text
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func styleMenuItem(state: ScreenBlurState) -> NSMenuItem {
        let item = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for style in MaskStyle.allCases {
            let entry = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = state.style == style ? .on : .off
            entry.toolTip = style.detail
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func intensityMenuItem(state: ScreenBlurState) -> NSMenuItem {
        let item = NSMenuItem(title: "Intensité", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for intensity in Intensity.allCases {
            let entry = NSMenuItem(title: intensity.title, action: #selector(pickIntensity(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = intensity.rawValue
            entry.state = state.intensity == intensity ? .on : .off
            // Un aplat n'a pas d'intensité : le réglage reste visible mais inerte.
            entry.isEnabled = state.style != .opaque
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// La liste des applications ouvertes, cochables. Une application suivie mais fermée reste
    /// en bas de liste : sans cela on ne pourrait plus la décocher.
    private func appsMenuItem(state: ScreenBlurState) -> NSMenuItem {
        let item = NSMenuItem(title: "Masquer une application entière", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let mine = Bundle.main.bundleIdentifier

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != mine }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            let entry = NSMenuItem(title: app.localizedName ?? bundleID,
                                   action: #selector(toggleApp(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [bundleID, app.localizedName ?? bundleID]
            entry.state = controller.isMasked(bundleID: bundleID) ? .on : .off
            entry.image = app.icon.map { icon in
                let small = NSImage(size: NSSize(width: 16, height: 16))
                small.lockFocus()
                icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                small.unlockFocus()
                return small
            }
            submenu.addItem(entry)
        }

        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let absent = state.apps.filter { !runningIDs.contains($0.bundleID) }
        if !absent.isEmpty {
            submenu.addItem(.separator())
            for target in absent {
                let entry = NSMenuItem(title: "\(target.name) (pas en cours)",
                                       action: #selector(toggleApp(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [target.bundleID, target.name]
                entry.state = .on
                submenu.addItem(entry)
            }
        }

        if !state.apps.isEmpty {
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "Ne plus masquer aucune application",
                                   action: #selector(unmaskAllApps), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }

        item.submenu = submenu
        return item
    }

    private func zonesMenuItem(state: ScreenBlurState) -> NSMenuItem {
        let item = NSMenuItem(title: "Zones", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, zone) in state.zones.enumerated() {
            let entry = NSMenuItem(title: zoneTitle(index: index, zone: zone), action: nil, keyEquivalent: "")
            entry.submenu = zoneSubmenu(for: zone)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func zoneTitle(index: Int, zone: Zone) -> String {
        let placed = controller.placedFrame(of: zone.id)
        let size = placed.map { "\(Int($0.width)) × \(Int($0.height))" }
        switch zone.scope {
        case .everywhere:
            let screen = NSScreen.screen(withIdentifier: zone.displayUUID)?.shortName ?? "écran absent"
            return "Zone \(index + 1) — \(screen)" + (size.map { " · \($0)" } ?? "")
        case .app(_, let name):
            // Une zone attachée dont l'application est fermée n'est nulle part : le dire.
            let state = placed == nil ? " · \(name) fermée" : (size.map { " · \($0)" } ?? "")
            return "Zone \(index + 1) — sur \(name)\(state)"
        }
    }

    /// Le choix demandé : cette zone s'applique-t-elle partout, ou seulement sur une application ?
    private func zoneSubmenu(for zone: Zone) -> NSMenu {
        let submenu = NSMenu()
        let header = NSMenuItem(title: "Appliquer cette zone à…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)

        let everywhere = NSMenuItem(title: "Tout l'écran", action: #selector(scopeZone(_:)), keyEquivalent: "")
        everywhere.target = self
        everywhere.representedObject = [zone.id.uuidString, "", ""]
        everywhere.state = zone.scope == .everywhere ? .on : .off
        everywhere.toolTip = "Un rectangle fixe, masqué en permanence."
        submenu.addItem(everywhere)

        let mine = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications
            .filter({ $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != mine })
            .sorted(by: { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }) {
            guard let bundleID = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let entry = NSMenuItem(title: "Seulement sur \(name)", action: #selector(scopeZone(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [zone.id.uuidString, bundleID, name]
            entry.state = zone.scope.bundleID == bundleID ? .on : .off
            entry.toolTip = "La zone suit les fenêtres de \(name) et disparaît avec elles."
            submenu.addItem(entry)
        }

        // Une application rattachée mais fermée doit rester visible, sinon on ne peut plus rien changer.
        if let bundleID = zone.scope.bundleID,
           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            let entry = NSMenuItem(title: "Seulement sur \(zone.scope.label ?? bundleID) (pas en cours)",
                                   action: nil, keyEquivalent: "")
            entry.state = .on
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        let delete = NSMenuItem(title: "Supprimer cette zone", action: #selector(deleteZone(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = zone.id.uuidString
        submenu.addItem(delete)
        return submenu
    }

    // MARK: - Actions

    @objc private func toggleEditing() { controller.toggleEditing() }
    @objc private func toggleHidden() { controller.toggleHidden() }
    @objc private func deleteAll() { controller.deleteAllZones() }
    @objc private func unmaskAllApps() { controller.unmaskAllApps() }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        controller.toggleApp(bundleID: pair[0], name: pair[1])
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MaskStyle(rawValue: raw) else { return }
        controller.set(style: style)
    }

    @objc private func pickIntensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let intensity = Intensity(rawValue: raw) else { return }
        controller.set(intensity: intensity)
    }

    @objc private func scopeZone(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 3,
              let id = UUID(uuidString: parts[0]) else { return }
        controller.setScope(zone: id, to: parts[1].isEmpty ? .everywhere : .app(bundleID: parts[1], name: parts[2]))
    }

    @objc private func deleteZone(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        controller.delete(zone: id)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Alerts.inform("L'ouverture à la connexion n'a pas pu être modifiée",
                          detail: "\(error.localizedDescription)\n\nCe réglage demande que ScreenBlur soit installé dans /Applications et signé.")
        }
    }


    @objc private func showSharePreview() {
        guard let screen = controller.busiestScreen else { return }
        Task { @MainActor in
            do {
                let url = try await SharePreview.capture(screen: screen, to: SharePreview.temporaryURL())
                NSWorkspace.shared.open(url)
            } catch SharePreview.Failure.refused {
                Alerts.askScreenRecording(detail: "L'aperçu relit l'écran pour vous montrer ce qui part à l'antenne. Autorisez ScreenBlur, puis relancez l'application.")
            } catch {
                Alerts.inform("L'aperçu n'a pas pu être pris", detail: error.localizedDescription)
            }
        }
    }

    /// Même capture, sans interface : sert au script de vérification.
    private func runPreviewDiagnostic(path: String) {
        Task { @MainActor in
            // Laisser le WindowServer composer les masques avant de photographier l'écran.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let screen = controller.busiestScreen else {
                print("aucun écran"); NSApp.terminate(nil); return
            }
            var report: String
            do {
                let url = try await SharePreview.capture(screen: screen, to: URL(fileURLWithPath: path))
                let apps = controller.state.apps.map(\.bundleID).joined(separator: ", ")
                report = """
                aperçu écrit : \(url.path)
                écran : \(screen.localizedName)
                zones : \(controller.state.zones.count) dont \(controller.state.zones.filter { $0.scope != .everywhere }.count) attachée(s) à une application
                applications suivies : \(apps.isEmpty ? "aucune" : apps)
                fenêtres masquées : \(controller.maskedWindowCount)
                style : \(controller.state.style.rawValue) / \(controller.state.intensity.rawValue)
                \(controller.trackingDescription.joined(separator: "\n"))
                \(controller.maskPlanDescription.joined(separator: "\n"))
                """
            } catch {
                report = "échec : \(error.localizedDescription)"
            }
            print(report)
            // Lancé par `open`, le diagnostic n'a pas de sortie standard lisible : le compte rendu
            // va aussi dans un fichier à côté de l'image.
            try? report.write(to: URL(fileURLWithPath: path + ".log"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    @objc private func showHelp() {
        Alerts.inform("ScreenBlur", detail: helpText)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Raccourcis globaux

    private func registerHotKeys() {
        let modifiers = UInt32(optionKey | shiftKey)
        // Carbon plutôt qu'un moniteur NSEvent global : RegisterEventHotKey fonctionne sans
        // autorisation d'accessibilité, et ne dépend donc pas d'une case cochée par écran.
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_B), modifiers: modifiers) { [weak self] in
            self?.controller.toggleHidden()
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_N), modifiers: modifiers) { [weak self] in
            self?.controller.toggleEditing()
        }
    }

    // MARK: - Premier lancement

    private func showWelcomeIfNeeded() {
        let key = "screenblur.welcomeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Alerts.inform("ScreenBlur masque une partie de votre écran", detail: helpText, button: "Créer ma première zone")
        controller.beginEditing()
    }

    private var helpText: String {
        """
        ⌥⇧N — créer ou modifier les zones. Glissez pour tracer un cadre, déplacez-le, \
        redimensionnez-le par ses poignées, ⌫ pour le supprimer, ⏎ pour terminer.
        ⌥⇧B — lever ou reposer tous les masques, sans les perdre.

        Les masques restent visibles pendant un partage d'écran : ils appartiennent à l'image \
        composée par macOS, exactement comme n'importe quelle fenêtre.

        Une limite à connaître : si vous partagez UNE SEULE FENÊTRE au lieu de l'écran entier, \
        la visioconférence ne capture que cette fenêtre et aucun masque n'y apparaît — le contenu \
        passerait à l'antenne. Partagez l'écran entier, ou vérifiez d'abord votre aperçu.

        Styles : « Verre dépoli » et « Cache opaque » ne demandent aucune autorisation. \
        « Flou réglable » et « Mosaïque » relisent l'écran et demandent l'autorisation \
        d'enregistrement de l'écran.

        Zones enregistrées dans ~/Library/Application Support/ScreenBlur/zones.json, en proportions \
        d'écran : un changement de résolution ne les déplace pas.
        """
    }
}
