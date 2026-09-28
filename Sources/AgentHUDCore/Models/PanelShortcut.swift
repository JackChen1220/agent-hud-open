import Foundation

/// Carbon key code / modifier mask; no platform permission or event recording is persisted.
public struct PanelShortcut: Hashable, Codable, Sendable {
    public var enabled = true
    public var keyCode: UInt32 = 4
    public var modifiers: UInt32 = 768 // cmdKey | shiftKey
    public var label = "⇧⌘H"
    public init() {}
}
