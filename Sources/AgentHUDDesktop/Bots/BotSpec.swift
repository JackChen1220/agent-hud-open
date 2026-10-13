import AgentHUDCore
import CoreGraphics
import Foundation

/// What an agent's mark turns into while its agent is in flight: a small body in the mark's own outline and
/// colour, with two eyes and nothing else.
///
/// Positions on the mark are shares of its side, measured from the top left with y running down, the way
/// artwork is read. Sizes on the body — eyes, a hat, a moustache — are in body radii from the body's centre,
/// so a bot can be resized by its radius alone.
struct BotSpec: Sendable {
    enum Shape: Sendable {
        /// The mark's own outline, averaged over `smooth` degrees and pulled in to `keep` of its relief.
        case outline(keep: CGFloat, smooth: Int)
        case circle
        /// Evenly spaced heads. `puff` below 1 broadens each head and leaves a crease between two.
        case star(points: Int, depth: CGFloat, puff: CGFloat)
        case polygon(sides: Int, rotation: CGFloat, round: CGFloat)
        case rect(width: CGFloat, height: CGFloat, round: CGFloat)
        case slant(width: CGFloat, height: CGFloat, skew: CGFloat, round: CGFloat)
        /// A wide head with two ears.
        case cat
        /// A dome of hair that falls straight and flicks out at the ends.
        case bob
    }

    enum Paint: Sendable {
        /// The mark's own colours, spread into a soft field so the body carries each where the mark had it.
        case artwork
        case solid(RGBA)
        /// Gradient ends and centres are shares of the body's own box, so the paint travels with the body.
        case linear(from: CGPoint, to: CGPoint, stops: [RGBA])
        case radial(center: CGPoint, inner: CGFloat, outer: CGFloat, stops: [RGBA])
    }

    struct Eye: Sendable {
        var height: CGFloat = 0.62
        var width: CGFloat = 0.25
        /// 1 is a capsule, 0 a block.
        var round: CGFloat = 1
        /// How far each eye sits from the middle of the face, as an angle round the body in radians.
        var spread: CGFloat = 0.34
    }

    /// A second colour laid inside the body: the face panel of a head.
    struct Patch: Sendable {
        var box: CGRect
        var round: CGFloat
        var paint: Paint
    }

    /// A ring round the body: its far side hidden by the body, its near side drawn across it.
    struct Ring: Sendable {
        var radiusX: CGFloat
        var radiusY: CGFloat
        var drop: CGFloat
        var tilt: CGFloat
        var width: CGFloat
    }

    enum Decor: Sendable {
        /// Rounded pieces in one colour laid on the body and kept to its outline, later ones over earlier:
        /// a fringe, a scarf. `round` 1 is a full capsule or ball, 0 a block.
        case soft([CGRect], RGBA, round: CGFloat)
        /// Thin lines with round ends that stand behind the body, so only what clears its outline shows:
        /// a pair of antennae.
        case feelers([[CGPoint]], RGBA, width: CGFloat)
        /// Filled blocks, such as hair or a hat. `followsFace` rides with the eyes when the bot looks around.
        case blocks([CGRect], RGBA, followsFace: Bool)
        /// Pieces taken out of the silhouette.
        case cut([CGRect])
        case notch([CGPoint])
        /// A dark line drawn on the body.
        case line([CGPoint], width: CGFloat)
    }

    var radius: CGFloat = 0.36
    var center = CGPoint(x: 0.5, y: 0.5)
    /// How far the face may travel across the body, as a share of a full turn of the head.
    var reach: CGFloat = 1
    var shape: Shape = .circle
    var paint: Paint = .artwork
    /// Where the face rests, in body radii from the centre.
    var face = CGPoint.zero
    var eye = Eye()
    /// Nil draws the eyes in the island's own dark, which reads as cut out on any body.
    var eyeColor: RGBA? = nil
    var pupil: RGBA? = nil
    var patch: Patch? = nil
    var ring: Ring? = nil
    var stroke: RGBA? = nil
    var decor: [Decor] = []
    /// Degrees per second the body turns under a still face while its agent works.
    var spin: CGFloat = 0
    /// A piece of the artwork that stays as drawn and hops above the body.
    var keeps: CGRect? = nil
    /// The mark already is a character and keeps its artwork; only the eyes inside these boxes come alive.
    var ownEyes: [CGRect]? = nil
    /// The artwork beneath its eyes, when removing them needs paint rather than transparency.
    var ownEyeBackground: RGBA? = nil
    /// Parts of the artwork left out of the body's colours: the mark's own eyes, which would smudge the body.
    var unpainted: [CGRect] = []
    /// How far below its logo the finished bot sits, as a share of the mark's side. The move happens with
    /// the morph, for a body that would otherwise stand higher or lower than its neighbours.
    var settle: CGFloat = 0

