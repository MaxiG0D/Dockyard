import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Draws folder icons: a rounded, tinted tile showing a 3×3 grid of the folder's contents,
/// using the same padding as macOS app icons so it sits naturally next to them in the Dock.
/// In a dark drawing appearance, tiles follow Apple's dark icon style: a near-black tile with
/// the folder's color carried by the glyph instead of the background.
enum IconRenderer {
    typealias Resolver = (UUID) -> DockFolder?

    static func folderImage(_ folder: DockFolder, size: CGFloat, showsContents: Bool, badge: Bool = false,
                            resolver: @escaping Resolver) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawFolder(folder, in: rect, showsContents: showsContents, badge: badge, resolver: resolver, depth: 0)
            return true
        }
    }

    static func drawFolder(_ folder: DockFolder, in rect: CGRect, showsContents: Bool, badge: Bool = false,
                           resolver: Resolver, depth: Int) {
        let s = rect.width
        let body = rect.insetBy(dx: s * 100 / 1024, dy: s * 100 / 1024)
        let base = NSColor(hex: folder.colorHex) ?? .systemBlue
        let icon = folder.icon ?? (showsContents ? .contents : .symbol(defaultGlyph))
        let dark = drawsDark

        switch icon {
        case .image(let path) where usesOwnIcon(path):
            // Apps and .icns files are already icon-shaped; draw them as they are.
            IconCache.icon(forPath: path).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        case .image(let path):
            drawTile(in: body, color: base, scale: s, shadow: depth == 0)
            NSGraphicsContext.saveGraphicsState()
            tilePath(body).addClip()
            if let image = IconCache.image(atPath: path) {
                image.draw(in: aspectFill(image.size, in: body), from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            drawRim(in: body, scale: s)
        case .symbol(let name):
            drawTile(in: body, color: base, scale: s, shadow: depth == 0)
            drawRim(in: body, scale: s)
            drawGlyph(name, in: body, color: dark ? glyphColor(for: base) : .white)
        case .emoji(let emoji):
            drawTile(in: body, color: base, scale: s, shadow: depth == 0)
            drawRim(in: body, scale: s)
            drawEmoji(emoji, in: body)
        case .contents:
            drawTile(in: body, color: base, scale: s, shadow: depth == 0)
            drawRim(in: body, scale: s)
            if folder.items.isEmpty {
                drawGlyph(defaultGlyph, in: body, color: dark ? glyphColor(for: base) : .white)
            } else {
                drawContents(folder.items, in: body, showsContents: showsContents, resolver: resolver, depth: depth)
            }
        }

        if badge, depth == 0 {
            drawBadge(color: base, body: body, scale: s, dark: dark)
        }
    }

    static let defaultGlyph = "square.grid.2x2.fill"

    /// The app, folder or document whose own icon the folder uses, if any.
    static func ownIconPath(of folder: DockFolder) -> String? {
        if case .image(let path) = folder.icon, usesOwnIcon(path) { return path }
        return nil
    }

    /// Just the Dockyard badge, positioned as on a full folder icon of this size.
    static func drawBadgeLayer(_ folder: DockFolder, in rect: CGRect) {
        let s = rect.width
        drawBadge(color: NSColor(hex: folder.colorHex) ?? .systemBlue,
                  body: rect.insetBy(dx: s * 100 / 1024, dy: s * 100 / 1024), scale: s, dark: drawsDark)
    }

    /// Whether the current drawing appearance is dark (set by `bitmap(pixels:dark:draw:)`
    /// for Dock icons, or by AppKit for images drawn on screen).
    private static var drawsDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The folder's color, lifted a little so it stays vivid on a dark tile.
    private static func glyphColor(for base: NSColor) -> NSColor {
        base.blended(withFraction: 0.2, of: .white) ?? base
    }

    /// Everything except picture files (apps, folders, documents, .icns) supplies its own
    /// Finder icon instead of being drawn as a picture filling the tile.
    static func usesOwnIcon(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let isPicture = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
        return isDirectory.boolValue || ext == "icns" || !isPicture
    }

    /// Apple's app icon shape: a continuous-corner ("squircle") rounded square. Matching it closely
    /// keeps macOS from shrinking the icon onto a gray tile, as it does with nonconforming icons.
    private static func tilePath(_ body: CGRect) -> NSBezierPath {
        squircle(body, radius: body.width * 0.2237)
    }

    private static func squircle(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
    }

    private static func drawTile(in body: CGRect, color base: NSColor, scale s: CGFloat, shadow: Bool) {
        let path = tilePath(body)
        NSGraphicsContext.saveGraphicsState()
        if shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = s * 0.025
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
            shadow.set()
        }
        base.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let top: NSColor, bottom: NSColor
        if drawsDark {
            // Like Apple's dark icons: charcoal with a faint hint of the folder's color.
            top = NSColor(white: 0.2, alpha: 1).blended(withFraction: 0.05, of: base) ?? base
            bottom = NSColor(white: 0.07, alpha: 1).blended(withFraction: 0.03, of: base) ?? base
        } else {
            top = base.blended(withFraction: 0.3, of: .white) ?? base
            bottom = base.blended(withFraction: 0.15, of: .black) ?? base
        }
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
    }

    /// Soft inner highlight along the tile's edge.
    private static func drawRim(in body: CGRect, scale s: CGFloat) {
        let radius = body.width * 0.2237
        NSGraphicsContext.saveGraphicsState()
        tilePath(body).addClip()
        let inset = s * 0.006
        let rim = squircle(body.insetBy(dx: inset, dy: inset), radius: radius - inset)
        rim.lineWidth = s * 0.012
        NSColor.white.withAlphaComponent(drawsDark ? 0.14 : 0.28).setStroke()
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawContents(_ allItems: [FolderItem], in body: CGRect, showsContents: Bool, resolver: Resolver, depth: Int) {
        let items = Array(allItems.prefix(9))
        let inner = body.insetBy(dx: body.width * 0.11, dy: body.width * 0.11)
        let cell = inner.width / 3
        let iconSide = cell * 0.9
        for (index, item) in items.enumerated() {
            let col = CGFloat(index % 3), row = CGFloat(index / 3)
            let frame = CGRect(x: inner.minX + col * cell + (cell - iconSide) / 2,
                               y: inner.maxY - (row + 1) * cell + (cell - iconSide) / 2,
                               width: iconSide, height: iconSide)
            // App icons carry their own transparent padding; grow the frame to compensate.
            let padded = frame.insetBy(dx: -iconSide * 0.1, dy: -iconSide * 0.1)
            if let linkID = item.linkedFolderID {
                if depth < 2, let linked = resolver(linkID) {
                    drawFolder(linked, in: padded, showsContents: showsContents, resolver: resolver, depth: depth + 1)
                }
            } else if let path = item.path {
                IconCache.icon(forPath: path).draw(in: padded, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    private static func drawGlyph(_ name: String, in body: CGRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.38, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let symbol = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                            ?? NSImage(systemSymbolName: defaultGlyph, accessibilityDescription: nil))?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let target = CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.95)
    }

    private static func drawEmoji(_ emoji: String, in body: CGRect) {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: body.width * 0.56)])
        let size = text.size()
        text.draw(at: CGPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2))
    }

    /// The Dockyard mark: a white (or, in dark icons, charcoal) disc with the grid glyph,
    /// tucked into the bottom-right corner.
    private static func drawBadge(color: NSColor, body: CGRect, scale s: CGFloat, dark: Bool) {
        let diameter = body.width * 0.36
        let center = CGPoint(x: body.maxX - diameter * 0.34, y: body.minY + diameter * 0.34)
        let disc = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        shadow.set()
        (dark ? NSColor(white: 0.17, alpha: 1) : .white).setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: s * 0.004, dy: s * 0.004))
        ring.lineWidth = s * 0.008
        color.withAlphaComponent(0.35).setStroke()
        ring.stroke()

        let ink = dark ? glyphColor(for: color) : color.blended(withFraction: 0.1, of: .black) ?? color
        let config = NSImage.SymbolConfiguration(pointSize: diameter * 0.42, weight: .bold)
            .applying(.init(paletteColors: [ink]))
        if let glyph = NSImage(systemSymbolName: defaultGlyph, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = glyph.size
            glyph.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private static func aspectFill(_ size: NSSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Dockyard's own app icon: a blue folder tile with four glass tiles.
    static func drawAppIcon(in rect: CGRect) {
        let folder = DockFolder(name: "Dockyard", colorHex: "#2563EB")
        drawFolder(folder, in: rect, showsContents: false, resolver: { _ in nil }, depth: 0)
    }

    // MARK: - Bitmaps

    /// Draws into a bitmap in a light or dark appearance, whatever the app's own appearance is.
    static func bitmap(pixels: Int, dark: Bool = false, draw: (CGRect) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A multi-resolution image suitable for `NSWorkspace.setIcon`.
    static func iconImage(draw: (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for pixels in [1024, 512, 256, 128, 64, 32] {
            if let rep = bitmap(pixels: pixels, draw: draw) {
                rep.size = NSSize(width: 512, height: 512)
                image.addRepresentation(rep)
            }
        }
        return image
    }

    static func writeICNS(to url: URL, dark: Bool = false, draw: (CGRect) -> Void) throws {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        for pixels in sizes {
            if let image = bitmap(pixels: pixels, dark: dark, draw: draw)?.cgImage {
                CGImageDestinationAddImage(destination, image, nil)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func icon(forPath path: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let image: NSImage
        if FileManager.default.fileExists(atPath: path) {
            // Resolve symlinks (e.g. /Applications/Safari.app) so icons don't get an alias badge.
            image = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        } else {
            image = NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: "Missing")
                ?? NSImage()
        }
        cache[path] = image
        return image
    }

    static func image(atPath path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        let key = "image:" + path
        if let cached = cache[key] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[key] = image
        return image
    }

    static func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
