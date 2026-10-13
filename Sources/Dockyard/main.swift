import AppKit

// `Dockyard --render-app-icon <out.icns>` is used by build.sh to produce the app icon.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-app-icon"), flag + 1 < arguments.count {
    do {
        try IconRenderer.writeICNS(to: URL(fileURLWithPath: arguments[flag + 1]), draw: IconRenderer.drawAppIcon(in:))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not write icon: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
