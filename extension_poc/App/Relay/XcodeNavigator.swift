//
//  XcodeNavigator.swift
//  extension_poc
//
//  Opens a file in Xcode at a given line, using `xed --line`, inside the file's own project.
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
    ///
    /// `xed --line` on its own opens a file in a bare window (no navigator, no project) when
    /// the file's project isn't open in Xcode. So first the project (or workspace / package)
    /// that owns the file is opened and loaded, then the jump happens INSIDE that project.
    /// Returns once the jump was sent, so the error is read only after the cursor moved.
    @MainActor
    static func openInProject(path: String, line: Int, developerDir: String?) async throws {
        // xed can take a moment (it may launch Xcode): never on the main thread.
        if let project = owningProject(of: path), !isOpen(project) {
            let projectPath = project.path
            try await Task.detached { try runXed([projectPath], developerDir: developerDir) }.value   // opens or focuses it
            await waitUntilLoaded(project, timeout: 20)
        }
        try await Task.detached { try runXed(["--line", String(line), path], developerDir: developerDir) }.value
    }

    static func runXed(_ arguments: [String], developerDir: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        process.environment = environment
        try process.run()
        process.waitUntilExit()        // xed returns once Xcode has the request (no --wait)
    }

    // MARK: - Which project owns a file

    /// Walks up from the file's folder: a .xcworkspace first (CocoaPods / multi-project),
    /// then a .xcodeproj, then a Swift package (Package.swift → the folder).
    static func owningProject(of path: String) -> URL? {
        let manager = FileManager.default
        let home = SandboxSupport.realHome.standardizedFileURL.path
        var folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        for _ in 0..<10 {
            let items = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            // A file inside the .xcodeproj bundle never decides the project.
            if !folder.path.contains(".xcodeproj"), !folder.path.contains(".xcworkspace") {
                if let workspace = items.first(where: { $0.hasSuffix(".xcworkspace") }) {
                    return folder.appendingPathComponent(workspace)
                }
                if let project = preferredProject(items.filter { $0.hasSuffix(".xcodeproj") }, in: folder) {
                    return folder.appendingPathComponent(project)
                }
                if items.contains("Package.swift") { return folder }
            }
            let parent = folder.deletingLastPathComponent()
            if folder.path == home || parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }

    /// Several .xcodeproj in one folder: the one named like the folder, else the first.
    private static func preferredProject(_ projects: [String], in folder: URL) -> String? {
        projects.first { ($0 as NSString).deletingPathExtension == folder.lastPathComponent } ?? projects.first
    }

    // MARK: - Is it open in Xcode? (AppleScript: Xcode's own workspace list)

    /// Paths and "loaded" state of every project/workspace open in Xcode.
    /// nil when Xcode isn't running or can't be asked (Automation not allowed).
    @MainActor
    static func openWorkspaces() -> [(path: String, loaded: Bool)]? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty else {
            return []                                   // not running: nothing is open
        }
        let source = """
        tell application id "com.apple.dt.Xcode"
            set out to ""
            repeat with d in workspace documents
                set out to out & (path of d) & "|" & (loaded of d) & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return nil }
        return (result.stringValue ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1] == "true")
        }
    }

    /// Same project? Xcode may report the .xcodeproj, or the workspace inside it.
    private static func matches(_ openPath: String, _ project: URL) -> Bool {
        var open = URL(fileURLWithPath: openPath).standardizedFileURL.path
        if open.hasSuffix("/project.xcworkspace") { open = (open as NSString).deletingLastPathComponent }
        let wanted = project.standardizedFileURL.path
        return open == wanted || (project.pathExtension.isEmpty && open == wanted)   // package folder
    }

    @MainActor
    static func isOpen(_ project: URL) -> Bool {
        openWorkspaces()?.contains { matches($0.path, project) && $0.loaded } ?? false
    }

    /// Polls until Xcode lists the project as loaded. If Xcode can't be asked, waits a bit.
    @MainActor
    private static func waitUntilLoaded(_ project: URL, timeout: Double) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            guard let open = openWorkspaces() else {
                try? await Task.sleep(for: .seconds(4))   // no AppleScript: a fixed wait
                return
            }
            if open.contains(where: { matches($0.path, project) && $0.loaded }) {
                try? await Task.sleep(for: .seconds(0.5))  // let the window settle
                return
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }
}
