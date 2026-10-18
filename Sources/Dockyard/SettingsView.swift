import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case folder(UUID)
    case appearance
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SidebarSelection?
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var navigation: SettingsNavigation
    @State private var pendingDelete: DockFolder?

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("Folders") {
                    ForEach(store.folders) { folder in
                        FolderSidebarRow(folder: folder, store: store)
                            .tag(SidebarSelection.folder(folder.id))
                            .contextMenu { folderMenu(folder) }
                    }
                }
                Section("Dockyard") {
                    Label("Appearance", systemImage: "paintpalette")
                        .tag(SidebarSelection.appearance)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        navigation.selection = .folder(store.addFolder())
                    } label: {
                        Label("New Folder", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            switch navigation.selection {
            case .folder(let id) where store.folder(id) != nil:
                FolderDetailView(store: store, folderID: id, onDelete: { pendingDelete = store.folder(id) })
                    .id(id)
            case .appearance:
                AppearanceView(store: store)
            default:
                ContentUnavailableView("No Folder Selected", systemImage: "square.grid.2x2",
                                       description: Text("Pick a folder in the sidebar, or create one with New Folder."))
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            store.refreshDockState()
            if navigation.selection == nil, let first = store.folders.first { navigation.selection = .folder(first.id) }
        }
        .alert("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let folder = pendingDelete {
                    store.deleteFolder(folder.id)
                    navigation.selection = store.folders.first.map { .folder($0.id) }
                }
            }
        } message: {
            Text("The folder is removed from Dockyard and your Dock. The apps and files inside it aren’t touched.")
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: DockFolder) -> some View {
        if !store.dockFolderIDs.contains(folder.id) {
            Button("Add to Dock") { store.addToDock(folder.id) }
        }
        Button("Show in Finder") { store.revealInFinder(folder.id) }
        Divider()
        Button("Delete Folder…", role: .destructive) { pendingDelete = folder }
    }
}

struct FolderIconView: View {
    let folder: DockFolder
    @ObservedObject var store: Store
    let size: CGFloat
    /// Whether to draw the Dockyard badge (when enabled), so previews match the Dock.
    var showsBadge = false
    /// Read so the preview is redrawn, in the dark icon style, when the appearance changes.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: IconRenderer.folderImage(folder, size: max(size * 2, 64),
                                                showsContents: store.appearance.iconShowsContents,
                                                badge: showsBadge && store.appearance.dockBadge,
                                                resolver: store.resolver))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private struct FolderSidebarRow: View {
    let folder: DockFolder
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 8) {
            // Only the icon is a drag source: `.onDrag` on the whole List row swallows the
            // click that selects it.
            FolderIconView(folder: folder, store: store, size: 26)
                .onDrag { store.dragProvider(for: folder.id) }
                .help("Drag to your Dock")
            Text(folder.name.isEmpty ? "Untitled" : folder.name)
                .lineLimit(1)
            Spacer()
            if store.staleDockFolderIDs.contains(folder.id) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Click Update Dock to refresh this folder in the Dock")
            } else if store.dockFolderIDs.contains(folder.id) {
                Image(systemName: "dock.rectangle")
                    .foregroundStyle(.secondary)
                    .help("In your Dock")
            }
        }
    }
}

// MARK: - Folder detail

private struct FolderDetailView: View {
    @ObservedObject var store: Store
    let folderID: UUID
    let onDelete: () -> Void
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false

