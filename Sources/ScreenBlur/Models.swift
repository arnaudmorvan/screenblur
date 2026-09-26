import AppKit

/// À quoi s'applique une zone.
enum ZoneScope: Codable, Equatable {
    /// Un rectangle fixe sur l'écran, masqué en permanence.
    case everywhere
    /// Un rectangle attaché aux fenêtres d'une application : il les suit, et n'existe que
    /// lorsqu'une de ses fenêtres est à l'écran.
    case app(bundleID: String, name: String)

    var bundleID: String? {
        if case .app(let bundleID, _) = self { return bundleID }
        return nil
    }

    var label: String? {
        if case .app(_, let name) = self { return name }
        return nil
    }
}

/// Une zone à masquer.
///
/// Son cadre est TOUJOURS normalisé, mais pas dans le même repère selon la portée : dans l'écran
/// pour une zone fixe, **dans la fenêtre** pour une zone attachée à une application. C'est ce qui
/// lui permet de suivre la fenêtre quand on la déplace ou la redimensionne.
struct Zone: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// L'écran d'origine. Sert pour une zone fixe ; conservé pour une zone attachée, afin de la
    /// reposer au bon endroit si on la détache.
    var displayUUID: String
    var rect: NormalizedRect
    var scope: ZoneScope = .everywhere

    init(id: UUID = UUID(), displayUUID: String, rect: NormalizedRect, scope: ZoneScope = .everywhere) {
        self.id = id
        self.displayUUID = displayUUID
        self.rect = rect
        self.scope = scope
    }

    /// Décodage tolérant, comme pour l'état complet : un fichier écrit avant les portées reste
    /// lisible, et ses zones redeviennent simplement des zones fixes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayUUID = try container.decode(String.self, forKey: .displayUUID)
        rect = try container.decode(NormalizedRect.self, forKey: .rect)
        scope = try container.decodeIfPresent(ZoneScope.self, forKey: .scope) ?? .everywhere
    }
}

/// Quatre façons de cacher. Les deux premières ne demandent AUCUNE autorisation macOS ;
/// les deux suivantes relisent l'écran et exigent donc « Enregistrement de l'écran ».
enum MaskStyle: String, Codable, CaseIterable {
    case verre      // NSVisualEffectView : le flou du système, calculé par le WindowServer.
    case flou       // Recapture + flou gaussien réglable.
    case mosaique   // Recapture + gros pixels.
    case opaque     // Aplat : aucun doute possible.

    var title: String {
        switch self {
        case .verre: return "Verre dépoli"
        case .flou: return "Flou réglable"
        case .mosaique: return "Mosaïque"
        case .opaque: return "Cache opaque"
        }
    }

    var detail: String {
        switch self {
        case .verre: return "Le flou du système. Aucune autorisation, aucun calcul."
        case .flou: return "ScreenBlur gaussien dont l'intensité se règle. Autorisation d'enregistrement de l'écran."
        case .mosaique: return "Gros pixels, illisible par construction. Autorisation d'enregistrement de l'écran."
        case .opaque: return "Un aplat. Rien ne passe, jamais."
        }
    }

    /// Ces styles relisent le contenu de l'écran pour le redessiner flouté.
    var needsScreenRecording: Bool { self == .flou || self == .mosaique }
}

/// L'intensité pilote trois grandeurs différentes selon le style : la teinte posée sur le
/// verre, le rayon du flou gaussien, la taille des pixels de la mosaïque.
enum Intensity: String, Codable, CaseIterable {
    case douce, moyenne, forte, maximale

    var title: String {
        switch self {
        case .douce: return "Douce"
        case .moyenne: return "Moyenne"
        case .forte: return "Forte"
        case .maximale: return "Maximale"
        }
    }

    /// Teinte sombre posée par-dessus le verre dépoli : le flou du système est fixe,
    /// c'est elle qui achève de rendre un gros titre illisible.
    var tintAlpha: CGFloat {
        switch self {
        case .douce: return 0.0
        case .moyenne: return 0.18
        case .forte: return 0.34
        case .maximale: return 0.58
        }
    }

    /// Rayon du flou gaussien, exprimé en points de l'écran capturé.
    var gaussianRadius: Double {
        switch self {
        case .douce: return 10
        case .moyenne: return 22
        case .forte: return 40
        case .maximale: return 70
        }
    }

    /// Côté d'un pixel de la mosaïque, en points de l'écran capturé.
    var pixelScale: Double {
        switch self {
        case .douce: return 10
        case .moyenne: return 18
        case .forte: return 30
        case .maximale: return 48
        }
    }
}

/// Une application dont toutes les fenêtres sont masquées, où qu'elles aillent. Mémorisée par
/// son identifiant de paquet : elle se retrouve d'un lancement à l'autre, même si l'app n'est
/// pas ouverte au moment où ScreenBlur démarre.
struct AppTarget: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}

/// Tout l'état persistant de l'application.
struct ScreenBlurState: Codable, Equatable {
    var zones: [Zone] = []
    var apps: [AppTarget] = []
    var style: MaskStyle = .verre
    var intensity: Intensity = .forte

    init() {}

    /// Décodage tolérant : une clé absente reprend sa valeur par défaut. Sans cela, ajouter un
    /// réglage rendrait illisible le fichier de la version précédente — et l'utilisateur
    /// perdrait ses zones en mettant ScreenBlur à jour.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zones = try container.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        apps = try container.decodeIfPresent([AppTarget].self, forKey: .apps) ?? []
        style = try container.decodeIfPresent(MaskStyle.self, forKey: .style) ?? .verre
        intensity = try container.decodeIfPresent(Intensity.self, forKey: .intensity) ?? .forte
    }

    func zones(onDisplay uuid: String) -> [Zone] {
        zones.filter { $0.displayUUID == uuid }
    }

    /// Les applications masquées EN ENTIER, par opposition à celles qui portent seulement une zone.
    var targetedWholeApps: Set<String> { Set(apps.map(\.bundleID)) }

    /// Toutes les applications à suivre : celles masquées en entier, et celles auxquelles une
    /// zone est attachée.
    var targetedBundleIDs: Set<String> {
        Set(apps.map(\.bundleID)).union(zones.compactMap(\.scope.bundleID))
    }
}
