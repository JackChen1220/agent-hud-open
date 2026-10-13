import AppKit
import AgentHUDCore
import CoreGraphics

/// Everything a bot needs from its mark's artwork, read once: the artwork in light ink, how far it reaches
/// from the body's centre in every direction, the body's own reach, and the mark's colours as a soft field.
///
/// The morph is the first outline relaxing into the second while the artwork fades into the field, which is
/// why both outlines are taken as reach per degree from one centre: any two can be blended angle by angle.
@MainActor
final class BotForm {
    /// Samples round the body, one per degree.
    static let samples = 360
    /// Side of the bitmap the artwork is read at.
    private static let grain = 256

    let vendor: String
    let spec: BotSpec
    let artwork: CGImage
    /// The artwork with its own eyes taken out, for a mark that keeps its artwork and animates them.
    let stripped: CGImage?
    let logoReach: [CGFloat]
    let bodyReach: [CGFloat]
    let field: CGImage?

    private static var cache: [String: BotForm?] = [:]

    static func form(for vendor: String) -> BotForm? {
        let key = AgentArtwork.markKey(vendor)
        if let hit = cache[key] { return hit }
        let form = read(vendor)
        cache[key] = form
        return form
    }

    /// Reads a mark afresh, without the cache.
    static func read(_ vendor: String) -> BotForm? {
        BotSpec.spec(for: vendor).flatMap { BotForm(vendor: vendor, spec: $0) }
    }

    private init?(vendor: String, spec: BotSpec) {
        guard let artwork = Self.lightArtwork(for: vendor), let pixels = Self.pixels(of: artwork) else { return nil }
        self.vendor = vendor
        self.spec = spec
        self.artwork = artwork
        logoReach = Self.reach(alphaOf: pixels, from: spec.center)
        bodyReach = Self.bodyReach(spec, logo: logoReach)
        field = Self.colorField(pixels, skipping: spec.unpainted)
        stripped = spec.ownEyes.flatMap { Self.strip($0, from: artwork, background: spec.ownEyeBackground) }
    }

    // MARK: Artwork

    /// The dark-surface artwork at a fixed size. A single-colour mark carries no colour of its own and is
    /// drawn as a white stencil, the way the logo queue draws it.
    private static func lightArtwork(for vendor: String) -> CGImage? {
        guard let image = AgentArtwork.original(for: vendor, light: false) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let mark = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = bitmap(grain) else { return nil }
        let box = CGRect(x: 0, y: 0, width: grain, height: grain)
        context.interpolationQuality = .high
        if AgentArtwork.isTemplate(vendor) {
            context.clip(to: box, mask: mark)
            context.setFillColor(.white)
            context.fill(box)
        } else {
            context.draw(mark, in: box)
        }
        return context.makeImage()
    }

    private static func strip(_ eyes: [CGRect], from artwork: CGImage, background: RGBA?) -> CGImage? {
        guard let context = bitmap(grain) else { return nil }
        let side = CGFloat(grain)
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Bitmap rows run bottom up; the boxes are measured from the top.
        for eye in eyes {
            let box = CGRect(x: eye.minX * side, y: (1 - eye.maxY) * side,
                             width: eye.width * side, height: eye.height * side).insetBy(dx: -3, dy: -3)
            if let background {
                context.setFillColor(CGColor(red: background.red, green: background.green,
                                             blue: background.blue, alpha: background.alpha))
                context.fill(box)
            } else {
                context.clear(box)
            }
        }
        return context.makeImage()
    }

