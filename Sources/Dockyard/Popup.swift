import AppKit
import SwiftUI

enum PopupEdge { case bottom, left, right, top }

struct PopupLayout {
    let columns: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let padding: CGFloat = 14
    let headerHeight: CGFloat
    let needsScrolling: Bool
    let contentSize: CGSize

    init(itemCount: Int, appearance a: Appearance, showHeader: Bool) {
        let n = max(itemCount, 1)
        columns = max(1, min(a.columns, n))
        // Wide enough for two lines of ~18 characters, so typical app names fit whole.
        cellWidth = max(a.iconSize + 44, 104)
        cellHeight = a.iconSize + (a.showLabels ? 46 : 14)
        headerHeight = showHeader ? 38 : 0
        let rows = Int(ceil(Double(n) / Double(columns)))
        needsScrolling = rows > max(a.maxRows, 1)
        let width = max(CGFloat(columns) * cellWidth + padding * 2, 220)
        let height = CGFloat(min(rows, max(a.maxRows, 1))) * cellHeight + padding * 2 + headerHeight
        contentSize = CGSize(width: width, height: height)
    }
}

@MainActor
final class PopupModel: ObservableObject {
    @Published var stack: [UUID] = []
    @Published var shown = false
    @Published var anchor: UnitPoint = .bottom
    @Published var navigatingForward = true
    var current: UUID? { stack.last }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupController {
    static let shared = PopupController()
    /// Transparent room around the popup for its shadow and spring overshoot. Must exceed the
    /// shadow's full extent (blur + offset), or the shadow is clipped into a visible rectangle.
    static let margin: CGFloat = 64

    let model = PopupModel()
    private let store = Store.shared
    private var panel: PopupPanel?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var anchorPoint: CGPoint = .zero
    private var edge: PopupEdge = .bottom
    private var screen: NSScreen?
    /// A click on the Dock icon closes the popup before the launcher's "open" request arrives;
    /// remember it so that request doesn't immediately reopen it.
    private var suppressReopen: (id: UUID, until: Date)?

    var isVisible: Bool { panel?.isVisible == true && model.shown }

    // MARK: - Showing

    func toggle(folderID: UUID) {
        if isVisible, model.stack.first == folderID { return close() }
        if let suppress = suppressReopen, suppress.id == folderID, Date() < suppress.until {
            suppressReopen = nil
            return
        }
        showAtMouse(folderID)
    }

    func showAtMouse(_ id: UUID) {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        show(id, anchor: point, edge: Self.dockEdge(near: point, on: screen), screen: screen)
    }

    func show(_ id: UUID, anchor: CGPoint, edge: PopupEdge, screen: NSScreen) {
        guard store.folder(id) != nil else { return NSSound.beep() }
        anchorPoint = anchor
        self.edge = edge
        self.screen = screen

        let panel = self.panel ?? makePanel()
        model.navigatingForward = true
        model.stack = [id]
        let frame = frame(for: contentSize())
        panel.setFrame(frame, display: false)
        model.anchor = unitAnchor(in: frame)

        if !panel.isVisible { model.shown = false }
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        DispatchQueue.main.async {
            withAnimation(self.store.appearance.animationSpeed.open) { self.model.shown = true }
        }
    }

    func showPreview() {
        guard let first = store.folders.first, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        show(first.id, anchor: CGPoint(x: vf.midX, y: vf.minY), edge: .bottom, screen: screen)
    }

    func close() {
        removeMonitors()
        guard panel?.isVisible == true else { return }
        let duration = store.appearance.animationSpeed.closeDuration
        withAnimation(duration > 0 ? .easeIn(duration: duration) : nil) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Navigation & actions

    func open(_ item: FolderItem) {
        if let linkID = item.linkedFolderID {
            return navigate(to: linkID)
        }
        guard let url = item.url else { return }
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        if store.appearance.closeAfterOpening { close() }
    }

    func navigate(to id: UUID) {
        guard store.folder(id) != nil else { return }
        model.navigatingForward = true
        withAnimation(store.appearance.animationSpeed.navigation) { model.stack.append(id) }
        resizeForCurrentFolder()
    }

    func goBack() {
        guard model.stack.count > 1 else { return }
        model.navigatingForward = false
        withAnimation(store.appearance.animationSpeed.navigation) { _ = model.stack.removeLast() }
        resizeForCurrentFolder()
    }

    func openSettings() {
        close()
        (NSApp.delegate as? AppDelegate)?.openSettings(selecting: model.current)
    }

    private func resizeForCurrentFolder() {
        guard let panel else { return }
        let frame = frame(for: contentSize())
        panel.setFrame(frame, display: true, animate: store.appearance.animationSpeed != .off)
        model.anchor = unitAnchor(in: frame)
    }

    // MARK: - Geometry

    private func contentSize() -> CGSize {
        let folder = model.current.flatMap(store.folder)
        let showHeader = store.appearance.showTitle || model.stack.count > 1
        return PopupLayout(itemCount: folder?.items.count ?? 0, appearance: store.appearance, showHeader: showHeader).contentSize
    }

    private func frame(for content: CGSize) -> NSRect {
        let m = Self.margin, gap: CGFloat = 8
        let vf = screen?.visibleFrame ?? .zero
        let size = CGSize(width: content.width + m * 2, height: content.height + m * 2)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, hi)) }
        let x = clamp(anchorPoint.x - size.width / 2, vf.minX + gap - m, vf.maxX - gap + m - size.width)
        let y = clamp(anchorPoint.y - size.height / 2, vf.minY + gap - m, vf.maxY - gap + m - size.height)

