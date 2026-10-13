import AppKit
import SwiftUI

struct FolderItem: Identifiable, Codable, Hashable {
    var id = UUID()
    /// A file, folder, app or disk on disk.
    var path: String?
    /// A nested Dockyard folder.
    var linkedFolderID: UUID?

    static func file(_ url: URL) -> FolderItem { FolderItem(path: url.path) }
    static func link(_ id: UUID) -> FolderItem { FolderItem(linkedFolderID: id) }

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    var exists: Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
}

/// What a folder's tile shows. `nil` on a folder means "its contents".
enum FolderIcon: Codable, Hashable {
    case contents
    case symbol(String)
    case emoji(String)
    /// An image file, or an app/.icns whose own icon is used as-is.
    case image(path: String)
}

struct DockFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String = "#3B82F6"
    var items: [FolderItem] = []
    var icon: FolderIcon?
}

enum PopupMaterial: String, Codable, CaseIterable, Identifiable {
    case glass, hud, popover, menu, solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .hud: "Dark Glass"
        case .popover: "Popover"
        case .menu: "Menu"
        case .solid: "Solid"
        }
    }

    var visualEffect: NSVisualEffectView.Material {
        switch self {
        case .glass, .popover: .popover
        case .hud: .hudWindow
        case .menu: .menu
        case .solid: .windowBackground
        }
    }
}

struct Appearance: Codable, Equatable {
    var iconSize: Double = 56
    var columns: Int = 4
    var maxRows: Int = 4
    var showLabels = true
    var showTitle = true
    var material: PopupMaterial = .glass
    var cornerRadius: Double = 24
    var closeAfterOpening = true
    var iconShowsContents = true
    var dockBadge = true

    init() {}

    // Decode leniently so new settings never wipe out a saved configuration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance.defaults
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? d.iconSize
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? d.columns
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? d.maxRows
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? d.showLabels
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? d.showTitle
        material = (try? c.decodeIfPresent(PopupMaterial.self, forKey: .material)) ?? d.material
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        closeAfterOpening = try c.decodeIfPresent(Bool.self, forKey: .closeAfterOpening) ?? d.closeAfterOpening
        iconShowsContents = try c.decodeIfPresent(Bool.self, forKey: .iconShowsContents) ?? d.iconShowsContents
        dockBadge = try c.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? d.dockBadge
    }

    private static let defaults = Appearance()
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

enum FolderColors {
    static let presets = [
        "#3B82F6", "#8B5CF6", "#EC4899", "#EF4444", "#F97316",
        "#EAB308", "#22C55E", "#14B8A6", "#64748B", "#1F2937",
    ]
}

/// Loads file URLs from drag-and-drop providers, preserving their order.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var results = [URL?](repeating: nil, count: providers.count)
    let group = DispatchGroup()
    let lock = NSLock()
    for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            lock.lock()
            results[index] = url
            lock.unlock()
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(results.compactMap { $0 }) }
}
