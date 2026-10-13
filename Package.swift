// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dockyard",
    platforms: [.macOS(.v14)],
    targets: [
        // The menu bar app: settings window, popup panel, stub management.
        .executableTarget(name: "Dockyard", path: "Sources/Dockyard"),
        // The tiny launcher copied into every Dock folder bundle.
        .executableTarget(name: "DockyardStub", path: "Sources/DockyardStub"),
    ]
)
