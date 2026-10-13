import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = Store.shared
    private let navigation = SettingsNavigation()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Folder launchers talk to us through dockyard:// URLs; register before launch
        // finishes so the request that launched us isn't missed.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        store.load()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Folder launchers use this fast path when Dockyard is already running.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.maxgariepy.Dockyard.openFolder"), object: nil, queue: .main
        ) { notification in
            guard let id = (notification.object as? String).flatMap(UUID.init(uuidString:)) else { return }
            MainActor.assumeIsolated { PopupController.shared.toggle(folderID: id) }
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Dockyard")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        if store.isFirstRun { openSettings(selecting: nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(selecting: nil)
        return false
    }

    // MARK: - URL handling

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string), components.scheme == "dockyard"
        else { return }
        let query = components.queryItems ?? []
        guard let id = query.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:)) else { return }

        switch components.host {
        case "open":
            PopupController.shared.toggle(folderID: id)
        case "add":
            store.addPaths(query.filter { $0.name == "path" }.compactMap(\.value), to: id)
            PopupController.shared.showAtMouse(id)
        case "settings":
            openSettings(selecting: id)
        case "show" where ProcessInfo.processInfo.environment["DOCKYARD_DEMO"] != nil:
            // Development: open a popup at an exact point, e.g. for screenshots.
            // dockyard://show?id=<uuid>&x=<pt>&y=<pt>&edge=bottom|left|right|top
            let value = { (name: String) in query.first { $0.name == name }?.value }
            let point = CGPoint(x: Double(value("x") ?? "") ?? 0, y: Double(value("y") ?? "") ?? 0)
            let edge: PopupEdge = switch value("edge") {
            case "left": .left
            case "right": .right
            case "top": .top
            default: .bottom
            }
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
                PopupController.shared.show(id, anchor: point, edge: edge, screen: screen)
            }
        default:
            break
        }
    }

    // MARK: - Settings window

    func openSettings(selecting id: UUID?) {
        if let id { navigation.selection = .folder(id) }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store, navigation: navigation))
            let window = NSWindow(contentViewController: controller)
            window.title = "Dockyard"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 880, height: 580))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("DockyardSettings")
            settingsWindow = window
        }
        // Show in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for folder in store.folders {
            let item = NSMenuItem(title: folder.name, action: #selector(showFolderFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder.id
            item.image = IconRenderer.folderImage(folder, size: 18, showsContents: false, resolver: store.resolver)
            menu.addItem(item)
        }
        if !store.folders.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Update Dock", action: #selector(updateDock), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dockyard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showFolderFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let button = statusItem?.button, let window = button.window, let screen = window.screen
        else { return }
        let frame = window.frame
        // Wait for the menu to finish closing so its click doesn't dismiss the popup.
        DispatchQueue.main.async {
            PopupController.shared.show(id, anchor: CGPoint(x: frame.midX, y: frame.minY), edge: .top, screen: screen)
        }
    }

    @objc private func newFolder() {
        openSettings(selecting: store.addFolder())
    }

    @objc private func showSettings() {
        openSettings(selecting: nil)
    }

    @objc private func updateDock() {
        store.updateDock()
    }

    // MARK: - Main menu (key equivalents for the settings window)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Dockyard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Dockyard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Dockyard", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
