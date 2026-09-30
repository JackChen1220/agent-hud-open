import AppKit
import CoreGraphics

/// One agent's mark, baked at the size it will be drawn with its outline already in the pixels.
///
/// The outline has to follow the artwork's own silhouette, which no border or single shadow can do for an
/// arbitrary mark. Stacking live shadows does it but costs an offscreen pass per direction per frame, and
/// the queue animates — so the ring is drawn once here instead, from the artwork's alpha, and the animating
/// layer ends up with nothing but a flat image to composite.
@MainActor
enum LogoImages {
    struct Key: Hashable {
        var vendor: String
        /// Side of the mark in device pixels, excluding the outline.
        var side: Int
        /// Outline thickness in device pixels. A hairline: one pixel reads as an edge, more as a border.
        var outline: Int
        /// Which artwork variant to bake, for the vendors that ship one per background. It does not choose
        /// the ink: a single-colour mark is always drawn light, because what sits behind the queue is the
        /// wallpaper, not an app surface, and the system's appearance says nothing about the contrast there.
        var light: Bool
    }

    private static var cache: [Key: CGImage] = [:]

    /// The baked mark, and how far it overflows the nominal side on each edge.
    static func image(_ key: Key) -> CGImage? {
        if let hit = cache[key] { return hit }
        guard let image = render(key) else { return nil }
        if cache.count > 96 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    static func invalidate() { cache.removeAll(keepingCapacity: true) }

    private static func render(_ key: Key) -> CGImage? {
        guard key.side > 0,
              let artwork = AgentArtwork.original(for: key.vendor, light: key.light),
              let mark = cgImage(artwork)
        else { return nil }
        let outline = CGFloat(max(0, key.outline))
        let side = CGFloat(key.side)
        let canvas = Int((side + outline * 2).rounded())
        guard let context = CGContext(
            data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: outline, y: outline, width: side, height: side)

        // The ring is built opaque in its own bitmap and composited once. Drawing the eight offsets straight
        // into this context would let them accumulate where they overlap, which is most of the ring, and the
        // outline would come out near black however low each pass was set.
        if outline > 0, let ring = ring(mark: mark, rect: rect, thickness: outline, canvas: canvas) {
            context.saveGState()
            context.setAlpha(Self.outlineOpacity)
            context.draw(ring, in: CGRect(x: 0, y: 0, width: CGFloat(canvas), height: CGFloat(canvas)))
            context.restoreGState()
        }

        if AgentArtwork.isTemplate(key.vendor) {
            // A single-colour mark carries no colour of its own; it is drawn as a white stencil, with the
            // outline above doing the work on a pale wallpaper.
            context.saveGState()
            context.clip(to: rect, mask: mark)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.restoreGState()
        } else {
            context.draw(mark, in: rect)
        }
        return context.makeImage()
    }

    /// How dark the finished outline is. Enough to separate a white mark from a pale wallpaper, not enough
    /// to read as a border drawn around it.
    private static let outlineOpacity: CGFloat = 0.5
    /// Passes over the ring. Smearing an anti-aliased silhouette leaves a soft edge however thin the offset
    /// is; drawing it again drives the half-covered pixels to opaque, which is what makes the line crisp
    /// rather than a haze around the mark.
    private static let outlinePasses = 3

    /// The eight neighbouring pixels. Offsets taken around a circle instead put the diagonals at 0.707 of a
    /// pixel, which lands off the grid and is resampled into a grey fringe — the thing that makes a hairline
    /// look thick and soft however thin it is asked to be.
    private static let neighbours: [(x: CGFloat, y: CGFloat)] = [
        (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1),
    ]

    /// The mark's silhouette spread one pixel in every direction, with the mark itself knocked back out of
    /// it. Without that the ring survives under the mark's own half-transparent edge and shows through it,
    /// which reads as a thick muddy border rather than an edge.
    private static func ring(mark: CGImage, rect: CGRect, thickness: CGFloat, canvas: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(NSColor.black.cgColor)
        for _ in 0..<outlinePasses {
            for offset in neighbours {
                let shifted = rect.offsetBy(dx: offset.x * thickness, dy: offset.y * thickness)
                context.saveGState()
                context.clip(to: shifted, mask: mark)
                context.fill(shifted)
                context.restoreGState()
            }
        }
        context.setBlendMode(.destinationOut)
        context.draw(mark, in: rect)
        return context.makeImage()
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
