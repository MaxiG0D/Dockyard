import AppKit
import CoreServices
import CryptoKit

/// Creates and maintains the small `.app` bundles that represent each folder in the Dock.
/// Layout: ~/Library/Application Support/Dockyard/Folders/<uuid>/<Name>.app
enum StubManager {
    static var root: URL { Store.supportURL.appendingPathComponent("Folders", isDirectory: true) }

    static func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func existingBundle(for id: UUID) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(at: directory(for: id), includingPropertiesForKeys: nil)
        return contents?.first { $0.pathExtension == "app" }
    }

    static func fileName(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Folder" : cleaned
    }

    /// The launcher binary shipped inside Dockyard.app (or next to it when run from `swift build`).
    static var stubBinary: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DockyardStub"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DockyardStub"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let stubBinaryHash: String? = stubBinary.flatMap(sha256)

    /// The Dock tile plugin shipped inside Dockyard.app; it gives folder tiles a badge.
    static var tilePlugin: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/DockyardTile.docktileplugin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Folders whose tile plugin was replaced since launch. The Dock keeps running the plugin
    /// it loaded until it restarts.
    static var replacedTilePlugin: Set<UUID> = []

    private static let tilePluginHash: String? = tilePlugin
        .flatMap { sha256(of: $0.appendingPathComponent("Contents/MacOS/DockyardTile")) }

    private static func sha256(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    /// Brings the folder's bundle up to date and returns its location.
    @discardableResult
    static func sync(_ folder: DockFolder, showsContents: Bool, badge: Bool, resolver: IconRenderer.Resolver, allowRename: Bool) -> URL? {
        let fm = FileManager.default
        let dir = directory(for: folder.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let desired = dir.appendingPathComponent(fileName(for: folder.name) + ".app", isDirectory: true)
        var app = existingBundle(for: folder.id) ?? desired
        if app != desired, allowRename {
            // Two-step move so case-only renames work on case-insensitive volumes.
            let temp = dir.appendingPathComponent(UUID().uuidString + ".app")
            if (try? fm.moveItem(at: app, to: temp)) != nil {
                app = (try? fm.moveItem(at: temp, to: desired)) != nil ? desired : temp
            }
        }

        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try? fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

        var needsSigning = false

        // Signing rewrites the copied binary, so track which launcher it came from by hash.
        let binary = macOS.appendingPathComponent("DockyardStub")
        let marker = resources.appendingPathComponent("launcher.sha256")
        if let source = stubBinary, let hash = stubBinaryHash,
           !fm.fileExists(atPath: binary.path) || (try? String(contentsOf: marker, encoding: .utf8)) != hash {
            try? fm.removeItem(at: binary)
            do {
                try fm.copyItem(at: source, to: binary)
                try hash.write(to: marker, atomically: true, encoding: .utf8)
                needsSigning = true
            } catch {
                NSLog("Dockyard: could not copy launcher: \(error)")
            }
        } else if stubBinary == nil {
            NSLog("Dockyard: launcher binary not found; build with build.sh")
        }

        // Dock tile plugin, kept signed as shipped (signing the folder bundle doesn't touch it).
        let plugInsDir = contents.appendingPathComponent("PlugIns", isDirectory: true)
        let installedPlugin = plugInsDir.appendingPathComponent("DockyardTile.docktileplugin")
        let pluginMarker = resources.appendingPathComponent("tileplugin.sha256")
        if let source = tilePlugin, let hash = tilePluginHash,
           !fm.fileExists(atPath: installedPlugin.path) || (try? String(contentsOf: pluginMarker, encoding: .utf8)) != hash {
            try? fm.createDirectory(at: plugInsDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: installedPlugin)
            do {
                try fm.copyItem(at: source, to: installedPlugin)
                try hash.write(to: pluginMarker, atomically: true, encoding: .utf8)
                needsSigning = true
                replacedTilePlugin.insert(folder.id)
            } catch {
                NSLog("Dockyard: could not copy Dock tile plugin: \(error)")
            }
        }

        let plistURL = contents.appendingPathComponent("Info.plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: infoPlist(for: folder), format: .xml, options: 0),
           (try? Data(contentsOf: plistURL)) != data {
            try? data.write(to: plistURL)
            needsSigning = true
        }

        let draw: (CGRect) -> Void = { rect in
            IconRenderer.drawFolder(folder, in: rect, showsContents: showsContents, badge: badge, resolver: resolver, depth: 0)
        }

        // The icon lives only in the bundle's icns. A Finder custom icon would be simpler, but it
        // breaks the code signature, and the Dock won't load the tile plugin of an unsigned bundle.
        // AppIcon-Dark.icns is the dark variant; the tile plugin shows it when icons are dark.
        for (name, dark) in [("AppIcon", false), ("AppIcon-Dark", true)] {
            let icnsURL = resources.appendingPathComponent(name + ".icns")
            let rendered = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".icns")
            if (try? IconRenderer.writeICNS(to: rendered, dark: dark, draw: draw)) != nil,
               let data = try? Data(contentsOf: rendered), (try? Data(contentsOf: icnsURL)) != data {
                try? data.write(to: icnsURL)
                needsSigning = true
            }
            try? fm.removeItem(at: rendered)
        }

        // The tile plugin draws folders that use an app's (or file's) own icon live, so the Dock
        // shows that icon in the system's current style; this is the badge it lays on top.
        let wantsBadgeLayer = badge && IconRenderer.ownIconPath(of: folder) != nil
        for (name, dark) in [("Badge", false), ("Badge-Dark", true)] {
            let url = resources.appendingPathComponent(name + ".png")
            if wantsBadgeLayer {
                let data = IconRenderer.bitmap(pixels: 1024, dark: dark) { IconRenderer.drawBadgeLayer(folder, in: $0) }?
                    .representation(using: .png, properties: [:])
                if let data, (try? Data(contentsOf: url)) != data {
                    try? data.write(to: url)
                    needsSigning = true
                }
            } else if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                needsSigning = true
            }
        }

        // Earlier versions set a Finder custom icon; drop it so the signature can be valid.
        if fm.fileExists(atPath: app.appendingPathComponent("Icon\r").path) {
            NSWorkspace.shared.setIcon(nil, forFile: app.path, options: [])
            needsSigning = true
        }

        if needsSigning {
            run("/usr/bin/xattr", ["-cr", app.path]) // codesign rejects Finder metadata
            run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        }
        if needsSigning {
            // The Dock only loads tile plugins of bundles macOS has seen launch with their current
            // signature, so launch the folder once in the background; then refresh its tile icon.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = ["--register"]
            let id = folder.id.uuidString
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    DistributedNotificationCenter.default().postNotificationName(
                        NSNotification.Name("com.maxgariepy.Dockyard.tileIcon"), object: id,
                        userInfo: nil, deliverImmediately: true)
                }
            }
        }
        LSRegisterURL(app as CFURL, true)
        return app
    }

    static func remove(_ id: UUID) {
        if let bundle = existingBundle(for: id) { unregister(bundle) }
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Removes folder bundles that shouldn't be around: those of deleted folders, and frozen
    /// copies earlier versions left in SwiftUI's drag cache (macOS kept them registered, so the
    /// Dock could resolve a tile to a copy without the tile plugin).
    static func cleanUp(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: dir.lastPathComponent), !ids.contains(id) else { continue }
            remove(id)
        }

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for dir in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix("com.apple.SwiftUI.Drag-") {
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let copies = contents.filter {
                $0.pathExtension == "app"
                    && (Bundle(url: $0)?.bundleIdentifier ?? "").hasPrefix("com.maxgariepy.Dockyard.folder.")
            }
            guard !copies.isEmpty else { continue }
            copies.forEach(unregister)
            copies.forEach { try? fm.removeItem(at: $0) }
            if copies.count == contents.count { try? fm.removeItem(at: dir) }
        }
    }

    private static func unregister(_ bundle: URL) {
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            ["-u", bundle.path])
    }

    private static func infoPlist(for folder: DockFolder) -> [String: Any] {
        var plist = basePlist(for: folder)
        if tilePlugin != nil { plist["NSDockTilePlugIn"] = "DockyardTile.docktileplugin" }
        if let path = IconRenderer.ownIconPath(of: folder) { plist["DYIconPath"] = path }
        return plist
    }

    private static func basePlist(for folder: DockFolder) -> [String: Any] {
        [
            "CFBundleExecutable": "DockyardStub",
            "CFBundleIdentifier": "com.maxgariepy.Dockyard.folder.\(folder.id.uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "DYFolderID": folder.id.uuidString,
            "DYHostBundleID": Bundle.main.bundleIdentifier ?? "com.maxgariepy.Dockyard",
            "DYHostPath": Bundle.main.bundlePath,
            // Lets Finder items be dropped onto the Dock icon without making the
            // folder a handler that shows up in "Open With" menus.
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": "Any Item",
                "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "None",
                "LSItemContentTypes": ["public.item", "public.folder", "public.directory", "public.volume"],
            ]],
        ]
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// Reads and edits the Dock's persistent items, the same way `defaults`/dockutil do.
enum DockPrefs {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    static func persistentApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    private static func write(_ apps: [[String: Any]]) {
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private static let bundlePrefix = "com.maxgariepy.Dockyard.folder."

