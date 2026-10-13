import Carbon.HIToolbox
import Foundation
import Observation

/// Global hot keys via Carbon `RegisterEventHotKey` (works without Accessibility permission).
@MainActor @Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let keyH = UInt32(kVK_ANSI_H)
    static let commandOption = UInt32(cmdKey | optionKey)

    private var handlers: [UInt32: () -> Void] = [:]
    @ObservationIgnored private var references: [UInt32: EventHotKeyRef] = [:]
    var panelShortcutError: String?
    private var installed = false
    private static let signature: OSType = 0x4148_5544 // 'AHUD'

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            return false
        }
        references[id] = reference
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        handlers[id] = nil
    }

    fileprivate func dispatch(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.dispatch(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
