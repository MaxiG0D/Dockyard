import AppKit
import ApplicationServices
import SwiftUI

/// Reads apps' notification badges (the red numbers on Dock icons) from the Dock's
/// accessibility tree. Running apps always have a Dock tile, even when they live in a
/// Dockyard folder instead of being pinned, so this covers every app that can badge.
/// Requires the Accessibility permission. Only polls while a popup is open.
@MainActor
final class BadgeMonitor: ObservableObject {
    static let shared = BadgeMonitor()

    /// Badge text keyed by bundle identifier.
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var timer: Timer?
    private var bundleIDs: [String: String] = [:]

    func start() {
        guard Store.shared.appearance.showBadges else { return stop() }
        refresh()
        // Ask once, the first time a popup opens; after that the setting explains what's missing.
        let askedKey = "DYAskedForAccessibility"
        if !isTrusted && !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            requestPermission()
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { BadgeMonitor.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
    }

    // MARK: - Lookups for the popup

    func label(forPath path: String) -> String? {
        guard Store.shared.appearance.showBadges, let id = bundleID(for: path) else { return nil }
        return labels[id]
    }

    /// Total of numeric badges in a folder, for nested-folder tiles.
    func total(for folder: DockFolder) -> String? {
        let sum = folder.items.compactMap(\.path).compactMap { label(forPath: $0).flatMap(Int.init) }.reduce(0, +)
        return sum > 0 ? String(sum) : nil
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
