// LiveErrorProbe.swift — see how live error detection works, before building it into the app.
//
// Run in Terminal (the first time, macOS asks to give Terminal "Accessibility" access):
//
//   swift Tools/LiveErrorProbe.swift editor   → reads your UNSAVED code from Xcode every second
//                                               and syntax-checks it live (no ⌘S needed)
//   swift Tools/LiveErrorProbe.swift issues   → lists every error/warning text Xcode exposes
//                                               to VoiceOver (Xcode's own live issues)
//
// Stop with Ctrl+C.

import AppKit
import ApplicationServices

// MARK: - 1. Permission: same one VoiceOver-style tools need

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    print("""
    ⚠️  Give Terminal Accessibility access:
        System Settings → Privacy & Security → Accessibility → turn on Terminal.
        Then run this again.
    """)
    exit(1)
}

guard let xcode = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first else {
    print("Open Xcode first."); exit(1)
}

// MARK: - 2. Tiny helpers to read the accessibility tree

/// The root of Xcode's accessibility tree (what VoiceOver talks to).
let xcodeApp = AXUIElementCreateApplication(xcode.processIdentifier)

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return (value as? [AXUIElement]) ?? []
}

/// Cursor position in the editor (character offset).
func cursorOffset(_ element: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    AXValueGetValue(value as! AXValue, .cfRange, &range)
    return range.location
}

// MARK: - 3. Mode "editor": read unsaved code + syntax-check it live

func syntaxErrors(in code: String) -> [String] {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("LiveErrorProbe.swift")
    try? code.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-parse", file.path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output.split(separator: "\n")
        .filter { $0.contains(": error: ") }
        .map { line in
            // "/tmp/…/LiveErrorProbe.swift:12:5: error: expected '}'"  →  "line 12: expected '}'"
            let parts = line.split(separator: ":", maxSplits: 4).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count >= 5 ? "line \(parts[1]): \(parts[4])" : String(line)
        }
}

func runEditorMode() {
    print("Click into a Swift file in Xcode and type WITHOUT saving. Ctrl+C to stop.\n")
    var lastText = ""
    var lastErrors: [String] = []
    while true {
        defer { Thread.sleep(forTimeInterval: 1) }
        // The element that has keyboard focus inside Xcode (even if Terminal is in front).
        guard let focused = element(xcodeApp, kAXFocusedUIElementAttribute),
              string(focused, kAXRoleAttribute) == "AXTextArea",            // Xcode's code editor
              let text = string(focused, kAXValueAttribute) else {          // ← the UNSAVED text
            print("… (focus is not in Xcode's code editor)")
            continue
        }
        let offset = min(cursorOffset(focused) ?? 0, (text as NSString).length)
        let before = (text as NSString).substring(to: offset)
        let cursorLine = before.components(separatedBy: "\n").count

        guard text != lastText else { continue }    // only re-check when the code changed
        lastText = text
        let errors = syntaxErrors(in: text)
        let stamp = Date().formatted(date: .omitted, time: .standard)
        print("[\(stamp)] cursor on line \(cursorLine) · \(errors.count) syntax error(s)")
        if errors != lastErrors { errors.forEach { print("     ⛔️ \($0)") } }
        lastErrors = errors
    }
}

// MARK: - 4. Mode "issues": find Xcode's own error texts in the tree

func runIssuesMode() {
    print("Searching Xcode's accessibility tree for error / warning text…\n")
    var visited = 0
    var found = Set<String>()
    func walk(_ node: AXUIElement, depth: Int) {
        guard depth < 40, visited < 60_000 else { return }
        visited += 1
        let role = string(node, kAXRoleAttribute) ?? "?"
        for attribute in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            guard let text = string(node, attribute as String), text.count < 400 else { continue }
            let lower = text.lowercased()
            if (lower.contains("error") || lower.contains("warning")), found.insert(text).inserted {
                print("[\(role)] \(attribute): \(text)")
            }
        }
        for child in children(node) { walk(child, depth: depth + 1) }
    }
    if let window = element(xcodeApp, kAXFocusedWindowAttribute) { walk(window, depth: 0) }
    print("\nChecked \(visited) elements, found \(found.count) error/warning texts.")
    print("Tip: make an error in Xcode first (red mark visible), and open the Issue Navigator (⌘5).")
}

// MARK: - Run

switch CommandLine.arguments.dropFirst().first {
case "issues": runIssuesMode()
default: runEditorMode()
}
