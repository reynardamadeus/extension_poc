//
//  LiveTypeChecker.swift
//  extension_poc
//
//  NON-SANDBOXED. Full live checking of your UNSAVED code: type errors, missing names, wrong
//  arguments… not just syntax. No build: it runs `swiftc -typecheck` (no code generation)
//  on the file's whole module, with the editor's unsaved text in place of the saved file.
//
//  The compiler settings (SDK, target, Swift version, macro plugins, package search paths,
//  default actor isolation…) are copied from the command Xcode used in your last build
//  (⌘B / ⌘R), read from the build log. So: build once, then everything is checked live.
//  If a module's settings can't be used, that file falls back to the syntax-only check.
//

import Foundation

nonisolated enum LiveTypeChecker {

    /// How Xcode compiled one module (target), taken from a build log.
    struct Setup: Sendable, Equatable {
        var module: String
        var swiftc: String
        var arguments: [String]          // only the options that affect type checking
        var files: [String]              // every .swift file of the module
    }

    enum Outcome: Sendable {
        case errors([WatchDiagnostic])   // the check ran (empty = no errors)
        case unavailable(String)         // settings didn't work: use the syntax check
    }

    // MARK: - Settings from the build logs

    /// One setup per module, newest log first. Logs of builds where nothing compiled have
    /// no compile command, so older logs are searched too.
    static func setups(for projectFolder: URL, in derivedData: URL) -> [Setup] {
        var logs: [(url: URL, date: Date)] = []
        for folder in BuildLogReader.derivedDataFolders(for: projectFolder, in: derivedData) {
            let dir = folder.appendingPathComponent("Logs/Build")
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "xcactivitylog" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                logs.append((file, date ?? .distantPast))
            }
        }
        var byModule: [String: Setup] = [:]
        for log in logs.sorted(by: { $0.date > $1.date }).prefix(15) {
            for setup in setups(inLog: log.url) where byModule[setup.module] == nil {
                byModule[setup.module] = setup
            }
        }
        return Array(byModule.values)
    }

    static func setups(inLog log: URL) -> [Setup] {
        guard let compressed = try? Data(contentsOf: log),
              let data = SandboxSupport.gunzip(compressed) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        // "builtin-SwiftDriver -- /…/swiftc -module-name App … @/…/App.SwiftFileList …"
        let pattern = #"(/[^\s"]+/swiftc) ([^\r\n]*-module-name [^\r\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [Setup] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tokens = shellSplit(ns.substring(with: match.range(at: 2)))
            if let setup = makeSetup(swiftc: ns.substring(with: match.range(at: 1)), tokens: tokens),
               !result.contains(where: { $0.module == setup.module }) {
                result.append(setup)
            }
        }
        return result
    }

    /// Options copied with their value.
    private static let valueFlags: Set<String> = [
        "-module-name", "-sdk", "-target", "-target-variant", "-swift-version", "-F", "-I", "-Fsystem",
        "-Isystem", "-D", "-enable-upcoming-feature", "-enable-experimental-feature", "-default-isolation",
        "-plugin-path", "-external-plugin-path", "-load-plugin-executable", "-load-plugin-library",
        "-module-cache-path", "-working-directory", "-vfsoverlay", "-Xcc", "-package-name",
    ]
    /// Options copied as they are.
    private static let plainFlags: Set<String> = [
        "-application-extension", "-enable-bare-slash-regex", "-enable-testing", "-parse-as-library",
        "-warnings-as-errors", "-suppress-warnings",
    ]
    /// Options written as one token, like -DDEBUG or -strict-concurrency=complete.
    private static let attachedPrefixes = ["-D", "-strict-concurrency=", "-default-isolation=", "-swift-version="]

    private static func makeSetup(swiftc: String, tokens: [String]) -> Setup? {
        var arguments: [String] = []
        var files: [String] = []
        var module = ""
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if valueFlags.contains(token), let next {
                // Explicitly built modules (newer Xcode) need prebuilt module files we don't
                // pass: let the compiler find modules itself instead.
                if token == "-Xcc", next.contains("implicit-module") || next.hasPrefix("-fmodule-file=") {
                    i += 2
                    continue
                }
                if token == "-module-name" { module = next }
                arguments += [token, next]
                i += 2
                continue
            }
            if token == "-Xfrontend", let next {
                // Keep default actor isolation (MainActor by default in new Xcode projects).
                if next.hasPrefix("-default-isolation=") {
                    arguments += ["-default-isolation", String(next.dropFirst("-default-isolation=".count))]
                } else if next == "-default-isolation", i + 3 < tokens.count, tokens[i + 2] == "-Xfrontend" {
                    arguments += ["-default-isolation", tokens[i + 3]]
                    i += 4
                    continue
                }
                i += 2
                continue
            }
            if plainFlags.contains(token) || attachedPrefixes.contains(where: { token.hasPrefix($0) && token != $0 }) {
                arguments.append(token)
            } else if token.hasPrefix("@") {
                files += readFileList(String(token.dropFirst()))
            } else if token.hasSuffix(".swift"), !token.hasPrefix("-") {
                files.append(token)
            }
            i += 1
        }
        guard !module.isEmpty, !files.isEmpty else { return nil }
        return Setup(module: module, swiftc: swiftc, arguments: arguments, files: files)
    }

    private static func readFileList(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { line in
            let raw = String(line)
            if FileManager.default.fileExists(atPath: raw) { return raw }
            return shellSplit(raw).joined(separator: " ")       // "watch\ Watch\ App/…" → real path
        }.filter { $0.hasSuffix(".swift") }
    }

    /// Splits a command line like a shell: backslash escapes and quotes.
    static func shellSplit(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false
        for char in line {
            if escaped { current.append(char); escaped = false; hasToken = true; continue }
            if char == "\\", quote != "'" { escaped = true; continue }
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; hasToken = true; continue }
            if char == " " || char == "\t" {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(char)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    // MARK: - Checking the whole project (saved files)

    /// Type-checks every file of the module as saved on disk: all errors in all files,
    /// without building. Used when a project is opened, and after each save.
    static func checkModule(setup: Setup, developerDir: String?) -> Outcome {
        let files = setup.files.filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return .unavailable("no files") }
        switch run(files: files, setup: setup, developerDir: developerDir) {
        case .unavailable(let reason): return .unavailable(reason)
        case .errors(let errors):
            let own = Set(files)
            return .errors(errors.filter { own.contains($0.path) })
        }
    }

    // MARK: - Checking unsaved text

    /// Type-checks the module with `text` in place of `path`. Reports this file's errors only.
    static func check(text: String, path: String, setup: Setup, developerDir: String?) -> Outcome {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorRelay-typecheck-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent((path as NSString).lastPathComponent).path
        guard (try? text.write(toFile: temp, atomically: true, encoding: .utf8)) != nil else {
            return .unavailable("couldn't write a temporary file")
        }
        let files = setup.files.map { $0 == path ? temp : $0 }
        guard files.contains(temp) else { return .unavailable("file isn't in module \(setup.module)") }
        switch run(files: files, setup: setup, developerDir: developerDir) {
        case .unavailable(let reason): return .unavailable(reason)
        case .errors(let all):
            return .errors(all.filter { $0.path == temp }.map { error in
                var error = error
                error.path = path
                return error
            })
        }
    }

    /// Runs `swiftc -typecheck` on `files` with the module's settings. All errors, any file.
    private static func run(files: [String], setup: Setup, developerDir: String?) -> Outcome {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: setup.swiftc) {
            process.executableURL = URL(fileURLWithPath: setup.swiftc)
            process.arguments = ["-typecheck"] + setup.arguments + files
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swiftc", "-typecheck"] + setup.arguments + files
        }
        var environment = ProcessInfo.processInfo.environment
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        process.environment = environment
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch { return .unavailable("couldn't start swiftc") }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        timeout.cancel()

        if process.terminationReason == .uncaughtSignal { return .unavailable("type check took too long") }
        let all = SwiftSyntaxChecker.parse(output)
        // Problems with the settings themselves, not with your code.
        let setupProblem = output.split(separator: "\n").first { line in
            line.contains("no such module") || line.hasPrefix("error:") || line.hasPrefix("<unknown>:0: error")
                || line.contains("unable to load standard library")
        }
        if let setupProblem { return .unavailable(String(setupProblem.prefix(120))) }
        if process.terminationStatus != 0, all.isEmpty {
            return .unavailable(String(output.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .errors(all)
    }
}