    static func bitmap(_ side: Int) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Premultiplied RGBA, top row first.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        guard let context = bitmap(grain) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: grain, height: grain))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: grain * grain * 4))
    }

    // MARK: Outlines

    /// How far the opaque pixels reach from `center`, per degree, as a share of the side.
    private static func reach(alphaOf pixels: [UInt8], from center: CGPoint) -> [CGFloat] {
        let side = Double(grain), startX = Double(center.x) * side, startY = Double(center.y) * side
        return pixels.withUnsafeBufferPointer { bytes in
            (0..<samples).map { index in
                let angle = Double(index) * 2 * .pi / Double(samples), dx = cos(angle), dy = sin(angle)
                var last = 0, distance = 0
                while distance < grain * 3 / 2 {
                    let x = Int((startX + dx * Double(distance)).rounded()), y = Int((startY + dy * Double(distance)).rounded())
                    if x < 0 || y < 0 || x >= grain || y >= grain { break }
                    if bytes[(y * grain + x) * 4 + 3] > 127 { last = distance }
                    distance += 1
                }
                return max(0.02, CGFloat(last) / CGFloat(grain))
            }
        }
    }

    private static func smoothed(_ ring: [CGFloat], over width: Int) -> [CGFloat] {
        var current = ring
        let count = ring.count
        for _ in 0..<2 {
            current = (0..<count).map { index in
                var sum: CGFloat = 0
                for offset in -width...width { sum += current[(index + offset + count) % count] }
                return sum / CGFloat(2 * width + 1)
            }
        }
        return current
    }

    private static func bodyReach(_ spec: BotSpec, logo: [CGFloat]) -> [CGFloat] {
        let radius = spec.radius, center = spec.center
        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: center.x + u * radius, y: center.y + v * radius) }
        switch spec.shape {
        case .circle:
            return Array(repeating: radius, count: samples)
        case .outline(let keep, let smooth):
            let soft = smoothed(logo, over: smooth), mean = soft.reduce(0, +) / CGFloat(soft.count)
            return soft.map { max(radius * 0.55, radius * (1 + keep * ($0 / mean - 1))) }
        case .star(let points, let depth, let puff):
            return (0..<samples).map { index in
                let turn = CGFloat(points) * CGFloat(index) * 2 * .pi / CGFloat(samples)
                // A smooth wave is a thin star. Broad round heads with a crease between them read as plump.
                let wave = puff < 1 ? 2 * pow(abs(cos(turn / 2)), puff) - 1 : cos(turn)
                return radius * (1 + depth * wave)
            }
        case .polygon(let sides, let rotation, let round):
            let corners = (0..<sides).map { index -> CGPoint in
                let angle = (rotation + CGFloat(index) * 360 / CGFloat(sides)) * .pi / 180
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            return traced(from: center) { $0.addPath(rounded(corners, radius: round)); $0.fillPath() }
        case .rect(let width, let height, let round):
            let w = width / 2, h = height / 2
            let corners = [CGPoint(x: center.x - w, y: center.y - h), CGPoint(x: center.x + w, y: center.y - h),
                           CGPoint(x: center.x + w, y: center.y + h), CGPoint(x: center.x - w, y: center.y + h)]
            return traced(from: center) { $0.addPath(rounded(corners, radius: round)); $0.fillPath() }
        case .slant(let width, let height, let skew, let round):
            let w = width / 2, h = height / 2, lean = skew / 2
            let corners = [CGPoint(x: center.x - w + lean, y: center.y - h), CGPoint(x: center.x + w + lean, y: center.y - h),
                           CGPoint(x: center.x + w - lean, y: center.y + h), CGPoint(x: center.x - w - lean, y: center.y + h)]
            return traced(from: center) { $0.addPath(rounded(corners, radius: round)); $0.fillPath() }
        case .cat:
            return traced(from: center) { context in
                context.fillEllipse(in: CGRect(x: center.x - 1.02 * radius, y: center.y + (0.1 - 0.88) * radius,
                                               width: 2.04 * radius, height: 1.76 * radius))
                // A round join on a thick stroke is what softens the ear tips.
                context.setLineJoin(.round)
                context.setLineWidth(0.16 * radius)
                for side in [-1.0, 1.0] as [CGFloat] {
                    let ear = CGMutablePath()
                    ear.move(to: at(side * 0.94, -0.02))
                    ear.addLine(to: at(side * 0.78, -1.04))
                    ear.addLine(to: at(side * 0.16, -0.6))
                    ear.closeSubpath()
                    context.addPath(ear)
                    context.drawPath(using: .fillStroke)
                }
            }
        case .bob:
            return traced(from: center) { context in
                let path = CGMutablePath()
                path.move(to: at(-1.14, 0.98))
                path.addQuadCurve(to: at(-0.98, 0.3), control: at(-0.92, 0.72))
                // The dome: half an ellipse over the top, from the left temple to the right.
                for step in 0...48 {
                    let angle = CGFloat.pi + CGFloat(step) / 48 * .pi
                    path.addLine(to: at(0.98 * cos(angle), -0.08 + 0.96 * sin(angle)))
                }
                path.addLine(to: at(0.98, 0.3))
                path.addQuadCurve(to: at(1.14, 0.98), control: at(0.92, 0.72))
                path.addLine(to: at(0.62, 0.9))
                path.addQuadCurve(to: at(-0.62, 0.9), control: at(0, 1.06))
                path.closeSubpath()
                context.addPath(path)
                context.fillPath()
            }
        }
    }

    /// Draws a shape in shares of the side, top left origin, and reads its reach back.
    private static func traced(from center: CGPoint, _ draw: (CGContext) -> Void) -> [CGFloat] {
        guard let context = bitmap(grain) else { return Array(repeating: 0.3, count: samples) }
        context.translateBy(x: 0, y: CGFloat(grain))
        context.scaleBy(x: CGFloat(grain), y: -CGFloat(grain))
        context.setFillColor(.white)
        context.setStrokeColor(.white)
        draw(context)
        guard let data = context.data else { return Array(repeating: 0.3, count: samples) }
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: grain * grain * 4))
        return reach(alphaOf: pixels, from: center)
    }

    private static func rounded(_ corners: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath(), count = corners.count
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: middle(corners[count - 1], corners[0]))
        for index in 0..<count {
            let next = middle(corners[index], corners[(index + 1) % count])
            path.addArc(tangent1End: corners[index], tangent2End: next, radius: radius)
            path.addLine(to: next)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Colour

    /// The mark's colours spread into a field a quarter-side wider than the mark, so a body cut from it
    /// carries each colour where the mark had it, with nothing transparent inside. A mark drawn in one colour
    /// gives a single pixel of it.
    private static func colorField(_ pixels: [UInt8], skipping holes: [CGRect]) -> CGImage? {
        let side = 60, margin = 10, inner = side - 2 * margin, count = side * side
        let colour = UnsafeMutablePointer<Float>.allocate(capacity: count * 3)
        let other = UnsafeMutablePointer<Float>.allocate(capacity: count * 3)
        let known = UnsafeMutablePointer<Bool>.allocate(capacity: count), filled = UnsafeMutablePointer<Bool>.allocate(capacity: count)
        defer { colour.deallocate(); other.deallocate(); known.deallocate(); filled.deallocate() }
        colour.initialize(repeating: 0, count: count * 3)
        known.initialize(repeating: false, count: count)

        var low: (Float, Float, Float) = (255, 255, 255), high: (Float, Float, Float) = (0, 0, 0), sum: (Float, Float, Float) = (0, 0, 0)
        var seen: Float = 0
        pixels.withUnsafeBufferPointer { bytes in
            for y in 0..<inner {
                for x in 0..<inner {
                    let row = Int((Double(y) + 0.5) * Double(grain) / Double(inner)), column = Int((Double(x) + 0.5) * Double(grain) / Double(inner))
                    let source = (row * grain + column) * 4, alpha = Float(bytes[source + 3])
                    if alpha <= 200 { continue }
                    let place = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(inner), y: (CGFloat(y) + 0.5) / CGFloat(inner))
                    if !holes.isEmpty, holes.contains(where: { $0.contains(place) }) { continue }
                    let index = (y + margin) * side + x + margin
                    let red = Float(bytes[source]) / alpha * 255, green = Float(bytes[source + 1]) / alpha * 255, blue = Float(bytes[source + 2]) / alpha * 255
                    colour[index * 3] = red; colour[index * 3 + 1] = green; colour[index * 3 + 2] = blue
                    known[index] = true
                    low = (min(low.0, red), min(low.1, green), min(low.2, blue))
                    high = (max(high.0, red), max(high.1, green), max(high.2, blue))
                    sum = (sum.0 + red, sum.1 + green, sum.2 + blue)
                    seen += 1
                }
            }
        }
        guard seen > 0 else { return nil }
        if high.0 - low.0 < 14, high.1 - low.1 < 14, high.2 - low.2 < 14 {
            return swatch(sum.0 / seen, sum.1 / seen, sum.2 / seen)
        }

        // Every empty cell takes the colour of the nearest painted one along its line, mixed by distance when
        // it lies between two. Rows first; a row with no paint at all is then filled down its columns.
        func spread(lines: Int, length: Int, at cell: (Int, Int) -> Int) {
            filled.update(from: known, count: count)
            for line in 0..<lines {
                var before = -1
                var position = 0
                while position < length {
                    if known[cell(line, position)] { before = position; position += 1; continue }
                    var after = position
                    while after < length, !known[cell(line, after)] { after += 1 }
                    let hasAfter = after < length
                    if before >= 0 || hasAfter {
                        for empty in position..<after {
                            let index = cell(line, empty)
                            let share: Float = before < 0 ? 1 : !hasAfter ? 0 : Float(empty - before) / Float(after - before)
                            let from = before < 0 ? cell(line, after) : cell(line, before)
                            let to = hasAfter ? cell(line, after) : from
                            for channel in 0..<3 {
                                colour[index * 3 + channel] = colour[from * 3 + channel] * (1 - share) + colour[to * 3 + channel] * share
                            }
                            filled[index] = true
                        }
                    }
                    position = after
                }
            }
            known.update(from: filled, count: count)
        }
        spread(lines: side, length: side) { $0 * side + $1 }
        spread(lines: side, length: side) { $1 * side + $0 }

        // Soften it: three passes of a three-cell blur, across and then down.
        for _ in 0..<3 {
            for y in 0..<side {
                for x in 0..<side {
                    let left = max(0, x - 1), right = min(side - 1, x + 1)
                    for channel in 0..<3 {
                        other[(y * side + x) * 3 + channel] = (colour[(y * side + left) * 3 + channel] + colour[(y * side + x) * 3 + channel]
                                                               + colour[(y * side + right) * 3 + channel]) / 3
                    }
                }
            }
            for y in 0..<side {
                let up = max(0, y - 1), down = min(side - 1, y + 1)
                for x in 0..<side {
                    for channel in 0..<3 {
                        colour[(y * side + x) * 3 + channel] = (other[(up * side + x) * 3 + channel] + other[(y * side + x) * 3 + channel]
                                                                + other[(down * side + x) * 3 + channel]) / 3
                    }
                }
            }
        }
        guard let context = bitmap(side), let data = context.data else { return nil }
        let out = data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count {
            for channel in 0..<3 { out[index * 4 + channel] = UInt8(max(0, min(255, colour[index * 3 + channel]))) }
            out[index * 4 + 3] = 255
        }
        return context.makeImage()
    }

    private static func swatch(_ red: Float, _ green: Float, _ blue: Float) -> CGImage? {
        guard let context = bitmap(1) else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(red / 255), green: CGFloat(green / 255), blue: CGFloat(blue / 255), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }
}
