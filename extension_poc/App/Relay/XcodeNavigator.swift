//
//  XcodeNavigator.swift
//  extension_poc
//
//  Opens a file in Xcode at a given line, using `xed --line`.
//

import AppKit

nonisolated enum XcodeNavigator {

    /// The installed Xcode's Developer folder, so we don't depend on `xcode-select`.
    static func developerDirectory() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            return nil
        }
        return app.appendingPathComponent("Contents/Developer").path
    }

    /// App Store-safe: opens the file in Xcode (no exact line: the sandbox can't run `xed`).
    /// The target line is left for the extension's "Jump to Error Line" command.
    static func openSandboxed(path: String, line: Int) {
        SharedSettings.defaults.set(["file": (path as NSString).lastPathComponent,
                                     "line": line,
                                     "at": Date().timeIntervalSince1970], forKey: SharedSettings.Key.pendingJump)
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: xcode,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Brings Xcode to the front with `path` open and the cursor on `line` (needs the sandbox off).
    static func open(path: String, line: Int, developerDir: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
        process.arguments = ["--line", String(line), path]
        var environment = ProcessInfo.processInfo.environment
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        process.environment = environment
        try process.run()
    }
}