        switch edge {
        case .bottom:
            return NSRect(x: x, y: max(vf.minY, anchorPoint.y + 36) + gap - m, width: size.width, height: size.height)
        case .top:
            return NSRect(x: x, y: anchorPoint.y - gap + m - size.height, width: size.width, height: size.height)
        case .left:
            return NSRect(x: max(vf.minX, anchorPoint.x + 36) + gap - m, y: y, width: size.width, height: size.height)
        case .right:
            return NSRect(x: min(vf.maxX, anchorPoint.x - 36) - gap + m - size.width, y: y, width: size.width, height: size.height)
        }
    }

    /// Where the popup grows from, in SwiftUI's top-left coordinate space.
    private func unitAnchor(in frame: NSRect) -> UnitPoint {
        let x = (anchorPoint.x - frame.minX) / frame.width
        let y = 1 - (anchorPoint.y - frame.minY) / frame.height
        return UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    static func dockEdge(near point: CGPoint, on screen: NSScreen) -> PopupEdge {
        let vf = screen.visibleFrame
        if point.y < vf.minY { return .bottom }
        if point.x < vf.minX { return .left }
        if point.x > vf.maxX { return .right }
        if point.y > vf.maxY { return .top }
        // Auto-hidden Dock: fall back to its configured position.
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    // MARK: - Panel & event monitors

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: PopupRootView(model: model, store: store, controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocal(event) ?? event }
        }) {
            monitors.append(local)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    private func clickedOutside() {
        let point = NSEvent.mouseLocation
        if let screen, !NSMouseInRect(point, screen.visibleFrame, false), let root = model.stack.first {
            suppressReopen = (root, Date().addingTimeInterval(1.5))
        }
        close()
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: // Escape
                close()
                return nil
            case 51 where model.stack.count > 1, 123 where model.stack.count > 1: // Delete / ←
                goBack()
                return nil
            default:
                return event
            }
        }
        if event.window !== panel {
            close()
        } else if let panel {
            let inner = panel.contentView?.bounds.insetBy(dx: Self.margin, dy: Self.margin) ?? .zero
            if !inner.contains(event.locationInWindow) { close() }
        }
        return event
    }
}

// MARK: - Views

