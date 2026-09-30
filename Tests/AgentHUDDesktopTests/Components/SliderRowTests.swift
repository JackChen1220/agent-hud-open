import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDDesktop

final class SliderRowTests: XCTestCase {
    @MainActor
    func testSliderDebouncesInputAndSavesPendingValueWhenRemoved() async throws {
        _ = NSApplication.shared
        var value = 20.0
        // The row formats the value it shows each time it is drawn, which tells when a change has reached it.
        var commits: [Double] = [], shown: [Double] = [], shownAtCommit = 0
        let hosting = NSHostingView(rootView: AnyView(SliderRow(label: "Brightness",
            value: Binding(get: { value }, set: { value = $0; commits.append($0); shownAtCommit = shown.count }),
            range: 20...100, step: 5, format: { shown.append($0); return "\(Int($0))%" }, theme: .light)))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 600, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await waitUntil("the slider is laid out") {
            hosting.layoutSubtreeIfNeeded()
            return findSlider(in: hosting) != nil
        }
        let slider = try XCTUnwrap(findSlider(in: hosting))

        func position(for value: Double) -> Double {
            slider.minValue + (value - 20) / 80 * (slider.maxValue - slider.minValue)
        }

        // Input arrives well inside the debounce interval, so a slow machine cannot let it lapse between two moves.
        for next in [40.0, 60.0, 80.0] {
            slider.doubleValue = position(for: next)
            slider.sendAction(slider.action, to: slider.target)
            XCTAssertEqual(slider.doubleValue, position(for: next), accuracy: 0.001, "The slider must follow input immediately")
            XCTAssertEqual(value, 20, "Settings must stay unchanged while input continues")
            XCTAssertTrue(commits.isEmpty)
            try await Task.sleep(for: .milliseconds(20))
        }

        try await waitUntil("the debounced value is saved") { !commits.isEmpty }
        XCTAssertEqual(value, 80)
        XCTAssertEqual(commits, [80], "Only the latest value should reach settings")
        // The row takes the saved value in its next update, which also clears what it held back.
        try await waitUntil("the row takes the saved value") {
            hosting.layoutSubtreeIfNeeded()
            return shown.count > shownAtCommit
        }

        let settled = shown.count
        slider.doubleValue = position(for: 90)
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(value, 80)
        try await waitUntil("the row shows the adjustment") {
            hosting.layoutSubtreeIfNeeded()
            return shown.dropFirst(settled).contains(90)
        }
        hosting.rootView = AnyView(EmptyView())
        try await waitUntil("the pending value is saved") { commits.count == 2 }
        XCTAssertEqual(commits, [80, 90], "Leaving the pane must save the pending adjustment")
    }

    /// Polls `condition` on the main actor instead of betting on how long the machine takes.
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func findSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
    }
}