    /// A mark with no entry stays a logo: it moves as a whole and has no face.
    static func spec(for vendor: String) -> BotSpec? {
        table[AgentArtwork.markKey(vendor).replacingOccurrences(of: "-dark", with: "")]
    }

    private static let grey = RGBA(hex: 0x4b4646)
    private static let hair = RGBA(hex: 0xb7b6c2)

    static let table: [String: BotSpec] = [
        "Claude": BotSpec(radius: 0.375, reach: 0.9, shape: .star(points: 12, depth: 0.085, puff: 0.7), spin: 9),
        // The knot's own six lobes, deepened: a body that is nearly round turns without anyone seeing it turn.
        "ChatGPT": BotSpec(radius: 0.37, shape: .outline(keep: 1.1, smooth: 5), spin: 7),
        // The arch gives a dome that runs from 0.05 to 0.77 down the mark, where a ball beside it runs from
        // 0.14 to 0.86. The finished bot settles by that difference, so its top and bottom line up with theirs.
        "Antigravity": BotSpec(reach: 0.75, shape: .outline(keep: 0.5, smooth: 16), face: CGPoint(x: 0, y: -0.2),
                               settle: 0.093),
        // A ball like any other but for a whale's pale belly, which is what tells it from the plain balls.
        "DeepSeek": BotSpec(face: CGPoint(x: 0, y: -0.14),
                            decor: [.soft([rect(-0.86, 0.34, 0.86, 1.9)], RGBA(hex: 0xc9d4ff), round: 1)]),
        "Grok": BotSpec(radius: 0.33, reach: 0.55, face: CGPoint(x: 0, y: -0.3),
                        ring: Ring(radiusX: 1.5, radiusY: 0.32, drop: 0.3, tilt: -20, width: 0.14)),
        // Grok's bot is one flat colour with eyes in the other: black on a light ground, white on a dark one.
        // Bots are drawn on the island's black and over wallpapers in light ink, so this one is the white ball
        // with dark eyes its own wordmark shows on black.
        "Grok Bot": BotSpec(radius: 0.37, paint: .solid(RGBA(hex: 0xffffff)), eye: Eye(height: 0.78, width: 0.3)),
        // The logo's cut, as a notch in the edge it was taken from.
        "Cursor": BotSpec(radius: 0.41, reach: 0.7, shape: .polygon(sides: 6, rotation: -90, round: 0.07),
                          face: CGPoint(x: -0.12, y: 0.16),
                          decor: [.notch([CGPoint(x: 0.32, y: -0.954), CGPoint(x: 0.75, y: -0.704),
                                          CGPoint(x: 0.266, y: -0.361)])]),
        // A cap of hair with uneven locks and a moustache, both in the logo's grey.
        "OpenCode": BotSpec(reach: 0.5, shape: .rect(width: 0.66, height: 0.66, round: 0.04),
                            paint: .solid(RGBA(hex: 0xf1ecec)), face: CGPoint(x: 0, y: -0.02),
                            eye: Eye(height: 0.4, width: 0.24, round: 0.12),
                            decor: [.blocks([rect(-1.0, -1.06, 1.0, -0.56), rect(-1.0, -0.56, -0.62, -0.36),
                                             rect(-0.24, -0.56, 0.16, -0.42), rect(0.58, -0.56, 1.0, -0.3)],
                                            grey, followsFace: false),
                                    .blocks([rect(-0.6, 0.36, 0.6, 0.6)], grey, followsFace: true)]),
        "Kimi": BotSpec(radius: 0.32, center: CGPoint(x: 0.41, y: 0.59), shape: .outline(keep: 0.3, smooth: 22),
                        keeps: CGRect(x: 0.78, y: 0.02, width: 0.215, height: 0.215)),
        "GLM": BotSpec(shape: .rect(width: 0.74, height: 0.74, round: 0.16), paint: .solid(RGBA(hex: 0x28282b)),
                       eyeColor: RGBA(hex: 0xffffff), stroke: RGBA(hex: 0xffffff)),
        // The letter itself, in one piece: a wide bar that holds the face, standing on two legs.
        "Pi": BotSpec(center: CGPoint(x: 0.5, y: 0.31), reach: 0.3, shape: .rect(width: 0.9, height: 0.29, round: 0.02),
                      eye: Eye(height: 0.3, width: 0.3, round: 0),
                      decor: [.blocks([rect(-0.8, 0.36, -0.3, 1.5), rect(0.3, 0.36, 0.8, 1.5)], RGBA(hex: 0xffffff), followsFace: false)]),
        // A plain white ball with a fringe: three locks over the forehead, kept to the ball's outline.
        "Hermes": BotSpec(radius: 0.35, reach: 0.5, paint: .solid(RGBA(hex: 0xf8f8f9)), face: CGPoint(x: 0, y: 0.24),
                          eye: Eye(height: 0.72, width: 0.3, spread: 0.44),
                          decor: [.soft([rect(-1.1, -1.25, -0.2, -0.22), rect(-0.44, -1.3, 0.44, -0.3), rect(0.2, -1.25, 1.1, -0.22)],
                                        hair, round: 1)]),
        "ZCode": BotSpec(reach: 0.8, shape: .slant(width: 0.66, height: 0.64, skew: 0.2, round: 0.05)),
        "Qwen": BotSpec(radius: 0.37, shape: .outline(keep: 0.55, smooth: 7), spin: 7),
        // A plain red ball with two round black eyes and the logo's pair of small antennae. The logo's cyan
        // pupils are left out: on a face this small they stare.
        "OpenClaw": BotSpec(center: CGPoint(x: 0.5, y: 0.54), reach: 0.7,
                            paint: .linear(from: CGPoint(x: 0.2, y: 0.1), to: CGPoint(x: 0.85, y: 0.95),
                                           stops: [RGBA(hex: 0xee4747), RGBA(hex: 0xc22e2e)]),
                            face: CGPoint(x: 0, y: 0.06), eye: Eye(height: 0.46, width: 0.46, spread: 0.46),
                            eyeColor: RGBA(hex: 0x050810),
                            decor: [.feelers([[CGPoint(x: -0.24, y: -0.9), CGPoint(x: -0.34, y: -1.14), CGPoint(x: -0.54, y: -1.22)],
                                              [CGPoint(x: 0.24, y: -0.9), CGPoint(x: 0.34, y: -1.14), CGPoint(x: 0.54, y: -1.22)]],
                                             RGBA(hex: 0xea4a4a), width: 0.1)]),
        // The cat in each logo, sitting up straight and out of its tile: white head, the logo's coloured face.
        "CodeBuddy": cat(head: RGBA(hex: 0xffffff),
                         face: .linear(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.85, y: 1),
                                       stops: [RGBA(hex: 0x5570da), RGBA(hex: 0x4587c1), RGBA(hex: 0x369dab)])),
        "WorkBuddy": cat(head: RGBA(hex: 0xeafaf6),
                         face: .linear(from: CGPoint(x: 0.5, y: 0.55), to: CGPoint(x: 0.5, y: 1),
                                       stops: [RGBA(hex: 0x00cd8c), RGBA(hex: 0x7dd76d)])),
        // A white ball wearing the logo's green as a neck warmer: the lower part of the ball, pulled up higher
        // at the sides than under the eyes, with a paler cuff along its edge. Nothing stands out from the ball.
        "Qoder": BotSpec(reach: 0.55, paint: .solid(RGBA(hex: 0xf8f8f8)), face: CGPoint(x: 0, y: -0.24),
                         eye: Eye(height: 0.7, width: 0.3, spread: 0.42),
                         decor: [.soft([rect(-1.2, -0.3, 1.2, 1.2)], RGBA(hex: 0x28d858), round: 0),
                                 .soft([rect(-1.4, -1.7, 1.4, 0.45)], RGBA(hex: 0x5be584), round: 1),
                                 .soft([rect(-1.4, -1.7, 1.4, 0.34)], RGBA(hex: 0xf8f8f8), round: 1)]),
        // Already a bot: it keeps its helmet and goggles, and its two eyes come alive where they are drawn.
        "GitHub Copilot": BotSpec(ownEyes: [rect(0.355, 0.570, 0.434, 0.723), rect(0.562, 0.570, 0.645, 0.723)]),
        // Keep the fork's purple tile and white ghost; only its black eyes move and blink.
        "Kiro": BotSpec(eyeColor: RGBA(hex: 0x000000),
                        ownEyes: [rect(0.492, 0.352, 0.563, 0.461), rect(0.609, 0.352, 0.672, 0.461)],
                        ownEyeBackground: RGBA(hex: 0xffffff)),
    ]

    private static func cat(head: RGBA, face: Paint) -> BotSpec {
        BotSpec(center: CGPoint(x: 0.5, y: 0.55), reach: 0.5, shape: .cat, paint: .solid(head),
                face: CGPoint(x: 0, y: 0.2), eye: Eye(height: 0.84, width: 0.36), eyeColor: RGBA(hex: 0xffffff),
                patch: Patch(box: rect(-0.9, -0.52, 0.9, 1.3), round: 0.5, paint: face))
    }

    private static func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
