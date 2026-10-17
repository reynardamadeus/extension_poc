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

    /// Brings Xcode to the front with `path` open and the cursor on `line`.
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
