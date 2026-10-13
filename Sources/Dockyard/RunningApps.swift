import AppKit

/// Tracks which apps are running, for the Dock-style dots and the Quit/Hide actions in popups.
@MainActor
final class RunningApps: ObservableObject {
    static let shared = RunningApps()

    /// Bundle identifiers of running apps.
    @Published private(set) var bundleIDs: Set<String> = []
    private var bundleIDCache: [String: String] = [:]

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningApps.shared.refresh() }
            }
        }
    }

    private func refresh() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if ids != bundleIDs { bundleIDs = ids }
    }

    /// Follows the Dock's "Show indicators for open applications" setting.
    var showsIndicators: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "show-process-indicators") as? Bool ?? true
    }

    func isRunning(_ path: String) -> Bool {
        bundleID(for: path).map(bundleIDs.contains) ?? false
    }

    func apps(at path: String) -> [NSRunningApplication] {
        bundleID(for: path).map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []
    }

    func show(_ path: String) {
        apps(at: path).first?.activate()
    }

    func hide(_ path: String) {
        apps(at: path).forEach { $0.hide() }
    }

    /// Asks the app to quit, like Quit in the Dock (it may ask to save documents).
    func quit(_ path: String) {
        apps(at: path).forEach { $0.terminate() }
    }

    private func bundleID(for path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached }
        let id = Bundle(url: URL(fileURLWithPath: path).resolvingSymlinksInPath())?.bundleIdentifier
        bundleIDCache[path] = id
        return id
    }
}
