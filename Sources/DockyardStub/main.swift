import AppKit

// Each Dock folder is a tiny app bundle running this launcher. When clicked in the
// Dock it asks Dockyard to show the folder (through a distributed notification when
// Dockyard is running, else by launching it with a dockyard:// URL); when files are
// dropped onto it, it asks Dockyard to add them. Then it quits immediately.

final class StubDelegate: NSObject, NSApplicationDelegate {
    private var droppedURLs: [URL] = []
    private var forwarded = false

    func application(_ sender: NSApplication, open urls: [URL]) {
        droppedURLs.append(contentsOf: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documents dropped onto the Dock icon are delivered before this point.
        if droppedURLs.isEmpty && signaledEarly {
            NSApp.terminate(nil)
        } else {
            forward()
        }
    }

    private func forward() {
        guard !forwarded else { return }
        forwarded = true

        let info = Bundle.main.infoDictionary ?? [:]
        var components = URLComponents()
        components.scheme = "dockyard"
        components.host = droppedURLs.isEmpty ? "open" : "add"
        let encode: (String) -> String? = { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }
        components.percentEncodedQueryItems =
            [URLQueryItem(name: "id", value: encode(info["DYFolderID"] as? String ?? ""))]
            + droppedURLs.map { URLQueryItem(name: "path", value: encode($0.path)) }

        guard let url = components.url else { return NSApp.terminate(nil) }

        let workspace = NSWorkspace.shared
        let host = (info["DYHostBundleID"] as? String).flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            ?? (info["DYHostPath"] as? String).map { URL(fileURLWithPath: $0) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let done: (NSRunningApplication?, Error?) -> Void = { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        if let host, FileManager.default.fileExists(atPath: host.path) {
            workspace.open([url], withApplicationAt: host, configuration: configuration, completionHandler: done)
        } else {
            workspace.open(url, configuration: configuration, completionHandler: done)
        }
    }
}


// `--register`: Dockyard launches a folder once after re-signing it, so macOS trusts the new
// signature and the Dock will load the folder's tile plugin. Nothing to do beyond launching.
if CommandLine.arguments.contains("--register") { exit(0) }

// Fast path: if Dockyard is running, tell it to open the folder right away, before AppKit
// finishes starting up (that alone takes ~60 ms). Dropped files still follow via forward().
let info = Bundle.main.infoDictionary ?? [:]
let hostBundleID = info["DYHostBundleID"] as? String ?? "com.maxgariepy.Dockyard"
let signaledEarly = !NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID).isEmpty
if signaledEarly {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.maxgariepy.Dockyard.openFolder"),
        object: info["DYFolderID"] as? String ?? "", userInfo: nil, deliverImmediately: true)
}

let app = NSApplication.shared
let delegate = StubDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
