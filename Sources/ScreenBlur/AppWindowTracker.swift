import AppKit

/// Une fenêtre suivie : son cadre AppKit et les morceaux recouverts par ce qui est devant.
struct TrackedWindow: Equatable {
    let id: CGWindowID
    let bundleID: String
    let frame: CGRect
    let holes: [CGRect]
}

/// Suit les fenêtres des applications choisies.
///
/// S'appuie sur `CGWindowListCopyWindowInfo`, qui donne le propriétaire, le cadre et l'ordre de
/// profondeur de chaque fenêtre **sans aucune autorisation** — seul le TITRE d'une fenêtre est
/// protégé par TCC, et on n'en a pas besoin. Masquer une application ne demande donc ni
/// accessibilité ni enregistrement de l'écran, contrairement à ce qu'on pourrait croire.
@MainActor
final class AppWindowTracker: NSObject {
    /// Le battement de base. À chaque tour on lit la position du curseur — quelques
    /// microsecondes — et on ne fait le relevé complet des fenêtres, qui coûte environ 1,1 ms
    /// (mesuré, dix-neuf fenêtres suivies), que si quelque chose bouge.
    private static let interval: TimeInterval = 1.0 / 30

    /// Au repos, le relevé complet tombe à cette cadence : rien ne bouge, rien à suivre.
    /// Une fenêtre ne peut se déplacer sans que la souris bouge ou qu'une application
    /// s'active — les deux sont détectés autrement, et sans délai.
    private static let idleInterval: TimeInterval = 1.0 / 6

    /// Durée pendant laquelle on reste à pleine cadence après le dernier mouvement.
    private static let activeAfterMotion: TimeInterval = 0.6

    /// Après un changement d'application, ses fenêtres sont masquées EN ENTIER pendant ce délai,
    /// sans tenir compte de ce qui les recouvrait. Le temps que le système réordonne les
    /// fenêtres, un relevé peut encore les croire derrière : les percer à ce moment-là
    /// découvrirait leur contenu juste au moment où l'utilisateur les regarde.
    private static let graceAfterActivation: TimeInterval = 0.35
    /// Sous cette taille, une « fenêtre » est un artefact (ombre, infobulle, panneau vide).
    private static let minimumSide: CGFloat = 40

    private var timer: Timer?
    private var targets: Set<String> = []
    private var last: [TrackedWindow] = []
    private var grace: [String: Date] = [:]
    private var lastMouse = CGPoint.zero
    private var lastMotion = Date.distantPast
    private var lastFullPoll = Date.distantPast

    override init() {
        super.init()
        let centre = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification,
                                          NSWorkspace.didHideApplicationNotification,
                                          NSWorkspace.didUnhideApplicationNotification] {
            centre.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
        }
    }

    /// Appelé seulement quand le relevé change réellement.
    var onChange: (([TrackedWindow]) -> Void)?

    var tracked: [TrackedWindow] { last }

    func setTargets(_ bundleIDs: Set<String>) {
        targets = bundleIDs
        if bundleIDs.isEmpty {
            stop()
            if !last.isEmpty {
                last = []
                onChange?([])
            }
            return
        }
        start()
        poll()
    }

    /// Changement d'application : réagir tout de suite, sans attendre le prochain relevé.
    @objc private func applicationChanged(_ note: Notification) {
        guard !targets.isEmpty else { return }
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let bundleID = app.bundleIdentifier, targets.contains(bundleID) {
            grace[bundleID] = Date().addingTimeInterval(Self.graceAfterActivation)
            // Masquer au maximum immédiatement : le relevé qui suit ne fera qu'affiner.
            let promoted = last.map { window in
                window.bundleID == bundleID
                    ? TrackedWindow(id: window.id, bundleID: window.bundleID, frame: window.frame, holes: [])
                    : window
            }
            if promoted != last {
                last = promoted
                onChange?(promoted)
            }
        }
        poll()
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Mode .common : sans cela le suivi se fige dès qu'un menu est ouvert.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Hauteur de l'écran dont l'origine AppKit est (0, 0) : c'est lui qui sert de repère à
    /// Quartz pour toutes les fenêtres du système.
    private static var zeroScreenHeight: CGFloat {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    /// Un relevé PONCTUEL, indépendant des applications suivies.
    ///
    /// Indispensable pour rattacher une zone à une application qui n'est pas encore suivie :
    /// sans cela, on ne connaît les fenêtres que des applications déjà rattachées, et aucune
    /// première zone ne peut jamais l'être. C'est exactement le cercle vicieux qui faisait
    /// répondre « Claude n'a pas de fenêtre à l'écran » alors que Claude était devant.
    func snapshot(of bundleIDs: Set<String>) -> [TrackedWindow] {
        // `includingCovered` : ici on cherche OÙ EST une fenêtre, pas s'il faut la masquer.
        // L'écarter parce qu'une autre passe devant ferait échouer le rattachement d'une zone
        // à une application simplement posée en arrière-plan.
        collect(targets: bundleIDs, includingCovered: true)
    }

    /// Le battement : décide s'il faut payer un relevé complet.
    private func tick() {
        guard !targets.isEmpty else { return }
        let now = Date()
        // Lecture de la position du curseur : aucune autorisation, coût négligeable. Une
        // fenêtre ne se déplace pas toute seule — si la souris ne bouge pas, rien à refaire.
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse {
            lastMouse = mouse
            lastMotion = now
        }
        let moving = now.timeIntervalSince(lastMotion) < Self.activeAfterMotion
        let due = now.timeIntervalSince(lastFullPoll) >= (moving ? 0 : Self.idleInterval)
        guard due else { return }
        poll()
    }

    private func poll() {
        guard !targets.isEmpty else { return }
        lastFullPoll = Date()
        let found = collect(targets: targets, includingCovered: true)
        guard found != last else { return }
        // Une fenêtre a bougé sans la souris — animation, gestionnaire de fenêtres : rester
        // à pleine cadence le temps que ça se stabilise.
        lastMotion = Date()
        last = found
        onChange?(found)
    }

    private func collect(targets: Set<String>, includingCovered: Bool) -> [TrackedWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let zeroHeight = Self.zeroScreenHeight
        let mine = ProcessInfo.processInfo.processIdentifier
        let now = Date()

        var bundles: [pid_t: String] = [:]
        // La liste est ordonnée de l'avant vers l'arrière : tout ce qui a déjà été vu est devant.
        var front: [CGRect] = []
        var found: [TrackedWindow] = []

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }

            let frame = Geometry.appKitRect(fromQuartz: quartz, zeroScreenHeight: zeroHeight)
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let bundleID = bundles[pid] ?? {
                let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                bundles[pid] = resolved
                return resolved
            }()

            // Seules les fenêtres ordinaires (couche 0) se masquent ; mais TOUTES les fenêtres
            // rencontrées comptent comme obstacles, barre des menus et Dock compris.
            if layer == 0, targets.contains(bundleID),
               quartz.width >= Self.minimumSide, quartz.height >= Self.minimumSide,
               includingCovered || !Geometry.isFullyCovered(frame, by: front) {
                let id = CGWindowID(info[kCGWindowNumber as String] as? UInt32 ?? 0)
                // Pendant le délai de grâce, aucun trou : on masque plus que nécessaire
                // plutôt que de risquer de découvrir.
                let settling = (grace[bundleID].map { $0 > now } ?? false)
                found.append(TrackedWindow(id: id, bundleID: bundleID, frame: frame,
                                           holes: settling ? [] : Geometry.holes(in: frame, coveredBy: front)))
            }
            front.append(frame)
        }
        return found
    }
}
