import Foundation

/// La langue de l'interface, sur le modèle de KeyFigma.
///
/// Pas de `.lproj` : l'app est un exécutable SPM assemblé à la main, et `l("Zones", "Zones")`
/// garde les deux langues côte à côte. Le menu étant reconstruit à chaque ouverture, changer de
/// langue s'applique sans relancer.
enum L10n {
    enum Language: String, CaseIterable {
        case automatic, fr, en

        var title: String {
            switch self {
            case .automatic: return l("Automatique", "Automatic")
            case .fr: return "Français"
            case .en: return "English"
            }
        }
    }

    private static let key = "screenblur.language"

    static var language: Language {
        get { UserDefaults.standard.string(forKey: key).flatMap(Language.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// « Automatique » = français dès que le français figure parmi les langues macOS.
    static var isFrench: Bool {
        switch language {
        case .fr: return true
        case .en: return false
        case .automatic: return Locale.preferredLanguages.contains { $0.lowercased().hasPrefix("fr") }
        }
    }
}

/// `l("Aide…", "Help…")`
func l(_ fr: String, _ en: String) -> String { L10n.isFrench ? fr : en }
