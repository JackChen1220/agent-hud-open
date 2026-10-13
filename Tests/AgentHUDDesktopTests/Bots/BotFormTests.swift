import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class BotFormTests: XCTestCase {
    func testEveryBundledMarkHasABot() {
        for vendor in AgentArtwork.allVendors {
            XCTAssertNotNil(BotForm.form(for: vendor), "\(vendor) has artwork and no bot")
        }
    }

    func testClientsThatShareAMarkShareItsBot() throws {
        let codex = try XCTUnwrap(BotForm.form(for: "Codex")), chatGPT = try XCTUnwrap(BotForm.form(for: "ChatGPT"))
        XCTAssertTrue(codex === chatGPT)
        XCTAssertNil(BotForm.form(for: "An agent nobody has drawn"))
    }

    func testOutlinesAreOneReachPerDegreeAndStayInsideTheFrame() throws {
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            XCTAssertEqual(form.logoReach.count, BotForm.samples)
            XCTAssertEqual(form.bodyReach.count, BotForm.samples)
            guard form.spec.ownEyes == nil else { continue }
            let widest = try XCTUnwrap(form.bodyReach.max())
            XCTAssertGreaterThan(try XCTUnwrap(form.bodyReach.min()), 0.1, vendor)
            // A body has to fit the room the renderer leaves round the mark.
            XCTAssertLessThan(widest, 0.5 + BotRenderer.margin, vendor)
        }
    }

    func testClaudeHasTwelveEvenHeads() throws {
        let reach = try XCTUnwrap(BotForm.form(for: "Claude")).bodyReach
        let mean = reach.reduce(0, +) / CGFloat(reach.count)
        var peaks = 0
        for index in reach.indices {
            let before = reach[(index + reach.count - 1) % reach.count], after = reach[(index + 1) % reach.count]
            if reach[index] > mean, reach[index] >= before, reach[index] > after { peaks += 1 }
        }
        XCTAssertEqual(peaks, 12)
        // Even: every head repeats thirty degrees on.
        for index in 0..<30 { XCTAssertEqual(reach[index], reach[index + 30], accuracy: 0.0001) }
    }

    func testEveryBotDrawsAtQueueSizeInEveryPhase() throws {
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            for phase in [BotPhase.working, .asking, .done] {
                var motion = BotMotion(seed: 3)
                motion.spin = form.spec.spin
                motion.set(phase, at: 0)
                var now: TimeInterval = 0
                while now < 1 { motion.step(to: now); now += 1.0 / 30 }
                let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 40), "\(vendor) \(phase)")
                XCTAssertEqual(image.width, 64)
                XCTAssertGreaterThan(Self.coverage(of: image), 0.05, "\(vendor) \(phase) drew almost nothing")
            }
        }
    }

    func testAnOutlinedFrameGrowsByTheHairlineOnEveryEdge() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude"))
        var motion = BotMotion(seed: 3)
        motion.set(.working, at: 0)
        motion.step(to: 0); motion.step(to: 1)
        let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 40))
        let outlined = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 40, outline: 1))
        XCTAssertEqual(outlined.width, image.width + 2)
        // The hairline adds a ring of pixels round the bot and takes none away.
        XCTAssertGreaterThan(Self.coverage(of: outlined, above: 20), Self.coverage(of: image, above: 20))
    }

    func testCharacterMarksRestoreTheirOriginalEyesWhileShowingTheLogo() throws {
        for vendor in ["GitHub Copilot", "Kiro"] {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            let original = try XCTUnwrap(BotRenderer.image(form, motion: BotMotion(seed: 3), side: 60))
            var motion = BotMotion(seed: 3)
            motion.set(.working, at: 0)
            for frame in 0..<30 {
                motion.step(to: Double(frame) / 30, aim: CGPoint(x: 0.8, y: 0.5))
            }
            for frame in 30..<60 {
                motion.step(to: Double(frame) / 30, aim: CGPoint(x: 0.8, y: 0.5), hasFace: false)
            }
            XCTAssertEqual(motion.morph, 0)
            XCTAssertGreaterThan(abs(motion.face.look), 0.25, "The hidden bot is looking away from the original eyes")
            let logo = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 60))
            XCTAssertEqual(try XCTUnwrap(logo.dataProvider?.data) as Data,
                           try XCTUnwrap(original.dataProvider?.data) as Data)
        }
    }

    func testCharacterEyeTransitionsKeepTheirBodiesOpaque() throws {
        for vendor in ["GitHub Copilot", "Kiro"] {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            let original = try XCTUnwrap(BotRenderer.image(form, motion: BotMotion(seed: 3), side: 60))
            var motion = BotMotion(seed: 3)
            motion.set(.working, at: 0)
            for frame in 0...5 {
                motion.step(to: Double(frame) / 20, aim: CGPoint(x: 0.8, y: 0.5))
            }
            XCTAssertEqual(motion.morph, 0.5, accuracy: 0.0001)
            let transition = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 60))
            XCTAssertGreaterThan(Self.coverage(of: transition, above: 240),
                                 Self.coverage(of: original, above: 240) * 0.9,
                                 "Changing the eyes must not fade the whole logo against the wallpaper")
        }
    }

    func testALookOnlyChangesWhenTheBotVisiblyDoes() {
        var motion = BotMotion(seed: 5)
        motion.staysBot = true
        var now: TimeInterval = 0
        while now < 3 { motion.step(to: now); now += 1.0 / 30 }
        let settled = BotRenderer.look(of: motion)
        motion.step(to: now + 1.0 / 30)
        XCTAssertEqual(BotRenderer.look(of: motion), settled)
    }

    /// Share of pixels that are not transparent.
    private static func coverage(of image: CGImage, above floor: UInt8 = 40) -> Double {
        guard let context = BotForm.bitmap(image.width) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.width))
        guard let data = context.data else { return 0 }
        let bytes = data.assumingMemoryBound(to: UInt8.self), count = image.width * image.width
        var solid = 0
        for index in 0..<count where bytes[index * 4 + 3] > floor { solid += 1 }
        return Double(solid) / Double(count)
    }
}
