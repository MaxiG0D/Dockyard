import AppKit

// Dock tile plugin installed in every folder bundle (Contents/PlugIns). The Dock loads it
// for the folder's tile even though the folder app isn't running, which lets the tile carry
// a real notification badge: the total of the folder's apps' badges, sent by Dockyard.
//
// Dockyard broadcasts "com.maxgariepy.Dockyard.tileBadge" with the object "<folderID>|<label>";
// the label rides in the object because the Dock's plugin host doesn't receive userInfo.

@objc(DockyardTilePlugIn)
final class DockyardTilePlugIn: NSObject, NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var observer: NSObjectProtocol?

    private var iconObserver: NSObjectProtocol?
    private var themeObservers: [NSObjectProtocol] = []
    private var themeTimer: Timer?
    /// Whether the icon on show is the dark one.
    private var showingDark: Bool?

    /// Posted when the system appearance or the icon style (Default/Dark/Clear/Tinted) changes.
    private static let themeNotifications = [
        "AppleInterfaceThemeChangedNotification",
        "AppleIconAppearanceThemeChangedNotification",
    ].map { NSNotification.Name($0) }

    /// …/<Folder>.app, from …/<Folder>.app/Contents/PlugIns/DockyardTile.docktileplugin
    private lazy var folderApp: URL = Bundle(for: DockyardTilePlugIn.self).bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private lazy var folderID: String =
        Bundle(url: folderApp)?.object(forInfoDictionaryKey: "DYFolderID") as? String ?? ""

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        let center = DistributedNotificationCenter.default()
        for token in [observer, iconObserver].compactMap({ $0 }) + themeObservers { center.removeObserver(token) }
        observer = nil
        iconObserver = nil
        themeObservers = []
        themeTimer?.invalidate()
        themeTimer = nil
        guard dockTile != nil, !folderID.isEmpty else { return }

        observer = center.addObserver(
            forName: NSNotification.Name("com.maxgariepy.Dockyard.tileBadge"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let payload = note.object as? String else { return }
            let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == self.folderID else { return }
            self.tile?.badgeLabel = parts[1].isEmpty ? nil : String(parts[1])
        }
        // The Dock caches a tile's icon; when the folder's icon changes, draw the new one ourselves.
        iconObserver = center.addObserver(
            forName: NSNotification.Name("com.maxgariepy.Dockyard.tileIcon"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? String == self.folderID else { return }
            self.showCurrentIcon()
        }
        // Switch between the light and dark icon along with the system.
        themeObservers = Self.themeNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The preference is written just before the notification; give it a moment.
                // App icons take a little longer to switch style, so draw again once they have.
                for delay in [0.2, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.showCurrentIcon() }
                }
            }
        }
        // Changing only the icon style posts nothing documented, so also check every few seconds.
        themeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.showingDark != Self.iconsAreDark else { return }
            self.showCurrentIcon()
        }
        // Draw the icon ourselves from the start: the Dock would otherwise show macOS's version of
        // it, which since macOS 26 may be shrunk onto a gray tile.
        showCurrentIcon()
        // Ask Dockyard for the current total (it answers if it's running).
        center.postNotificationName(NSNotification.Name("com.maxgariepy.Dockyard.tileBadgeRequest"),
                                    object: folderID, userInfo: nil, deliverImmediately: true)
    }

    /// Whether the Dock shows dark icons: the icon style's Dark setting, or its Automatic
    /// setting (and macOS before 26, which has no icon style) in Dark Mode.
    private static var iconsAreDark: Bool {
        let any = kCFPreferencesAnyApplication
        CFPreferencesAppSynchronize(any)
        let theme = CFPreferencesCopyAppValue("AppleIconAppearanceTheme" as CFString, any) as? String ?? ""
        if theme.hasSuffix("Dark") { return true }
        if theme.hasSuffix("Light") { return false }
        return CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, any) as? String == "Dark"
    }

    /// A folder using an app's own icon: draw that icon now, so it's in the system's current
    /// style (which Dockyard can't render ahead of time), plus the Dockyard badge if any.
    private func liveIcon(resources: URL, dark: Bool) -> NSImage? {
        // Read the plist itself: Bundle caches it, and the folder's icon may have changed.
        let plist = NSDictionary(contentsOf: folderApp.appendingPathComponent("Contents/Info.plist"))
        guard let path = plist?["DYIconPath"] as? String,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        let badge = NSImage(contentsOf: resources.appendingPathComponent(dark ? "Badge-Dark.png" : "Badge.png"))
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            badge?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private func renderedIcon(resources: URL, dark: Bool) -> NSImage? {
        let darkIcns = resources.appendingPathComponent("AppIcon-Dark.icns")
        let icns = dark && FileManager.default.fileExists(atPath: darkIcns.path)
            ? darkIcns : resources.appendingPathComponent("AppIcon.icns")
        return NSImage(contentsOf: icns)
    }

    private func showCurrentIcon() {
        let resources = folderApp.appendingPathComponent("Contents/Resources")
        let dark = Self.iconsAreDark
        guard let tile, let image = liveIcon(resources: resources, dark: dark) ?? renderedIcon(resources: resources, dark: dark)
        else { return }
        showingDark = dark
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
}
