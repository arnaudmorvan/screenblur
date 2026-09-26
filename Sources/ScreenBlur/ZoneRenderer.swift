import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Le rendu d'une zone à partir de l'image de l'écran. Isolé du flux de capture pour être
/// vérifiable : c'est ici que se joue la chaîne colorimétrique, et une erreur y est invisible
/// à l'œil sur une capture réelle.
final class ZoneRenderer: @unchecked Sendable {
    /// Espace de travail fixé de bout en bout. Ce n'est pas un correctif : le comportement
    /// par défaut de Core Image donne aujourd'hui le même résultat, et le test le vérifie sur
    /// un vrai tampon de capture. C'est un contrat écrit — une zone masquée dont les couleurs
    /// dériveraient ne se verrait pas, puisqu'un flou de grand rayon produit de toute façon
    /// des aplats plausibles.
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: ZoneRenderer.space,
        .outputColorSpace: ZoneRenderer.space
    ])

    /// Lit une image d'écran en sRGB, l'étiquette étant posée explicitement plutôt que laissée
    /// à l'interprétation par défaut du tampon.
    func source(from buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.space])
    }

    func render(source: CIImage, crop: CGRect, style: MaskStyle, intensity: Intensity) -> CGImage? {
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        // Étendre les bords avant de filtrer : sans cela le flou aspire du transparent et
        // la zone s'assombrit sur son pourtour.
        let region = source.cropped(to: crop).clampedToExtent()

        let filtered: CIImage
        switch style {
        case .mosaique:
            let filter = CIFilter.pixellate()
            filter.inputImage = region
            filter.scale = Float(intensity.pixelScale)
            // Centrer la grille sur la zone : sinon les blocs se décalent d'une image à
            // l'autre et l'œil y lit un mouvement.
            filter.center = CGPoint(x: crop.midX, y: crop.midY)
            filtered = filter.outputImage ?? region
        default:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = region
            filter.radius = Float(intensity.gaussianRadius)
            filtered = filter.outputImage ?? region
        }

        return context.createCGImage(filtered.cropped(to: crop), from: crop,
                                     format: .BGRA8, colorSpace: Self.space)
    }
}
