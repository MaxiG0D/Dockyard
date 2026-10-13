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

    private static let stubBinaryHash: String? = stubBinary
        .flatMap { try? Data(contentsOf: $0) }
        .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }

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

        let plistURL = contents.appendingPathComponent("Info.plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: infoPlist(for: folder), format: .xml, options: 0),
           (try? Data(contentsOf: plistURL)) != data {
            try? data.write(to: plistURL)
            needsSigning = true
        }

        let draw: (CGRect) -> Void = { rect in
            IconRenderer.drawFolder(folder, in: rect, showsContents: showsContents, badge: badge, resolver: resolver, depth: 0)
        }

        if needsSigning {
            // codesign refuses bundles carrying a custom icon or Finder metadata, so strip them first.
            NSWorkspace.shared.setIcon(nil, forFile: app.path, options: [])
            run("/usr/bin/xattr", ["-cr", app.path])
            try? IconRenderer.writeICNS(to: resources.appendingPathComponent("AppIcon.icns"), draw: draw)
            run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        } else {
            // Keep the bundled icon current too, for anything that ignores custom icons.
            try? IconRenderer.writeICNS(to: resources.appendingPathComponent("AppIcon.icns"), draw: draw)
        }

        // A custom icon is what the Dock and Finder pick up when contents or color change.
        NSWorkspace.shared.setIcon(IconRenderer.iconImage(draw: draw), forFile: app.path, options: [])
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        LSRegisterURL(app as CFURL, true)
        return app
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    private static func infoPlist(for folder: DockFolder) -> [String: Any] {
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

    static func remove(_ ids: Set<UUID>) {
        write(persistentApps().filter { folderID(of: $0).map { !ids.contains($0) } ?? true })
    }

    static func restartDock() {
        StubManager.run("/usr/bin/killall", ["Dock"])
    }
}
