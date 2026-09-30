import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class DisplayPerformanceTests: XCTestCase {
    @MainActor
    func testPreviewReusesBitmapUntilRenderingInputsChange() throws {
        let cache = GlowImageCache()
        var settings = Settings()
        func render() throws -> GlowImage {
            let glow = settings.glow.geometry(islandWidth: 240, islandHeight: 30, islandRadius: 13)
            return try XCTUnwrap(cache.render(glow: glow, islandSize: CGSize(width: 240, height: 30),
                islandRadius: 13, outwardOnly: settings.glowOutwardOnly, stops: GlowGradient.idleStops, scale: 2,
                pattern: settings.glow.pattern()))
        }
        let initial = try render()
        settings.glowBrightness = 0.5
        settings.breathSeconds = 5
        settings.breathAmplitude = 0.8
        let opacityOnly = try render()
        XCTAssertTrue(initial.image === opacityOnly.image)

        settings.glowRange += 1
        let wider = try render()
        XCTAssertFalse(initial.image === wider.image)
        XCTAssertGreaterThan(wider.size.width, initial.size.width)

        settings.glowBlur += 1
        let feathered = try render()
        XCTAssertFalse(wider.image === feathered.image)
        XCTAssertGreaterThan(feathered.padding, wider.padding)

        settings.glowOutwardOnly.toggle()
        let soft = try render()
        XCTAssertFalse(feathered.image === soft.image)
        XCTAssertTrue(soft.image === (try render()).image)

        settings.glowStyle = .dots
        let dots = try render()
        XCTAssertFalse(soft.image === dots.image)
        XCTAssertEqual(dots.padding, 0, "grid styles need no blur padding")
        settings.glowEffect = .ripple
        XCTAssertTrue(dots.image === (try render()).image, "the resting bitmap does not depend on the effect")
        settings.glowGridPitch = 6
        let finer = try render()
        XCTAssertFalse(dots.image === finer.image)
        settings.glowGridDensity = 1.3
        let denser = try render()
        XCTAssertFalse(finer.image === denser.image)
        XCTAssertEqual(denser.size, finer.size)
        settings.glowStyle = .ascii
        XCTAssertFalse(finer.image === (try render()).image)
        XCTAssertTrue((try render()).image === (try render()).image)
    }

    /// Alpha of one device pixel in a rendered glow bitmap; rows run top-down like the glow rect.
    private func alpha(in image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return bytes[y * image.bytesPerRow + x * 4 + 3]
    }

    private func coverage(of image: CGImage) throws -> Int {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return stride(from: 3, to: CFDataGetLength(data), by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    private func pixels(of image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func gridRenderer(style: GlowStyle, effect: GlowEffect, density: Double = 1,
                              levels: [StatusLevel] = [.ok, .critical]) -> GlowFrameRenderer {
        let settings = Settings().with { $0.glowStyle = style; $0.glowEffect = effect; $0.glowGridDensity = density }
        let glow = settings.glow.geometry(islandWidth: 240, islandHeight: 30, islandRadius: 13)
        return GlowFrameRenderer(.init(glow: glow, islandRadius: 13, stops: GlowGradient.stops(levels: levels),
                                       scale: 2, pattern: settings.glow.pattern(),
                                       islandSize: CGSize(width: 240, height: 30), outwardOnly: settings.glowOutwardOnly))
    }

    @MainActor
    func testGridStylesLeaveTheIslandClearAndHugItsRim() throws {
        let island = CGSize(width: 240, height: 30)
        for style in GlowStyle.allCases where style != .blur {
            let settings = Settings().with { $0.glowStyle = style }
            let glow = settings.glow.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 13)
            let rendered = try XCTUnwrap(GlowFrameRenderer.resting(.init(glow: glow, islandRadius: 13,
                                                                         stops: GlowGradient.stops(levels: [.ok, .critical]), scale: 2,
                                                                         pattern: settings.glow.pattern())))
            XCTAssertEqual(rendered.size, CGSize(width: glow.width, height: glow.height))
            let centerX = Int(glow.width), centerY = Int(island.height)
            XCTAssertEqual(try alpha(in: rendered.image, x: centerX, y: centerY), 0, "\(style): nothing is drawn over the island")
            let bottom = Int((glow.height - glow.sideInset) * 2)
            let firstRow = (bottom + 2..<bottom + 18).flatMap { y in (centerX - 10..<centerX + 10).map { x in (x, y) } }
            XCTAssertTrue(try firstRow.contains { try alpha(in: rendered.image, x: $0.0, y: $0.1) > 0 }, "\(style): the first row sits right under the island")
            let lastPixelRow = Int(glow.height * 2) - 1
            XCTAssertEqual(try alpha(in: rendered.image, x: centerX, y: lastPixelRow), 0, "\(style): the glow has faded out by the bottom edge")
        }
    }

    func testEffectsAnimateButRestAtBlendZero() throws {
        for style in GlowStyle.allCases {
            for effect in GlowEffect.allCases {
                let renderer = gridRenderer(style: style, effect: effect)
                let resting = try pixels(of: try XCTUnwrap(renderer.render(time: 0, blend: 0, breathSeconds: 3, breathAmplitude: 0.6)?.image))
                XCTAssertEqual(try pixels(of: try XCTUnwrap(renderer.render(time: 1.7, blend: 0, breathSeconds: 3, breathAmplitude: 0.6)?.image)), resting,
                               "\(style)/\(effect): blend 0 is the resting frame at any time")
                let moments = try [0.3, 1.1, 1.9].map { time in
                    try pixels(of: try XCTUnwrap(renderer.render(time: time, blend: 1, breathSeconds: 3, breathAmplitude: 0.6)?.image))
                }
                XCTAssertTrue(moments.contains { $0 != resting }, "\(style)/\(effect): the effect changes the frame")
                XCTAssertNotEqual(moments[0], moments[1], "\(style)/\(effect): the effect moves over time")
            }
        }
    }

    func testFlowMovesEvenWhenEveryAgentSharesOneColour() throws {
        for style in GlowStyle.allCases {
            let renderer = gridRenderer(style: style, effect: .flow, levels: [.ok])
            let frames = try [0.5, 2.0, 3.5].map { time in
                try pixels(of: try XCTUnwrap(renderer.render(time: time, blend: 1, breathSeconds: 3, breathAmplitude: 0.6)?.image))
            }
            XCTAssertNotEqual(frames[0], frames[1], "\(style): the sheen travels along a single-colour glow")
            XCTAssertNotEqual(frames[1], frames[2], "\(style): and keeps moving")
        }
    }

    @MainActor
    func testSoftRestingFrameIsTheStaticGlow() throws {
        let settings = Settings()
        let island = CGSize(width: 240, height: 30)
        let glow = settings.glow.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 13)
        let stops = GlowGradient.stops(levels: [.ok, .critical])
        let still = try XCTUnwrap(GlowRenderer.render(glow: glow, islandSize: island, islandRadius: 13, outwardOnly: true, stops: stops, scale: 2))
        for effect in GlowEffect.allCases {
            let renderer = gridRenderer(style: .blur, effect: effect)
            let resting = try XCTUnwrap(renderer.render(time: 1.3, blend: 0, breathSeconds: 3, breathAmplitude: 0.6))
            XCTAssertEqual(resting.size, still.size, "\(effect): frames keep the nine-slice layout")
            XCTAssertEqual(resting.padding, still.padding)
            XCTAssertEqual(try pixels(of: resting.image), try pixels(of: still.image), "\(effect)")
        }
    }

    func testDensityFillsMoreOfEachCellOnTheSameGrid() throws {
        for style in GlowStyle.allCases where style != .blur {
            let normal = gridRenderer(style: style, effect: .breathe)
            let dense = gridRenderer(style: style, effect: .breathe, density: 2)
            let sparse = gridRenderer(style: style, effect: .breathe, density: 0.7)
            XCTAssertEqual(dense.cellCount, normal.cellCount, "\(style): density keeps the grid")
            let coverage = try [sparse, normal, dense].map { renderer in
                try self.coverage(of: try XCTUnwrap(renderer.render(time: 0, blend: 0, breathSeconds: 3, breathAmplitude: 0.6)?.image))
            }
            XCTAssertLessThan(coverage[0], coverage[1], "\(style): lower density leaves wider gaps")
            XCTAssertLessThan(coverage[1], coverage[2], "\(style): higher density fills more of each cell")
        }
    }

    func testBreatheShrinksTheDotsAtItsTrough() throws {
        let renderer = gridRenderer(style: .dots, effect: .breathe)
        let peak = try coverage(of: try XCTUnwrap(renderer.render(time: 0, blend: 1, breathSeconds: 3, breathAmplitude: 0.6)?.image))
        let trough = try coverage(of: try XCTUnwrap(renderer.render(time: 1.5, blend: 1, breathSeconds: 3, breathAmplitude: 0.6)?.image))
        XCTAssertLessThan(Double(trough), Double(peak) * 0.8)
        XCTAssertGreaterThan(renderer.cellCount, 100)
    }

    func testMotionPlaysWhetherOrNotAnAgentRuns() {
        let running = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: true, glow: GlowSettings())
        let idle = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: false, glow: GlowSettings())
        let dots = GlowPattern(style: .dots)
        XCTAssertTrue(GlowWindowController.playsMotion(pattern: dots, appearance: running, reduceMotion: false))
        XCTAssertTrue(GlowWindowController.playsMotion(pattern: dots, appearance: idle, reduceMotion: false),
                      "an idle HUD keeps moving at the idle period; only a paused or hidden one stops")
        XCTAssertFalse(GlowWindowController.playsMotion(pattern: dots, appearance: .idle(), reduceMotion: false),
                       "pausing detection does stop it")
        XCTAssertFalse(GlowWindowController.playsMotion(pattern: dots, appearance: running, reduceMotion: true))
        XCTAssertFalse(GlowWindowController.playsMotion(pattern: dots, appearance: .idle(hidden: true), reduceMotion: false))
        XCTAssertFalse(GlowWindowController.playsMotion(pattern: GlowPattern(style: .blur), appearance: running, reduceMotion: false),
                       "soft breathing stays a Core Animation opacity pulse")
        XCTAssertTrue(GlowWindowController.playsMotion(pattern: GlowPattern(style: .blur, effect: .ripple), appearance: running, reduceMotion: false))
    }

    @MainActor
    func testSliderChangesDoNotTriggerUnrelatedSettingsEffects() async throws {
        let domain = "app.agenthud.tests.display.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        var languageChanges = 0
        var appearanceChanges = 0
        var loginChanges = 0
        trackChanges({ [weak settings] in
            settings?.settings.language
        }, onChange: { languageChanges += 1 })
        trackChanges({ [weak settings] in
            settings?.settings.appearance
        }, onChange: { appearanceChanges += 1 })
        trackChanges({ [weak settings] in
            settings?.settings.launchAtLogin
        }, onChange: { loginChanges += 1 })

        for value in [0.2, 0.4, 0.6] {
            settings.update { $0.glowBrightness = value }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(languageChanges, 0, "Dragging a glow slider must not run the language refresh handler")
        XCTAssertEqual(appearanceChanges, 0)
        XCTAssertEqual(loginChanges, 0)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.glowBrightness, 0.6)

        settings.update { $0.language = .en; $0.appearance = .dark; $0.launchAtLogin.toggle() }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(languageChanges, 1)
        XCTAssertEqual(appearanceChanges, 1)
        XCTAssertEqual(loginChanges, 1)

        settings.update { $0.glowBlur = 12 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(languageChanges, 1)
        settings.update { $0.language = .zhHans }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(languageChanges, 2, "Observation must stay armed after unrelated changes")
    }
}