    private var folder: Binding<DockFolder> {
        Binding(get: { store.folder(folderID) ?? DockFolder(name: "") },
                set: { store.update($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            FolderHeader(store: store, folder: folder)
            Divider()
            itemList
            Divider()
            bottomBar
        }
        .navigationTitle(folder.wrappedValue.name)
    }

    private var itemList: some View {
        List(selection: $selection) {
            ForEach(folder.wrappedValue.items) { item in
                ItemRow(item: item, store: store)
                    .tag(item.id)
                    .contextMenu {
                        if let url = item.url {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                        }
                        Button("Remove from Folder") { remove(selection.contains(item.id) ? selection : [item.id]) }
                    }
            }
            .onMove { store.moveItems(in: folderID, from: $0, to: $1) }
            .onInsert(of: [.fileURL]) { index, providers in
                loadFileURLs(from: providers) { store.insert($0, into: folderID, at: index) }
            }
        }
        .onDeleteCommand { remove(selection) }
        .overlay {
            if folder.wrappedValue.items.isEmpty {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("Drag apps, files, folders or disks here from Finder — or drop them on the folder’s Dock icon.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadFileURLs(from: providers) { store.insert($0, into: folderID) }
                    return true
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                chooseFiles()
            } label: {
                Label("Add Items…", systemImage: "plus")
            }

            Menu {
                let others = store.folders.filter { $0.id != folderID }
                if others.isEmpty {
                    Text("Create another folder first")
                }
                ForEach(others) { other in
                    Button(other.name) { store.link(other.id, into: folderID) }
                }
            } label: {
                Label("Nest Folder", systemImage: "folder.badge.plus")
            }
            .fixedSize()

            Button {
                remove(selection)
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty)

            Spacer()

            Button("Delete Folder…", role: .destructive, action: onDelete)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func remove(_ ids: Set<UUID>) {
        store.removeItems(ids, from: folderID)
        selection.subtract(ids)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            store.insert(panel.urls, into: folderID)
        }
    }
}

private struct FolderHeader: View {
    @ObservedObject var store: Store
    @Binding var folder: DockFolder
    @State private var showingIconPicker = false

    var body: some View {
        let inDock = store.dockFolderIDs.contains(folder.id)
        let stale = store.staleDockFolderIDs.contains(folder.id)

        HStack(alignment: .center, spacing: 18) {
            FolderIconView(folder: folder, store: store, size: 92, showsBadge: true)
                .onDrag { store.dragProvider(for: folder.id) }
                .onTapGesture { showingIconPicker = true }
                .help("Click to change the icon, or drag it to your Dock")
                .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                    IconPicker(store: store, folder: $folder)
                }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Folder Name", text: $folder.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                ColorSwatchRow(hex: $folder.colorHex)
                Text(inDock ? "\(folder.items.count) items · In your Dock"
                            : "\(folder.items.count) items · Drag the icon to your Dock, or click Add to Dock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                if !inDock {
                    Button("Add to Dock") { store.addToDock(folder.id) }
                        .buttonStyle(.borderedProminent)
                } else if stale {
                    Button("Update Dock") { store.updateDock() }
                        .buttonStyle(.borderedProminent)
                        .help("Refresh this folder's Dock icon and name (the Dock restarts briefly)")
                } else {
                    Label("In Dock", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Change Icon…") { showingIconPicker = true }
                Button("Show in Finder") { store.revealInFinder(folder.id) }
            }
        }
        .padding(20)
    }
}

// MARK: - Icon picker

private struct IconPicker: View {
    @ObservedObject var store: Store
    @Binding var folder: DockFolder
    @State private var mode: Mode = .contents
    @State private var symbolQuery = ""
    @State private var emojiText = ""

    enum Mode: String, CaseIterable, Identifiable {
        case contents = "Contents", item = "Item", symbol = "Symbol", emoji = "Emoji", image = "Image"
        var id: String { rawValue }
    }

    private static let symbols = [
        "square.grid.2x2.fill", "folder.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill",
        "sparkles", "leaf.fill", "gamecontroller.fill", "puzzlepiece.fill", "paintpalette.fill", "paintbrush.fill",
        "pencil", "hammer.fill", "wrench.and.screwdriver.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "cpu.fill",
        "music.note", "headphones", "film.fill", "camera.fill", "photo.fill", "tv.fill",
        "book.fill", "books.vertical.fill", "graduationcap.fill", "doc.text.fill", "tray.full.fill", "archivebox.fill",
        "briefcase.fill", "chart.bar.fill", "dollarsign.circle.fill", "cart.fill", "bag.fill", "creditcard.fill",
        "globe", "envelope.fill", "bubble.left.and.bubble.right.fill", "person.2.fill", "calendar", "clock.fill",
        "house.fill", "fork.knife", "cup.and.saucer.fill", "dumbbell.fill", "airplane", "car.fill",
        "gearshape.fill", "lock.fill", "cloud.fill", "map.fill", "shippingbox.fill", "flag.fill",
    ]

    private static let emojis = ["⭐️", "🚀", "🎮", "🎨", "🎵", "🎬", "📚", "💼", "🛠️", "💻", "🧪", "🍳", "🌿", "🔥", "💡", "❤️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Icon", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .contents: contentsPane
                case .symbol: symbolPane
                case .emoji: emojiPane
                case .item: itemPane
                case .image: imagePane
                }
            }
            // Fixed height: a popover doesn't resize when switching tabs, so size it for the tallest one.
            .frame(height: 290, alignment: .top)

            Divider()
            Toggle("Show Dockyard badge on Dock icons", isOn: $store.appearance.dockBadge)
                .help("A small grid mark in the corner so Dockyard folders stand out from apps")
        }
        .padding(16)
        .frame(width: 420)
        .onAppear(perform: syncMode)
        .onChange(of: mode) { _, newMode in apply(newMode) }
    }

    private var contentsPane: some View {
        Text("The icon shows the first nine items in the folder, like a folder on iPhone.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var symbolPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 9), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { name in
                    let selected = folder.icon == .symbol(name)
                    Button {
                        folder.icon = .symbol(name)
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 32)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            HStack {
                TextField("Any SF Symbol name, e.g. “leaf.circle”", text: $symbolQuery)
                    .onSubmit(applySymbolQuery)
                Button("Use", action: applySymbolQuery)
                    .disabled(NSImage(systemSymbolName: symbolQuery, accessibilityDescription: nil) == nil)
            }
        }
    }

    private var emojiPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Type or paste an emoji", text: $emojiText)
                    .onChange(of: emojiText) { _, text in
                        if let last = text.last { folder.icon = .emoji(String(last)) }
                    }
                Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Button {
                        folder.icon = .emoji(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 20))
                            .frame(width: 36, height: 32)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(folder.icon == .emoji(emoji) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Files and apps in this folder (nested folders have no file to borrow an icon from).
    private var itemPaths: [String] {
        folder.items.compactMap(\.path)
    }

    private var itemPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use the icon of something in this folder.")
                .foregroundStyle(.secondary)
            if itemPaths.isEmpty {
                Text("Add apps or files to this folder first.")
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 5), spacing: 8) {
                        ForEach(itemPaths, id: \.self) { path in
                            let selected = folder.icon == .image(path: path)
                            Button {
                                folder.icon = .image(path: path)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(nsImage: IconCache.icon(forPath: path))
                                        .resizable()
                                        .frame(width: 40, height: 40)
                                    Text(FileManager.default.displayName(atPath: path))
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(width: 64, height: 62)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(path)
                        }
                    }
                }
            }
        }
    }

    private var imagePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use a picture, or borrow the icon of an app or folder.")
                .foregroundStyle(.secondary)
            if case .image(let path) = folder.icon {
                Label(IconRenderer.usesOwnIcon(path) ? FileManager.default.displayName(atPath: path) : "Custom image",
                      systemImage: "checkmark.circle.fill")
            }
            Button("Choose Image or App…", action: chooseImage)
        }
    }

    private func syncMode() {
        switch folder.icon {
        case .symbol(let name)?: mode = .symbol; symbolQuery = name
        case .emoji(let emoji)?: mode = .emoji; emojiText = emoji
        case .image(let path)? where itemPaths.contains(path): mode = .item
        case .image?: mode = .image
        case .contents?, nil: mode = .contents
        }
    }

    private func apply(_ mode: Mode) {
        switch (mode, folder.icon) {
        case (.contents, _): folder.icon = nil
        case (.item, .image(let path)?) where itemPaths.contains(path): break
        case (.item, _): folder.icon = itemPaths.first.map { .image(path: $0) }
        case (.symbol, .symbol?), (.emoji, .emoji?), (.image, .image?): break
        case (.symbol, _): folder.icon = .symbol("folder.fill")
        case (.emoji, _): folder.icon = .emoji(emojiText.last.map(String.init) ?? "⭐️")
        case (.image, _): break // wait until something is chosen
        }
    }

    private func applySymbolQuery() {
        let name = symbolQuery.trimmingCharacters(in: .whitespaces)
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            folder.icon = .symbol(name)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .application, .folder, .icns]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Use as Icon"
        if panel.runModal() == .OK, let url = panel.url {
            store.setIconImage(from: url, for: folder.id)
        }
    }
}

