// swift-tools-version:6.0
import PackageDescription

// ScreenBlur — masquer une zone de l'écran pendant un partage d'écran.
// Une seule cible exécutable, sans dépendance. Les tests sont un exécutable
// autonome compilé par scripts/test.sh (pas de XCTest sans Xcode).
let package = Package(
    name: "ScreenBlur",
    platforms: [
        .macOS(.v15) // Sequoia 15 et suivantes
    ],
    targets: [
        .executableTarget(
            name: "ScreenBlur",
            path: "Sources/ScreenBlur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
