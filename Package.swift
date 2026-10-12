// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Takeshot",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Automatic updates (https://sparkle-project.org). The framework is
        // copied into the app bundle by the Makefile.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Takeshot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Takeshot",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ApplicationServices"),
                // Find Sparkle.framework inside the app bundle at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
