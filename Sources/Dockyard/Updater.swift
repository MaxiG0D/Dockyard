import Combine
import Sparkle

/// Automatic updates via Sparkle. The feed (SUFeedURL) and signing key (SUPublicEDKey) are in
/// Info.plist; release.sh publishes appcast.xml with every GitHub release.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    @Published private(set) var canCheckForUpdates = false
    private var observation: AnyCancellable?

    private init() {
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
