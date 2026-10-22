//
//  LiveEditorMonitor.swift
//  extension_poc
//
//  Reads Xcode's code editor through the Accessibility API, the same tree
//  VoiceOver reads: the UNSAVED text, the cursor line, and (when Xcode
//  exposes it) the file. Needs "Accessibility" permission for this app.
//

import AppKit
import ApplicationServices

nonisolated struct EditorReading: Sendable {
    let text: String
    let cursorLine: Int          // 1-based
    let documentPath: String?    // nil when Xcode doesn't say which file
}

nonisolated enum LiveEditorMonitor {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt (once).
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Reads the focused code editor in Xcode, or nil if focus isn't in one.
    static func read() -> EditorReading? {
        guard AXIsProcessTrusted() else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
        guard let xcode = running.first(where: \.isActive) ?? running.first else { return nil }

        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)               // never hang if Xcode is busy

        guard let focused = element(app, kAXFocusedUIElementAttribute),
              string(focused, kAXRoleAttribute) == "AXTextArea",  // Xcode's code editor
              let text = string(focused, kAXValueAttribute) else { return nil }

        let ns = text as NSString
        let offset = min(cursorOffset(focused) ?? 0, ns.length)
        let cursorLine = ns.substring(to: offset).components(separatedBy: "\n").count

        var path: String?
        if let window = element(app, kAXFocusedWindowAttribute),
           let document = string(window, kAXDocumentAttribute),
           let url = URL(string: document), url.pathExtension == "swift" {
            path = url.path
        }
        return EditorReading(text: text, cursorLine: cursorLine, documentPath: path)
    }

    // MARK: - Accessibility helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func cursorOffset(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range.location
    }
}
