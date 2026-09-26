import CoreImage
import CoreVideo
import Foundation

@main
struct CoreTests {
    @MainActor
    static func main() throws {
        // Un écran secondaire posé à gauche et au-dessus de l'écran principal : les
        // coordonnées AppKit y sont négatives, c'est le cas qui casse les conversions.
        let screen = CGRect(x: -1512, y: 420, width: 1512, height: 982)

        // Aller-retour : une zone mémorisée doit retomber au pixel près.
        let rect = CGRect(x: -1300, y: 900, width: 400, height: 250)
        let normalized = Geometry.normalize(rect, in: screen)
        let back = Geometry.denormalize(normalized, in: screen)
        precondition(abs(back.minX - rect.minX) < 0.001 && abs(back.minY - rect.minY) < 0.001
                     && abs(back.width - rect.width) < 0.001 && abs(back.height - rect.height) < 0.001,
                     "Aller-retour de normalisation exact sur un écran aux coordonnées négatives")

        // La convention retenue mesure depuis le HAUT de l'écran.
        let topLeft = CGRect(x: screen.minX, y: screen.maxY - 100, width: 200, height: 100)
        let topNormalized = Geometry.normalize(topLeft, in: screen)
        precondition(topNormalized.x == 0 && abs(topNormalized.y) < 0.0001,
                     "Une zone collée en haut à gauche vaut (0, 0)")

        let bottomLeft = CGRect(x: screen.minX, y: screen.minY, width: 200, height: 100)
        let bottomNormalized = Geometry.normalize(bottomLeft, in: screen)
        precondition(abs(bottomNormalized.y + bottomNormalized.height - 1) < 0.0001,
                     "Une zone collée en bas touche le bord 1")

        // Le découpage Core Image rebascule vers l'origine en bas à gauche : une zone en haut
        // de l'écran se découpe en HAUT de l'image, donc à grand y.
        let image = CGSize(width: 1512, height: 982)
        let crop = Geometry.cropRect(topNormalized, imageSize: image)
        precondition(abs(crop.maxY - image.height) < 0.0001 && crop.minX == 0,
                     "La zone du haut se découpe contre le bord supérieur de l'image")
        let cropBottom = Geometry.cropRect(bottomNormalized, imageSize: image)
        precondition(abs(cropBottom.minY) < 0.0001, "La zone du bas se découpe contre le bord inférieur")

        // Une zone poussée hors de l'écran revient au bord au lieu de disparaître.
        let outside = Geometry.clamp(NormalizedRect(x: 0.9, y: -0.4, width: 0.4, height: 0.3))
        precondition(abs(outside.x + outside.width - 1) < 0.0001 && outside.y == 0,
                     "Une zone hors cadre est ramenée dans l'écran, sa taille conservée")
        let tiny = Geometry.clamp(NormalizedRect(x: 0.5, y: 0.5, width: 0, height: 0))
        precondition(tiny.width == Geometry.minimumSide && tiny.height == Geometry.minimumSide,
                     "Une zone de taille nulle reçoit la taille minimale")

        // Un simple clic n'est pas un tracé.
        let click = Geometry.rect(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 402, y: 401), in: screen)
        precondition(Geometry.isNegligible(click), "Un clic ne crée pas de zone")
        // Le tracé fonctionne dans les deux sens de glissement.
        let forward = Geometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400), in: screen)
        let backward = Geometry.rect(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 100, y: 100), in: screen)
        precondition(forward == backward, "Glisser vers le haut ou vers le bas donne la même zone")

        // Poignées : le bord opposé ne bouge pas.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let widened = Handle.right.resize(frame, by: CGSize(width: 50, height: 0))
        precondition(widened.minX == frame.minX && widened.width == 350, "La poignée droite laisse le bord gauche en place")
        let fromLeft = Handle.left.resize(frame, by: CGSize(width: 50, height: 0))
        precondition(fromLeft.maxX == frame.maxX && fromLeft.width == 250, "La poignée gauche laisse le bord droit en place")
        let flipped = Handle.left.resize(frame, by: CGSize(width: 600, height: 0))
        precondition(flipped.width >= 24 && flipped.minX <= flipped.maxX, "Un cadre retourné est remis d'aplomb, pas jeté")
        let corner = Handle.topRight.resize(frame, by: CGSize(width: 40, height: 60))
        precondition(corner.minX == frame.minX && corner.minY == frame.minY
                     && corner.width == 340 && corner.height == 260, "Le coin haut-droit ancre le coin bas-gauche")

        // Repère Quartz → AppKit. Les fenêtres du système sont décrites depuis le HAUT de
        // l'écran principal ; une erreur de signe ici pose les masques en miroir vertical.
        let zeroHeight: CGFloat = 1117
        let quartz = CGRect(x: 200, y: 100, width: 800, height: 600)
        let appKit = Geometry.appKitRect(fromQuartz: quartz, zeroScreenHeight: zeroHeight)
        precondition(appKit == CGRect(x: 200, y: 417, width: 800, height: 600),
                     "Une fenêtre à 100 px du haut a son bas à 1117 - 700 = 417")
        let topmost = Geometry.appKitRect(fromQuartz: CGRect(x: 0, y: 0, width: 400, height: 50),
                                          zeroScreenHeight: zeroHeight)
        precondition(topmost.maxY == zeroHeight, "Une fenêtre collée en haut touche le sommet de l'écran")
        // Un écran secondaire au-dessus du principal donne des y AppKit supérieurs à la hauteur.
        let above = Geometry.appKitRect(fromQuartz: CGRect(x: 1728, y: -300, width: 500, height: 200),
                                        zeroScreenHeight: zeroHeight)
        precondition(above.minY == 1217, "Un écran placé plus haut sort au-dessus du repère, sans repli")

        // Occlusion : ce qui est DEVANT la fenêtre masquée doit percer le masque, sinon on
        // flouterait la fenêtre qui est au-dessus de celle qu'on cache.
        let target = CGRect(x: 100, y: 100, width: 400, height: 300)
        let overlapping = CGRect(x: 300, y: 200, width: 400, height: 400)
        let holes = Geometry.holes(in: target, coveredBy: [overlapping, CGRect(x: 900, y: 900, width: 100, height: 100)])
        precondition(holes == [CGRect(x: 300, y: 200, width: 200, height: 200)],
                     "Le trou est l'intersection, bornée à la fenêtre ; ce qui ne touche pas est ignoré")
        precondition(Geometry.holes(in: target, coveredBy: []).isEmpty, "Rien devant, aucun trou")
        // Deux fenêtres qui se touchent sans se recouvrir ne percent rien.
        precondition(Geometry.holes(in: target, coveredBy: [CGRect(x: 500, y: 100, width: 200, height: 300)]).isEmpty,
                     "Un simple contact de bord ne perce pas le masque")
        precondition(Geometry.isFullyCovered(target, by: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]),
                     "Une fenêtre entièrement cachée n'a pas besoin de masque")
        precondition(!Geometry.isFullyCovered(target, by: [overlapping]),
                     "Un recouvrement partiel demande toujours un masque")

        // La découpe du masque en rectangles visibles.
        let carre = CGRect(x: 0, y: 0, width: 100, height: 100)
        func couvert(_ point: CGPoint, _ pieces: [CGRect]) -> Bool { pieces.contains { $0.contains(point) } }

        precondition(Geometry.visibleRectangles(in: carre, holes: []) == [carre], "Sans trou, un seul rectangle")
        precondition(Geometry.visibleRectangles(in: carre, holes: [carre]).isEmpty, "Tout recouvert, plus rien à masquer")

        let unTrou = Geometry.visibleRectangles(in: carre, holes: [CGRect(x: 25, y: 25, width: 50, height: 50)])
        precondition(!couvert(CGPoint(x: 50, y: 50), unTrou), "Le milieu du trou n'est pas masqué")
        precondition(couvert(CGPoint(x: 10, y: 50), unTrou), "Autour du trou, le masque tient")
        precondition(couvert(CGPoint(x: 50, y: 10), unTrou), "Sous le trou aussi")
        // Les morceaux ne doivent pas se chevaucher, sinon le liseré et la teinte se cumulent.
        for (i, a) in unTrou.enumerated() {
            for b in unTrou[(i + 1)...] {
                let overlap = a.intersection(b)
                precondition(overlap.isNull || overlap.isEmpty, "Les rectangles visibles sont disjoints")
            }
        }

        // LE cas qui avait échoué en vrai : deux fenêtres qui recouvrent la même fenêtre se
        // chevauchent presque toujours. Avec un chemin pair-impair, leur intersection redevenait
        // masquée — exactement là où il fallait percer.
        let chevauchants = Geometry.visibleRectangles(in: carre, holes: [
            CGRect(x: 0, y: 0, width: 80, height: 80),
            CGRect(x: 40, y: 40, width: 80, height: 80)
        ])
        precondition(!couvert(CGPoint(x: 60, y: 60), chevauchants),
                     "L'intersection de deux trous reste un trou")
        precondition(!couvert(CGPoint(x: 20, y: 20), chevauchants) && !couvert(CGPoint(x: 90, y: 90), chevauchants),
                     "Chacun des deux trous perce aussi")
        precondition(couvert(CGPoint(x: 90, y: 20), chevauchants), "Le coin que personne ne recouvre reste masqué")

        // Trois trous empilés : le nombre impair piégeait aussi la règle pair-impair.
        let triples = Geometry.visibleRectangles(in: carre, holes: [
            CGRect(x: 0, y: 0, width: 90, height: 90),
            CGRect(x: 10, y: 10, width: 80, height: 80),
            CGRect(x: 20, y: 20, width: 70, height: 70)
        ])
        precondition(!couvert(CGPoint(x: 50, y: 50), triples), "Trois trous superposés percent toujours")

        // Des trous en double ne doivent pas consommer le plafond : plusieurs fenêtres
        // superposées au même endroit produisent le même rectangle, vingt fois s'il le faut.
        let gros = CGRect(x: 0, y: 0, width: 60, height: 60)
        let petits: [CGRect] = (0..<5).map { i in
            let x: CGFloat = 70
            let y: CGFloat = CGFloat(i) * 8
            return CGRect(x: x, y: y, width: 6, height: 6)
        }
        let avecDoublons = Geometry.visibleRectangles(in: carre, holes: Array(repeating: gros, count: 20) + petits)
        precondition(!couvert(CGPoint(x: 30, y: 30), avecDoublons), "Le gros trou est percé")
        for petit in petits {
            precondition(!couvert(CGPoint(x: petit.midX, y: petit.midY), avecDoublons),
                         "Les vrais recouvrements survivent aux doublons")
        }

        // Au-delà du plafond, les plus petits trous sont ignorés : on masque trop, jamais trop peu.
        // Quinze trous disjoints de tailles strictement décroissantes, pour douze retenus.
        let beaucoup: [CGRect] = (0..<15).map { (i: Int) -> CGRect in
            let x: CGFloat = CGFloat(i % 5) * 20
            let y: CGFloat = CGFloat(i / 5) * 20
            let side: CGFloat = CGFloat(15 - i)
            return CGRect(x: x, y: y, width: side, height: side)
        }
        precondition(beaucoup.count > Geometry.maximumHoles)
        let plafonne = Geometry.visibleRectangles(in: carre, holes: beaucoup)
        precondition(!couvert(CGPoint(x: beaucoup[0].midX, y: beaucoup[0].midY), plafonne),
                     "Le plus gros trou survit au plafond")
        precondition(couvert(CGPoint(x: beaucoup[14].midX, y: beaucoup[14].midY), plafonne),
                     "Un trou sacrifié reste masqué — l'erreur va dans le sens sûr")

        // Persistance : relecture complète, et fichier corrompu jamais écrasé.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screenblur-tests-\(UUID().uuidString)")
        let store = ScreenBlurStore(root: root)
        precondition(store.state.zones.isEmpty && store.state.style == .verre,
                     "Un état neuf part du verre dépoli, sans autorisation à demander")
        let zone = Zone(displayUUID: "ECRAN-1", rect: normalized)
        precondition(store.update { $0.zones.append(zone); $0.style = .mosaique; $0.intensity = .maximale })
        let reloaded = ScreenBlurStore(root: root)
        precondition(reloaded.state == store.state, "Zones, style et intensité survivent au redémarrage")
        precondition(reloaded.state.zones(onDisplay: "ECRAN-1").count == 1)
        precondition(reloaded.state.zones(onDisplay: "ECRAN-2").isEmpty, "Les zones sont rendues par écran")

        // Une zone attachée à une application est mémorisée DANS le repère de la fenêtre :
        // c'est ce qui la fait suivre quand la fenêtre bouge ou change de taille.
        let fenetre = CGRect(x: 300, y: 200, width: 1000, height: 800)
        let coin = CGRect(x: 300, y: 800, width: 250, height: 200)      // en haut à gauche de la fenêtre
        let relatif = Geometry.normalize(coin, in: fenetre)
        precondition(abs(relatif.x) < 0.0001 && abs(relatif.y) < 0.0001
                     && abs(relatif.width - 0.25) < 0.0001 && abs(relatif.height - 0.25) < 0.0001,
                     "Le coin haut-gauche d'une fenêtre vaut (0, 0, ¼, ¼) quelle que soit sa position")
        // La fenêtre se déplace : la zone la suit, taille inchangée.
        let deplacee = fenetre.offsetBy(dx: -900, dy: 150)
        let suivi = Geometry.denormalize(relatif, in: deplacee)
        precondition(suivi == coin.offsetBy(dx: -900, dy: 150), "La zone suit exactement le déplacement")
        // La fenêtre est redimensionnée : la zone garde ses proportions.
        let agrandie = CGRect(x: 300, y: 200, width: 2000, height: 1600)
        let suiviGrand = Geometry.denormalize(relatif, in: agrandie)
        precondition(suiviGrand == CGRect(x: 300, y: 1400, width: 500, height: 400),
                     "La zone double avec la fenêtre et reste collée au même coin")

        // Les deux façons de désigner une application se cumulent dans ce qu'il faut suivre.
        var portees = ScreenBlurState()
        portees.apps = [AppTarget(bundleID: "com.apple.finder", name: "Finder")]
        portees.zones = [Zone(displayUUID: "ECRAN-1", rect: relatif,
                              scope: .app(bundleID: "com.apple.Preview", name: "Aperçu"))]
        precondition(portees.targetedBundleIDs == ["com.apple.finder", "com.apple.Preview"],
                     "Applications masquées en entier ET applications portant une zone")
        precondition(portees.targetedWholeApps == ["com.apple.finder"],
                     "Seul Finder est masqué en entier ; Aperçu ne porte qu'une zone")

        // Applications suivies : mémorisées par identifiant de paquet.
        precondition(store.update { $0.apps = [AppTarget(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")] })
        precondition(ScreenBlurStore(root: root).state.targetedBundleIDs == ["com.tinyspeck.slackmacgap"])

        // Compatibilité du fichier : un zones.json écrit par une version qui ignorait les
        // applications doit continuer à se relire, sinon une mise à jour effacerait les zones.
        let file = root.appendingPathComponent("zones.json")
        let ancien = #"{"zones":[{"id":"11111111-1111-1111-1111-111111111111","displayUUID":"ECRAN-1","rect":{"x":0.1,"y":0.2,"width":0.3,"height":0.4}}],"style":"mosaique","intensity":"douce"}"#
        try Data(ancien.utf8).write(to: file)
        let migrated = ScreenBlurStore(root: root)
        precondition(migrated.error == nil, "Un fichier sans la clé des applications reste lisible")
        precondition(migrated.state.zones.count == 1 && migrated.state.apps.isEmpty
                     && migrated.state.style == .mosaique && migrated.state.intensity == .douce,
                     "Les réglages connus survivent, le nouveau prend sa valeur par défaut")
        // Une zone écrite avant l'existence des portées redevient une zone fixe, pas une erreur.
        precondition(migrated.state.zones[0].scope == .everywhere,
                     "Une zone sans portée mémorisée s'applique partout")
        // Et la portée survit à un aller-retour sur le disque.
        precondition(store.update { state in
            state.zones = [Zone(displayUUID: "ECRAN-1", rect: relatif,
                                scope: .app(bundleID: "com.apple.Preview", name: "Aperçu"))]
        })
        precondition(ScreenBlurStore(root: root).state.zones[0].scope == .app(bundleID: "com.apple.Preview", name: "Aperçu"),
                     "La portée d'une zone est enregistrée")

        // Et un fichier réduit au strict minimum ne fait pas tomber la relecture.
        try Data(#"{}"#.utf8).write(to: file)
        let empty = ScreenBlurStore(root: root)
        precondition(empty.error == nil && empty.state == ScreenBlurState(), "Un objet vide donne l'état par défaut")

        let broken = Data("ceci n'est pas du JSON".utf8)
        try broken.write(to: file)
        let corrupt = ScreenBlurStore(root: root)
        precondition(corrupt.error != nil, "Un fichier illisible est signalé")
        precondition(!corrupt.update { $0.zones.removeAll() }, "Aucune écriture par-dessus un fichier illisible")
        let afterWrite = try Data(contentsOf: file)
        precondition(afterWrite == broken, "Le fichier corrompu reste intact, les zones récupérables")
        try? FileManager.default.removeItem(at: root)

        // Les styles sans autorisation sont bien ceux annoncés.
        precondition(!MaskStyle.verre.needsScreenRecording && !MaskStyle.opaque.needsScreenRecording)
        precondition(MaskStyle.flou.needsScreenRecording && MaskStyle.mosaique.needsScreenRecording)

        // Chaîne colorimétrique. Un aplat gris moyen doit ressortir gris moyen. Une dérive ici
        // serait invisible à l'œil sur une capture réelle — un flou de grand rayon produit de
        // toute façon des gris plausibles — d'où la mesure plutôt que le coup d'œil.
        let renderer = ZoneRenderer()
        let grey = CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: ZoneRenderer.space)!
        let plate = CIImage(color: grey).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        for style in [MaskStyle.flou, .mosaique] {
            guard let rendered = renderer.render(source: plate, crop: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                 style: style, intensity: .forte) else {
                preconditionFailure("Le rendu de la zone a échoué pour \(style.rawValue)")
            }
            precondition(rendered.width == 200 && rendered.height == 200,
                         "La zone rendue a la taille du découpage")
            let value = middlePixel(of: rendered)
            precondition(abs(Int(value) - 128) <= 3,
                         "\(style.rawValue) : un gris 128 ressort à \(value) — la chaîne colorimétrique dérive")
        }

        // Le maillon qui compte : l'image vient d'un CVPixelBuffer BGRA, le format exact que
        // sert ScreenCaptureKit. C'est ce chemin-là qu'il faut pincer, pas une CIImage construite
        // en mémoire, qui porte déjà son espace et passerait quoi qu'il arrive.
        let buffer = greyPixelBuffer(width: 400, height: 400, value: 128)
        let captured = renderer.source(from: buffer)
        guard let fromCapture = renderer.render(source: captured, crop: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                style: .flou, intensity: .forte) else {
            preconditionFailure("Rendu impossible depuis un tampon de capture")
        }
        let captureValue = middlePixel(of: fromCapture)
        precondition(abs(Int(captureValue) - 128) <= 3,
                     "Un gris 128 capturé ressort à \(captureValue) — la chaîne colorimétrique dérive entre le tampon et l'écran")

        // Un aplat reste un aplat : le filtre ne fabrique pas de bord sombre sur le pourtour.
        guard let flat = renderer.render(source: plate, crop: CGRect(x: 0, y: 0, width: 400, height: 400),
                                         style: .flou, intensity: .maximale) else {
            preconditionFailure("Rendu impossible")
        }
        precondition(abs(Int(cornerPixel(of: flat)) - 128) <= 3,
                     "Les bords sont étendus avant le flou, la zone ne s'assombrit pas sur son pourtour")

        print("ScreenBlur : conversions d'écran et Quartz, bascule Core Image, bornes, tracé, poignées, occlusion, persistance et compatibilité du fichier, styles et chaîne colorimétrique validés")
    }
}

/// Lit la composante bleue (BGRA) du pixel central d'une image rendue.
@MainActor
func middlePixel(of image: CGImage) -> UInt8 {
    pixel(of: image, x: image.width / 2, y: image.height / 2)
}

/// Le pixel du coin, là où un filtre mal borné laisse une frange sombre.
@MainActor
func cornerPixel(of image: CGImage) -> UInt8 {
    pixel(of: image, x: 1, y: 1)
}

@MainActor
func pixel(of image: CGImage, x: Int, y: Int) -> UInt8 {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes[(y * image.width + x) * 4]
}

/// Un tampon BGRA d'un gris uniforme, tel qu'en produit la capture d'écran.
@MainActor
func greyPixelBuffer(width: Int, height: Int, value: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
    guard let buffer else { preconditionFailure("Tampon non créé") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
