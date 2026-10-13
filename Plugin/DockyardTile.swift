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

    /// …/<Folder>.app, from …/<Folder>.app/Contents/PlugIns/DockyardTile.docktileplugin
    private lazy var folderApp: URL = Bundle(for: DockyardTilePlugIn.self).bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private lazy var folderID: String =
        Bundle(url: folderApp)?.object(forInfoDictionaryKey: "DYFolderID") as? String ?? ""

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        let center = DistributedNotificationCenter.default()
        for token in [observer, iconObserver].compactMap({ $0 }) { center.removeObserver(token) }
        observer = nil
        iconObserver = nil
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
        // Draw the icon ourselves from the start: the Dock would otherwise show macOS's version of
        // it, which since macOS 26 may be shrunk onto a gray tile.
        showCurrentIcon()
        // Ask Dockyard for the current total (it answers if it's running).
        center.postNotificationName(NSNotification.Name("com.maxgariepy.Dockyard.tileBadgeRequest"),
                                    object: folderID, userInfo: nil, deliverImmediately: true)
    }

    private func showCurrentIcon() {
        let icns = folderApp.appendingPathComponent("Contents/Resources/AppIcon.icns")
        guard let tile, let image = NSImage(contentsOf: icns) else { return }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
}
