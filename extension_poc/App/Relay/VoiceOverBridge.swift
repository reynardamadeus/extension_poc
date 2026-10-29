//
//  VoiceOverBridge.swift
//  extension_poc
//
//  NON-SANDBOXED ONLY. Makes VoiceOver itself speak a sentence through AppleScript
//  (`tell application "VoiceOver" to output "…"`): the user's own VoiceOver voice and
//  speed, and NO focus change: Xcode stays in front, the cursor stays on the error line.
//
//  Nothing is downloaded or installed: AppleScript is part of macOS and runs inside this
//  app (NSAppleScript). Two one-time switches exist, both controlled by the user:
//   1. VoiceOver Utility → General → "Allow VoiceOver to be controlled with AppleScript".
//   2. The first time, macOS asks "extension_poc wants to control VoiceOver" → OK
//      (Privacy & Security → Automation).
//  If either is missing, `speak` returns false and the caller falls back to the
//  brief panel (ErrorReadoutPanel), so the user always hears something.
//

import AppKit

enum VoiceOverBridge {

    enum State: Equatable {
        case ready
        case scriptingOff          // VoiceOver Utility checkbox is off
        case automationDenied      // the user said "Don't Allow" to controlling VoiceOver
        case voiceOverOff
        case unknown(String)

        var description: String {
            switch self {
            case .ready: return "Ready: VoiceOver speaks errors without leaving Xcode"
            case .scriptingOff: return "Off in VoiceOver Utility: using the brief panel instead"
            case .automationDenied: return "Not allowed in Privacy & Security → Automation: using the brief panel"
            case .voiceOverOff: return "VoiceOver is off"
            case .unknown(let text): return "Didn't work (\(text)): using the brief panel"
            }
        }
    }

    /// Last result, shown in the Mac app.
    private(set) static var state: State = .unknown("not tried yet")

    /// What VoiceOver Utility's checkbox says (readable because we're not sandboxed).
    static var scriptingAllowedInVoiceOverUtility: Bool? {
        UserDefaults(suiteName: "com.apple.VoiceOver4/default")?.object(forKey: "SCREnableAppleScript") as? Bool
    }

    /// Asks VoiceOver to say `text` now. VoiceOver interrupts what it was saying.
    /// Returns false (and nothing is spoken) when VoiceOver can't be scripted.
    @discardableResult
    static func speak(_ text: String) -> Bool {
        guard NSWorkspace.shared.isVoiceOverEnabled else { state = .voiceOverOff; return false }
        if scriptingAllowedInVoiceOverUtility == false { state = .scriptingOff; return false }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"VoiceOver\" to output \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { state = .ready; return true }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        switch number {
        case -1743: state = .automationDenied                 // errAEEventNotPermitted
        case -1708, -10000, -1728: state = .scriptingOff       // VoiceOver refused the command
        default: state = .unknown(error[NSAppleScript.errorMessage] as? String ?? "error \(number)")
        }
        return false
    }

    /// Opens VoiceOver Utility so the user can tick the AppleScript checkbox.
    /// Its location changed between macOS versions, so ask Launch Services first.
    @discardableResult
    static func openVoiceOverUtility() -> Bool {
        let workspace = NSWorkspace.shared
        let candidates = [
            workspace.urlForApplication(withBundleIdentifier: "com.apple.VoiceOverUtility"),
            URL(fileURLWithPath: "/System/Applications/Utilities/VoiceOver Utility.app"),
            URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver Utility.app"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications/VoiceOver Utility.app"),
        ]
        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            workspace.openApplication(at: url, configuration: .init(), completionHandler: nil)
            return true
        }
        // Last resort: VoiceOver settings in System Settings (has a link to VoiceOver Utility).
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?VoiceOver") {
            workspace.open(url)
        }
        return false
    }

    /// Opens Privacy & Security → Automation (if the user said "Don't Allow" earlier).
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
