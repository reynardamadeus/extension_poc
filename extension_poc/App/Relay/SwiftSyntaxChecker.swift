//
//  SwiftSyntaxChecker.swift
//  extension_poc
//
//  Finds syntax errors by running `swiftc -parse` (syntax only, no build,
//  takes a fraction of a second per file). Needs App Sandbox OFF.
//

import Foundation

nonisolated enum SwiftSyntaxChecker {

    /// All .swift files under `root` with their modification dates.
    static func swiftFiles(in root: URL) -> [String: Date] {
        let skipped: Set<String> = ["DerivedData", "build", ".build", "Pods", "Carthage", "node_modules"]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }

        var result: [String: Date] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            result[url.path] = values?.contentModificationDate ?? .distantPast
            if result.count >= 500 { break }   // safety limit for the PoC
        }
        return result
    }

    /// Checks several files in parallel. Returns errors per file path.
    static func check(files: [String], developerDir: String?) -> [String: [WatchDiagnostic]] {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var results: [String: [WatchDiagnostic]] = [:]
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let errors = check(file: files[index], developerDir: developerDir)
            box.lock.lock(); box.results[files[index]] = errors; box.lock.unlock()
        }
        return box.results
    }

    /// Syntax-checks UNSAVED code (from the editor). Errors are reported as `path`.
    static func check(text: String, reportAs path: String, developerDir: String?) -> [WatchDiagnostic] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorRelay-live-\(ProcessInfo.processInfo.processIdentifier).swift")
        guard (try? text.write(to: temp, atomically: true, encoding: .utf8)) != nil else { return [] }
        return check(file: temp.path, developerDir: developerDir).map { error in
            var error = error
            error.path = path
            return error
        }
    }

    /// Syntax-checks one file.
    static func check(file path: String, developerDir: String?) -> [WatchDiagnostic] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-parse", path]
        var environment = ProcessInfo.processInfo.environment
        // Use Xcode's toolchain even if xcode-select points at the Command Line Tools.
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        process.environment = environment
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Turns "path:12:5: error: message" lines into diagnostics (errors only).
    static func parse(_ output: String) -> [WatchDiagnostic] {
        let pattern = #"^(.+?\.swift):(\d+):(\d+): error: (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let text = output as NSString
        var seen = Set<String>()
        return regex.matches(in: output, range: NSRange(location: 0, length: text.length)).compactMap { match in
            guard let line = Int(text.substring(with: match.range(at: 2))),
                  let column = Int(text.substring(with: match.range(at: 3))) else { return nil }
            let diagnostic = WatchDiagnostic(path: text.substring(with: match.range(at: 1)),
                                             line: line, column: column,
                                             message: text.substring(with: match.range(at: 4)))
            return seen.insert(diagnostic.id).inserted ? diagnostic : nil
        }
    }
}