    private static func urlString(of entry: [String: Any]) -> String? {
        ((entry["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }

    /// Identifies a folder tile by its bundle identifier, or failing that by its path.
    private static func folderID(of entry: [String: Any]) -> UUID? {
        if let bundleID = (entry["tile-data"] as? [String: Any])?["bundle-identifier"] as? String,
           bundleID.hasPrefix(bundlePrefix) {
            return UUID(uuidString: String(bundleID.dropFirst(bundlePrefix.count)))
        }
        guard let string = urlString(of: entry), let range = string.range(of: "Dockyard/Folders/") else { return nil }
        return UUID(uuidString: String(string[range.upperBound...].prefix(36)))
    }

    static func folderIDsInDock() -> Set<UUID> {
        Set(persistentApps().compactMap(folderID(of:)))
    }

    /// Folder tiles pointing somewhere other than the live bundle, e.g. a temporary copy
    /// made by a drag. Their icons never update until "Update Dock" repoints them.
    static func misplacedFolderIDs() -> Set<UUID> {
        Set(persistentApps().compactMap { entry in
            guard let id = folderID(of: entry) else { return nil }
            return urlString(of: entry)?.contains("Dockyard/Folders/\(id.uuidString)/") == true ? nil : id
        })
    }

    private static func tileData(id: UUID, url: URL, label: String) -> [String: Any] {
        [
            "bundle-identifier": bundlePrefix + id.uuidString,
            // Tells the Dock this tile has a tile plugin (it caches this per tile).
            "dock-extra": 1,
            "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
            "file-label": label,
            "file-type": 41,
        ]
    }

    static func add(id: UUID, url: URL, label: String) {
        var apps = persistentApps()
        apps.append(["tile-type": "file-tile", "tile-data": tileData(id: id, url: url, label: label)])
        write(apps)
    }

    /// Points existing Dock tiles at the live bundles and refreshes their labels.
    static func update(_ targets: [UUID: (url: URL, label: String)]) {
        let apps = persistentApps().map { entry -> [String: Any] in
            guard let id = folderID(of: entry), let target = targets[id] else { return entry }
            var updated = entry
            updated["tile-data"] = tileData(id: id, url: target.url, label: target.label)
            return updated
        }
        write(apps)
    }

    /// Folder tiles added before the tile plugin existed, which the Dock won't load it for.
    static func folderIDsMissingTilePlugin() -> Set<UUID> {
        Set(persistentApps().compactMap { entry in
            guard let id = folderID(of: entry) else { return nil }
            let extra = (entry["tile-data"] as? [String: Any])?["dock-extra"] as? Int ?? 0
            return extra == 1 ? nil : id
        })
    }

    /// Marks folder tiles as having a tile plugin; takes effect when the Dock restarts.
    static func enableTilePlugin(for ids: Set<UUID>) {
        let apps = persistentApps().map { entry -> [String: Any] in
            guard let id = folderID(of: entry), ids.contains(id), var tile = entry["tile-data"] as? [String: Any]
            else { return entry }
            tile["dock-extra"] = 1
            var updated = entry
            updated["tile-data"] = tile
            return updated
        }
        write(apps)
    }

    static func remove(_ ids: Set<UUID>) {
        write(persistentApps().filter { folderID(of: $0).map { !ids.contains($0) } ?? true })
    }

    static func restartDock() {
        StubManager.run("/usr/bin/killall", ["Dock"])
    }
}
