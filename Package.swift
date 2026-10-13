// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dockyard",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Automatic updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // The menu bar app: settings window, popup panel, stub management.
        .executableTarget(
            name: "Dockyard",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Dockyard",
            // build.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // The tiny launcher copied into every Dock folder bundle.
        .executableTarget(name: "DockyardStub", path: "Sources/DockyardStub"),
    ]
)