struct PopupRootView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var store: Store
    let controller: PopupController
    @State private var dropTargeted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: store.appearance.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let id = model.current, let folder = store.folder(id) {
                FolderPage(folder: folder, model: model, store: store, controller: controller)
                    .id(id)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.navigatingForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: model.navigatingForward ? .leading : .trailing).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .background { PopupBackground(material: store.appearance.material, shape: shape) }
        .overlay {
            shape.strokeBorder(dropTargeted ? Color.accentColor : Color.white.opacity(0.18), lineWidth: dropTargeted ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .environment(\.colorScheme, store.appearance.material == .hud ? .dark : colorSchemeFromSystem)
        .padding(PopupController.margin)
        .scaleEffect(model.shown ? 1 : store.appearance.animationSpeed.startScale, anchor: model.anchor)
        .opacity(model.shown ? 1 : 0)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let id = model.current else { return false }
            loadFileURLs(from: providers) { store.insert($0, into: id) }
            return true
        }
    }

    private var colorSchemeFromSystem: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

private struct PopupBackground: View {
    let material: PopupMaterial
    let shape: RoundedRectangle

    var body: some View {
        if material == .glass, #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            VisualEffectView(material: material.visualEffect).clipShape(shape)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

private struct FolderPage: View {
    let folder: DockFolder
    @ObservedObject var model: PopupModel
    @ObservedObject var store: Store
    let controller: PopupController

    var body: some View {
        let a = store.appearance
        let nested = model.stack.count > 1
        let layout = PopupLayout(itemCount: folder.items.count, appearance: a, showHeader: a.showTitle || nested)

        VStack(spacing: 0) {
            if layout.headerHeight > 0 {
                ZStack {
                    Text(folder.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 44)
                    HStack {
                        if nested {
                            HeaderButton(symbol: "chevron.left", help: "Back") { controller.goBack() }
                        }
                        Spacer()
                        HeaderButton(symbol: "slider.horizontal.3", help: "Edit Folder") { controller.openSettings() }
                    }
                    .padding(.horizontal, 10)
                }
                // Top inset lives inside headerHeight so the popup's computed size matches exactly.
                .padding(.top, 4)
                .frame(height: layout.headerHeight)
            }

            if folder.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                    Text("Drop apps or files here").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cellWidth), spacing: 0), count: layout.columns), spacing: 0) {
                    ForEach(folder.items) { item in
                        ItemCell(item: item, store: store, controller: controller, folderID: folder.id, layout: layout)
                    }
                }
                .padding(layout.padding)

                // Only scroll when there are more rows than fit; an always-present scroll view
                // flashes its scroller whenever the popup opens.
                if layout.needsScrolling {
                    ScrollView(.vertical) { grid }
                } else {
                    grid.frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ItemCell: View {
    let item: FolderItem
    @ObservedObject var store: Store
    let controller: PopupController
    let folderID: UUID
    let layout: PopupLayout
    @State private var hovering = false

    var body: some View {
        let size = store.appearance.iconSize
        VStack(spacing: 4) {
            icon
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .opacity(item.exists ? 1 : 0.4)
                .scaleEffect(hovering ? 1.06 : 1)
            if store.appearance.showLabels {
                Text(store.displayName(for: item))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .frame(width: layout.cellWidth - 8, height: 28, alignment: .top)
            }
        }
        .frame(width: layout.cellWidth, height: layout.cellHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { controller.open(item) }
        .onDrag { item.url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
        .help(item.path ?? store.displayName(for: item))
        .contextMenu {
            if item.linkedFolderID == nil {
                Button("Open") { controller.open(item) }
                Button("Show in Finder") {
                    if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
            }
            Button("Remove from Folder") { store.removeItems([item.id], from: folderID) }
        }
    }

    private var icon: Image {
        if let linkID = item.linkedFolderID, let linked = store.folder(linkID) {
            return Image(nsImage: IconRenderer.folderImage(linked, size: 128, showsContents: true, resolver: store.resolver))
        }
        return Image(nsImage: item.path.map(IconCache.icon(forPath:)) ?? NSImage())
    }
}
