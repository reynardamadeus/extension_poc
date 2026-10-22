//
//  HotKeyCenter.swift
//  extension_poc
//
//  Global keyboard shortcuts that work INSIDE the App Sandbox and need no
//  Accessibility permission: macOS tells us only when OUR key combo is
//  pressed (it never shows us other keystrokes). Many App Store apps use this.
//

import Carbon.HIToolbox
import Foundation

nonisolated final class HotKeyCenter: @unchecked Sendable {
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let signature: OSType

    /// Each center needs its own 4-letter signature so several can live side by side.
    init(signature: OSType = 0x4552_4C59) {                 // "ERLY"
        self.signature = signature
    }

    /// - keyCode: e.g. kVK_ANSI_E · modifiers: e.g. controlKey | shiftKey | cmdKey
    func register(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                               GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            guard hotKeyID.signature == center.signature,
                  let action = center.handlers[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { action() }                   // hotkey events arrive on the main thread
            return noErr
        }, 1, &spec, context, &eventHandler)
    }
}
