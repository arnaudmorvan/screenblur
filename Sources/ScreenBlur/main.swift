import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // --apercu <chemin> : pose les masques, écrit l'image telle qu'un partage d'écran la voit,
    // puis sort. Sert à vérifier sans se fier à une impression.
    var previewPath: String?
    if let index = CommandLine.arguments.firstIndex(of: "--apercu"),
       CommandLine.arguments.count > index + 1 {
        previewPath = CommandLine.arguments[index + 1]
    }

    let delegate = AppDelegate(previewPath: previewPath)
    application.delegate = delegate
    application.run()
}
