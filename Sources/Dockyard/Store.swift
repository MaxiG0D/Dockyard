import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    nonisolated static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dockyard", isDirectory: true)
    }
    private static var dataURL: URL { supportURL.appendingPathComponent("folders.json") }

    @Published var folders: [DockFolder] = [] { didSet { scheduleFlush() } }
    @Published var appearance = Appearance() {
        didSet {
            guard appearance != oldValue else { return }
            if appearance.iconShowsContents != oldValue.iconShowsContents || appearance.dockBadge != oldValue.dockBadge {
                forceIconSync = true
            }
            scheduleFlush()
        }
    }
    /// Folders currently pinned in the Dock.
    @Published private(set) var dockFolderIDs: Set<UUID> = []
    /// Folders in the Dock whose label changed and need "Update Dock".
    @Published private(set) var staleDockFolderIDs: Set<UUID> = []

    private(set) var isFirstRun = false
    private var loaded = false
    private var synced: [UUID: DockFolder] = [:]
    private var forceIconSync = false
    private var pendingFlush: DispatchWorkItem?

    private struct Persisted: Codable {
        var folders: [DockFolder]
        var appearance: Appearance
    }

    // MARK: - Loading & saving

    func load() {
        guard !loaded else { return }
        if let data = try? Data(contentsOf: Self.dataURL),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            // Drop blank entries left by an earlier bug that accepted drops without a file path.
            folders = saved.folders.map { folder in
                var folder = folder
                folder.items.removeAll { $0.linkedFolderID == nil && ($0.path ?? "").isEmpty }
                return folder
            }
            appearance = saved.appearance
        } else {
            isFirstRun = true
            folders = Self.sampleFolders()
        }
        loaded = true
        refreshDockState()
        forceIconSync = true
        flush()
    }

    private func scheduleFlush() {
        guard loaded else { return }
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flush() {
        pendingFlush = nil
        // Edits may add items or bring missing files back; popups otherwise reuse cached icons.
        IconCache.clear()
        save()
        syncStubs()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.supportURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Persisted(folders: folders, appearance: appearance)).write(to: Self.dataURL, options: .atomic)
        } catch {
            NSLog("Dockyard: save failed: \(error)")
        }
    }

    var resolver: IconRenderer.Resolver {
        let snapshot = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return { snapshot[$0] }
    }

    /// Regenerates bundles for folders that changed, plus folders that display them nested.
    private func syncStubs() {
        let force = forceIconSync
        forceIconSync = false
        let current = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        var changed = Set(folders.filter { force || synced[$0.id] != $0 }.map(\.id))
        changed.formUnion(folders.filter { folder in
            folder.items.contains { $0.linkedFolderID.map(changed.contains) ?? false }
        }.map(\.id))

        for id in Set(synced.keys).subtracting(current.keys) {
            StubManager.remove(id)
        }

        let resolver = self.resolver
        for folder in folders where changed.contains(folder.id) {
            let inDock = dockFolderIDs.contains(folder.id)
            if inDock, let old = synced[folder.id], old.name != folder.name {
                staleDockFolderIDs.insert(folder.id)
            }
            // Renaming a bundle that's in the Dock would break its tile, so wait for "Update Dock".
            StubManager.sync(folder, showsContents: appearance.iconShowsContents, badge: appearance.dockBadge, resolver: resolver, allowRename: !inDock)
        }
        synced = current
    }

    // MARK: - Dock

    func refreshDockState() {
        dockFolderIDs = DockPrefs.folderIDsInDock()
        staleDockFolderIDs.formIntersection(dockFolderIDs)
        staleDockFolderIDs.formUnion(DockPrefs.misplacedFolderIDs())
    }

    func bundleURL(for id: UUID) -> URL? {
        if let existing = StubManager.existingBundle(for: id) { return existing }
        guard let folder = folder(id) else { return nil }
        return StubManager.sync(folder, showsContents: appearance.iconShowsContents, badge: appearance.dockBadge, resolver: resolver, allowRename: true)
    }

    func addToDock(_ id: UUID) {
        guard let folder = folder(id), let url = bundleURL(for: id) else { return }
        DockPrefs.add(id: id, url: url, label: folder.name)
        DockPrefs.restartDock()
        refreshDockState()
    }

    /// Applies renames to Dock tiles and restarts the Dock so icons and labels refresh.
    func updateDock() {
        refreshDockState()
        let resolver = self.resolver
        var targets: [UUID: (url: URL, label: String)] = [:]
        for folder in folders where dockFolderIDs.contains(folder.id) {
            if let url = StubManager.sync(folder, showsContents: appearance.iconShowsContents, badge: appearance.dockBadge, resolver: resolver, allowRename: true) {
                targets[folder.id] = (url, folder.name)
            }
        }
        DockPrefs.update(targets)
        DockPrefs.restartDock()
        staleDockFolderIDs.removeAll()
    }

    func revealInFinder(_ id: UUID) {
        if let url = bundleURL(for: id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Hands out the bundle's real location. Providing it as a file (e.g. `NSItemProvider(object: NSURL)`)
    /// makes SwiftUI drag a temporary copy, and the Dock would keep that frozen copy forever.
    func dragProvider(for id: UUID) -> NSItemProvider {
        guard let url = bundleURL(for: id) else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    // MARK: - Folder editing

    func folder(_ id: UUID) -> DockFolder? {
        folders.first { $0.id == id }
    }

    func update(_ folder: DockFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }), folders[index] != folder else { return }
        folders[index] = folder
    }

    private func mutate(_ id: UUID, _ body: (inout DockFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        body(&folders[index])
    }

    @discardableResult
    func addFolder(named name: String = "New Folder") -> UUID {
        let used = Set(folders.map(\.colorHex))
        let color = FolderColors.presets.first { !used.contains($0) } ?? FolderColors.presets.randomElement()!
        let folder = DockFolder(name: name, colorHex: color)
        folders.append(folder)
        return folder.id
    }

    func deleteFolder(_ id: UUID) {
        if dockFolderIDs.contains(id) {
            DockPrefs.remove([id])
            DockPrefs.restartDock()
        }
        folders.removeAll { $0.id == id }
        for index in folders.indices {
            folders[index].items.removeAll { $0.linkedFolderID == id }
        }
        refreshDockState()
    }

    func insert(_ urls: [URL], into id: UUID, at index: Int? = nil) {
        mutate(id) { folder in
            let existing = Set(folder.items.compactMap(\.path))
            let new = urls.map(\.standardizedFileURL)
                .filter { url in
                    // Drops without a real file behind them (e.g. file promises) arrive with an empty path.
                    !url.path.isEmpty && url.path != "/" && FileManager.default.fileExists(atPath: url.path)
                        && !existing.contains(url.path) && !url.path.contains("/Dockyard/Folders/")
                }
                .map(FolderItem.file)
            let position = min(index ?? folder.items.count, folder.items.count)
            folder.items.insert(contentsOf: new, at: position)
        }
    }

    func addPaths(_ paths: [String], to id: UUID) {
        insert(paths.map { URL(fileURLWithPath: $0) }, into: id)
    }

    /// Uses a picked file as the folder's icon. Apps and .icns files are referenced in place;
    /// images are copied next to the folder's bundle so the icon survives the original moving.
    func setIconImage(from url: URL, for id: UUID) {
        if IconRenderer.usesOwnIcon(url.path) {
            return mutate(id) { $0.icon = .image(path: url.path) }
        }
        let fm = FileManager.default
        let dir = StubManager.directory(for: id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("CustomIcon-") {
            try? fm.removeItem(at: old)
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destination = dir.appendingPathComponent("CustomIcon-\(UUID().uuidString).\(ext)")
        do {
            try fm.copyItem(at: url, to: destination)
            mutate(id) { $0.icon = .image(path: destination.path) }
        } catch {
            NSLog("Dockyard: could not copy icon image: \(error)")
        }
    }

    func link(_ linkedID: UUID, into id: UUID) {
        guard linkedID != id else { return }
        mutate(id) { folder in
            guard !folder.items.contains(where: { $0.linkedFolderID == linkedID }) else { return }
            folder.items.append(.link(linkedID))
        }
    }

    func removeItems(_ itemIDs: Set<UUID>, from id: UUID) {
        mutate(id) { $0.items.removeAll { itemIDs.contains($0.id) } }
    }

    func moveItems(in id: UUID, from source: IndexSet, to destination: Int) {
        mutate(id) { $0.items.move(fromOffsets: source, toOffset: destination) }
    }

    func displayName(for item: FolderItem) -> String {
        if let linkID = item.linkedFolderID { return folder(linkID)?.name ?? "Missing Folder" }
        guard let path = item.path else { return "" }
        return FileManager.default.displayName(atPath: path)
    }

    // MARK: - First run

    private static func sampleFolders() -> [DockFolder] {
        let fm = FileManager.default
        func items(_ paths: [String]) -> [FolderItem] {
            paths.filter { fm.fileExists(atPath: $0) }.map { FolderItem(path: $0) }
        }
        var utilities = DockFolder(name: "Utilities", colorHex: "#64748B")
        utilities.items = items([
            "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Applications/Utilities/Disk Utility.app",
            "/System/Applications/Utilities/Screenshot.app",
            "/System/Applications/Utilities/Console.app",
        ])
        var favorites = DockFolder(name: "Favorites", colorHex: "#3B82F6")
        favorites.items = items([
            "/Applications/Safari.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Reminders.app",
            "/System/Applications/Music.app",
            "/System/Applications/System Settings.app",
        ]) + [.link(utilities.id)]
        return [favorites, utilities]
    }
}
