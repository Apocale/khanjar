// swift-tools-version:5.9
import PackageDescription

// NB : machine de dev avec Command Line Tools uniquement (pas de XCTest).
// Les tests vivent dans Sources/Khanjar/Support/SelfTest.swift et
// s'exécutent via `khanjar selftest` (code de sortie ≠ 0 en échec).
// Avant le premier build : ../scripts/fetch-sparkle.sh (build-app.sh le fait seul).
let package = Package(
    name: "Khanjar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "khanjar",
            dependencies: ["Sparkle"],
            path: "Sources/Khanjar",
            linkerSettings: [
                // Dans Khanjar.app, Sparkle.framework est rangé dans Contents/Frameworks ;
                // en développement (`swift build`), SwiftPM le copie à côté du binaire.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
            ]
        ),
        // Mises à jour automatiques. Récupéré et vérifié par scripts/fetch-sparkle.sh
        // (version et empreinte épinglées), jamais commité.
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
    ]
)
