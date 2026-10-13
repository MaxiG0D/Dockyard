import AppKit
import ApplicationServices
import SwiftUI

/// Reads apps' notification badges (the red numbers on Dock icons) from the Dock's
/// accessibility tree. Running apps always have a Dock tile, even when they live in a
/// Dockyard folder instead of being pinned, so this covers every app that can badge.
/// Requires the Accessibility permission.
///
/// Badges show in two places: on app icons in an open popup, and as a total on each folder's
/// own Dock tile (sent to the Dock tile plugin in the folder bundle). It polls only while a
/// popup is open or a folder is in the Dock.
@MainActor
final class BadgeMonitor: ObservableObject {
    static let shared = BadgeMonitor()

    /// Badge text keyed by bundle identifier.
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private static let tileBadge = NSNotification.Name("com.maxgariepy.Dockyard.tileBadge")
    private static let tileBadgeRequest = NSNotification.Name("com.maxgariepy.Dockyard.tileBadgeRequest")

    private var timer: Timer?
    private var bundleIDs: [String: String] = [:]
    private var popupOpen = false
    private var refreshCount = 0
    /// Last badge sent to each folder's Dock tile.
    private var sentTileLabels: [UUID: String] = [:]

    private init() {
        // A folder tile's plugin asks for its value when the Dock loads it.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.tileBadgeRequest, object: nil, queue: .main
        ) { note in
            guard let id = (note.object as? String).flatMap(UUID.init(uuidString:)) else { return }
            MainActor.assumeIsolated { BadgeMonitor.shared.sendTile(id, force: true) }
        }
        // Tile plugins may load before or after Dockyard starts; send soon after launch either way.
        for delay in [2.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { BadgeMonitor.shared.sendTiles(force: true) }
            }
        }
        // The plugin's request doesn't always get through from the Dock's sandboxed helper,
        // so resend everything once a restarted Dock has had time to load its tile plugins.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            for delay in [1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { BadgeMonitor.shared.sendTiles(force: true) }
                }
            }
        }
    }

    func popupDidOpen() {
        popupOpen = true
        // Ask once, the first time a popup opens; after that the setting explains what's missing.
        let askedKey = "DYAskedForAccessibility"
        if Store.shared.appearance.showBadges && !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            requestPermission()
        }
        update()
    }

    func popupDidClose() {
        popupOpen = false
        update()
    }

    /// Starts or stops polling to match the settings, open popups and folders in the Dock.
    func update() {
        let store = Store.shared
        let active = store.appearance.showBadges && (popupOpen || !store.dockFolderIDs.isEmpty)
        if active {
            refresh()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated { BadgeMonitor.shared.refresh() }
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            if !labels.isEmpty { labels = [:] }
            sendTiles()
        }
    }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshTrust() {
        isTrusted = AXIsProcessTrusted()
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            if !labels.isEmpty { labels = [:] }
            return
        }

        var found: [String: String] = [:]
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in Self.children(of: root) {
            for tile in Self.children(of: list) {
                guard let label = Self.attribute(tile, "AXStatusLabel") as? String, !label.isEmpty,
                      let url = Self.attribute(tile, kAXURLAttribute) as? URL,
                      let id = bundleID(for: url.path)
                else { continue }
                found[id] = label
            }
        }
        if found != labels { labels = found }
        // Resend unchanged values now and then, in case a tile plugin loaded after the last send.
        refreshCount += 1
        sendTiles(force: refreshCount % 8 == 0)
    }

    // MARK: - Folder tiles in the Dock

    private func sendTiles(force: Bool = false) {
        for id in Set(Store.shared.dockFolderIDs).union(sentTileLabels.keys) {
            sendTile(id, force: force)
        }
    }

    private func sendTile(_ id: UUID, force: Bool) {
        let store = Store.shared
        let label = store.appearance.showBadges && store.dockFolderIDs.contains(id)
            ? store.folder(id).flatMap { total(for: $0) } ?? ""
            : ""
        guard force || sentTileLabels[id, default: ""] != label else { return }
        sentTileLabels[id] = label.isEmpty ? nil : label
        DistributedNotificationCenter.default().postNotificationName(
            Self.tileBadge, object: "\(id.uuidString)|\(label)", userInfo: nil, deliverImmediately: true)
    }

    // MARK: - Lookups for the popup

    func label(forPath path: String) -> String? {
        guard Store.shared.appearance.showBadges, let id = bundleID(for: path) else { return nil }
        return labels[id]
    }

    /// A folder's badge: the sum of its apps' counts (including one level of nested folders),
    /// or a dot when apps only show non-numeric badges.
    func total(for folder: DockFolder, depth: Int = 0) -> String? {
        var sum = 0
        var hasOther = false
        for item in folder.items {
            if let path = item.path, let label = label(forPath: path) {
                if let count = Int(label) { sum += count } else { hasOther = true }
            } else if depth == 0, let linked = item.linkedFolderID.flatMap(Store.shared.folder),
                      let nested = total(for: linked, depth: 1) {
                if let count = Int(nested) { sum += count } else { hasOther = true }
            }
        }
        if sum > 0 { return String(sum) }
        return hasOther ? "•" : nil
    }

    private func bundleID(for path: String) -> String? {
        if let cached = bundleIDs[path] { return cached }
        let id = Bundle(url: URL(fileURLWithPath: path).resolvingSymlinksInPath())?.bundleIdentifier
        bundleIDs[path] = id
        return id
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// A red notification badge, styled like the Dock's.
struct NotificationBadge: View {
    let text: String
    let iconSize: CGFloat

    var body: some View {
        let height = max(16, iconSize * 0.34)
        Text(text)
            .font(.system(size: height * 0.62, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .fixedSize()
    }
}