private struct ColorSwatchRow: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(FolderColors.presets, id: \.self) { preset in
                Circle()
                    .fill(Color(nsColor: NSColor(hex: preset) ?? .systemBlue).gradient)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                    .padding(2.5)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(preset == hex.uppercased() ? 0.8 : 0), lineWidth: 2))
                    .contentShape(Circle())
                    .onTapGesture { hex = preset }
            }
            ColorPicker("Custom Color", selection: Binding(
                get: { Color(nsColor: NSColor(hex: hex) ?? .systemBlue) },
                set: { hex = NSColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private struct ItemRow: View {
    let item: FolderItem
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let linkID = item.linkedFolderID, let linked = store.folder(linkID) {
                    FolderIconView(folder: linked, store: store, size: 28)
                } else {
                    Image(nsImage: item.path.map(IconCache.icon(forPath:)) ?? NSImage())
                        .resizable()
                        .frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName(for: item))
                Text(item.linkedFolderID != nil ? "Nested folder" : (item.path ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !item.exists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This item no longer exists")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Appearance

private struct AppearanceView: View {
    @ObservedObject var store: Store
    @ObservedObject private var badges = BadgeMonitor.shared
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Popup") {
                LabeledContent("Icon size") {
                    HStack {
                        Slider(value: $store.appearance.iconSize, in: 36...96, step: 4)
                        Text("\(Int(store.appearance.iconSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Stepper("Columns: \(store.appearance.columns)", value: $store.appearance.columns, in: 2...8)
                Stepper("Visible rows: \(store.appearance.maxRows)", value: $store.appearance.maxRows, in: 1...8)
                Picker("Background", selection: $store.appearance.material) {
                    ForEach(PopupMaterial.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Corner radius") {
                    Slider(value: $store.appearance.cornerRadius, in: 8...36, step: 2)
                }
                Toggle("Show item names", isOn: $store.appearance.showLabels)
                Toggle("Show folder title", isOn: $store.appearance.showTitle)
                Picker("Animation", selection: $store.appearance.animationSpeed) {
                    ForEach(PopupAnimation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Close after opening an item", isOn: $store.appearance.closeAfterOpening)
                HStack {
                    Spacer()
                    Button("Preview Popup") { PopupController.shared.showPreview() }
                }
            }

            Section {
                Toggle("Show folder contents on Dock icons", isOn: $store.appearance.iconShowsContents)
                Toggle("Show Dockyard badge on Dock icons", isOn: $store.appearance.dockBadge)
                HStack {
                    Text("If a Dock icon looks out of date, restart the Dock.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Dock") { store.updateDock() }
                }
            } header: {
                Text("Dock Icons")
            }

            Section {
                Toggle("Show notification badges", isOn: $store.appearance.showBadges)
                    .onChange(of: store.appearance.showBadges) { _, enabled in
                        if enabled && !badges.isTrusted { badges.requestPermission() }
                    }
                if store.appearance.showBadges && !badges.isTrusted {
                    HStack {
                        Label("Dockyard needs Accessibility access to read badges from the Dock.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings…") { badges.openAccessibilitySettings() }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Shows apps’ red badge counts on their icons in folder popups, and the total on nested folders.")
                    .foregroundStyle(.secondary)
            }
            .onAppear { badges.refreshTrust() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                badges.refreshTrust()
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!updater.automaticallyChecksForUpdates)
                HStack {
                    Text(Updater.versionDescription).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            }

            Section("General") {
                Toggle("Open Dockyard at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Tips") {
                Label("Click a folder in the Dock to open it. Click again, press Esc or click elsewhere to close it.", systemImage: "cursorarrow.click")
                Label("Drop files onto a folder’s Dock icon (hold over it for a moment) to add them.", systemImage: "tray.and.arrow.down")
                Label("⌘-click an item in a popup to reveal it in Finder.", systemImage: "command")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
