import CoreGraphics

/// Un cadre normalisé (0…1) exprimé dans l'espace de SON écran, origine en HAUT à gauche —
/// la convention d'une capture d'écran. Rien n'est mémorisé en pixels : une zone survit ainsi
/// au changement de résolution, au débranchement d'un écran et au réagencement du bureau.
struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

enum Geometry {
    /// Taille minimale d'une zone, en fraction d'écran : sous ce seuil un clic maladroit
    /// créerait une zone invisible impossible à rattraper.
    static let minimumSide: Double = 0.01

    /// Cadre AppKit global (origine en bas à gauche de l'écran principal) → cadre normalisé.
    static func normalize(_ rect: CGRect, in screenFrame: CGRect) -> NormalizedRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .full }
        return NormalizedRect(
            x: Double((rect.minX - screenFrame.minX) / screenFrame.width),
            // L'écart mémorisé part du HAUT de l'écran, pas du bas comme AppKit.
            y: Double((screenFrame.maxY - rect.maxY) / screenFrame.height),
            width: Double(rect.width / screenFrame.width),
            height: Double(rect.height / screenFrame.height)
        )
    }

    /// L'inverse : où poser la fenêtre de masque sur cet écran.
    static func denormalize(_ n: NormalizedRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + CGFloat(n.x) * screenFrame.width,
            y: screenFrame.maxY - CGFloat(n.y + n.height) * screenFrame.height,
            width: CGFloat(n.width) * screenFrame.width,
            height: CGFloat(n.height) * screenFrame.height
        )
    }

    /// Le cadre à découper dans l'image Core Image de l'écran capturé (pixels, origine en bas
    /// à gauche comme toute CIImage) : c'est la même bascule verticale que denormalize.
    static func cropRect(_ n: NormalizedRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(n.x) * imageSize.width,
            y: CGFloat(1 - n.y - n.height) * imageSize.height,
            width: CGFloat(n.width) * imageSize.width,
            height: CGFloat(n.height) * imageSize.height
        )
    }

    /// Deux points de glissement → un cadre normalisé, quel que soit le sens du geste.
    static func rect(from a: CGPoint, to b: CGPoint, in frame: CGRect) -> NormalizedRect {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return normalize(rect, in: frame)
    }

    /// Les fenêtres du système sont décrites dans le repère Quartz : origine en HAUT à gauche
    /// de l'écran principal, y vers le bas. AppKit place les siennes dans le repère inverse.
    /// `zeroScreenHeight` est la hauteur de l'écran dont l'origine AppKit est (0, 0).
    static func appKitRect(fromQuartz rect: CGRect, zeroScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: zeroScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Les parties du cadre réellement recouvertes par les fenêtres placées devant. Elles
    /// deviendront des trous dans le masque : flouter par-dessus une fenêtre qui est AU-DESSUS
    /// de celle qu'on cache reviendrait à flouter la mauvaise.
    static func holes(in frame: CGRect, coveredBy front: [CGRect]) -> [CGRect] {
        front.compactMap { candidate in
            let overlap = candidate.intersection(frame)
            return overlap.isNull || overlap.isEmpty ? nil : overlap
        }
    }

    /// Au-delà de ce nombre, les trous les plus petits sont ignorés : le masque couvre alors
    /// un peu plus que nécessaire, ce qui est le sens sûr de l'erreur.
    static let maximumHoles = 12

    /// La région à masquer, découpée en rectangles DISJOINTS : le cadre moins l'union des trous.
    ///
    /// Pourquoi ne pas simplement empiler les trous dans un chemin pair-impair : deux trous qui
    /// se chevauchent s'y annulent et la zone commune redevient pleine. Comme deux fenêtres qui
    /// recouvrent la même fenêtre se chevauchent presque toujours, le masque se reformait
    /// exactement là où il fallait percer. Mesuré, pas supposé.
    static func visibleRectangles(in frame: CGRect, holes: [CGRect]) -> [CGRect] {
        var seen = Set<String>()
        let clipped = holes
            .compactMap { hole -> CGRect? in
                let overlap = hole.intersection(frame)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                // Deux fenêtres superposées au même endroit produisent le même trou : sans
                // dédoublonnage, les doublons consommeraient le plafond à la place de vrais
                // recouvrements, et une partie resterait masquée à tort.
                return seen.insert("\(overlap)").inserted ? overlap : nil
            }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(maximumHoles)
        guard !clipped.isEmpty else { return [frame] }

        // Une grille formée par les bords : chaque cellule est entièrement dedans ou dehors.
        let xs = Set([frame.minX, frame.maxX] + clipped.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set([frame.minY, frame.maxY] + clipped.flatMap { [$0.minY, $0.maxY] }).sorted()

        var result: [CGRect] = []
        for row in 0..<max(0, ys.count - 1) {
            let bottom = ys[row], top = ys[row + 1]
            guard top > bottom else { continue }
            var runStart: CGFloat?
            for column in 0..<max(0, xs.count - 1) {
                let left = xs[column], right = xs[column + 1]
                guard right > left else { continue }
                let centre = CGPoint(x: (left + right) / 2, y: (bottom + top) / 2)
                if clipped.contains(where: { $0.contains(centre) }) {
                    if let start = runStart {
                        result.append(CGRect(x: start, y: bottom, width: left - start, height: top - bottom))
                        runStart = nil
                    }
                } else if runStart == nil {
                    runStart = left
                }
            }
            if let start = runStart {
                result.append(CGRect(x: start, y: bottom, width: frame.maxX - start, height: top - bottom))
            }
        }
        return result
    }

    /// Une fenêtre entièrement cachée derrière une autre n'a pas besoin de masque.
    static func isFullyCovered(_ frame: CGRect, by front: [CGRect]) -> Bool {
        front.contains { $0.contains(frame) }
    }

    /// Ramène une zone dans l'écran et lui impose une taille minimale. Une zone glissée
    /// hors cadre revient au bord au lieu de disparaître.
    static func clamp(_ n: NormalizedRect) -> NormalizedRect {
        var r = n
        r.width = min(max(r.width, minimumSide), 1)
        r.height = min(max(r.height, minimumSide), 1)
        r.x = min(max(r.x, 0), 1 - r.width)
        r.y = min(max(r.y, 0), 1 - r.height)
        return r
    }

    /// Vrai si le geste est trop petit pour être une intention : on le jette.
    static func isNegligible(_ n: NormalizedRect) -> Bool {
        n.width < minimumSide || n.height < minimumSide
    }
}
