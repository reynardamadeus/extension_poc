//
//  BuildLogReader.swift
//  extension_poc
//
//  Reads Xcode's own build log after ⌘B / ⌘R, so the watch gets EVERY error
//  (type errors, missing names, wrong arguments…), not just syntax errors.
//
//  Xcode writes a log for each build to
//    ~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Logs/Build/*.xcactivitylog
//  (gzip-compressed). The compiler's "file:line:col: error: message" lines
//  are inside it as plain text.
//

import Foundation

nonisolated enum BuildLogReader {

    /// DerivedData folders belonging to projects inside `projectFolder`.
    /// - derivedData: Xcode's DerivedData folder (granted by the user in the sandbox).
    static func derivedDataFolders(for projectFolder: URL, in derivedData: URL) -> [URL] {
        let root = derivedData
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let projectPath = projectFolder.standardizedFileURL.path
        return folders.filter { folder in
            guard let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist")),
                  let workspace = info["WorkspacePath"] as? String else { return false }
            return workspace.hasPrefix(projectPath)
        }
    }

    /// The newest build log for the project, with its modification date.
    static func latestBuildLog(for projectFolder: URL, in derivedData: URL) -> (url: URL, date: Date)? {
        var newest: (url: URL, date: Date)?
        for folder in derivedDataFolders(for: projectFolder, in: derivedData) {
            let logs = folder.appendingPathComponent("Logs/Build")
            let files = (try? FileManager.default.contentsOfDirectory(
                at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "xcactivitylog" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || date > newest!.date { newest = (file, date) }
            }
        }
        return newest
    }

    /// All Swift errors in a build log. Nil if the log couldn't be read.
    static func errors(in log: URL) -> [WatchDiagnostic]? {
        // Unzipped in-process: sandboxed apps can't run /usr/bin/gzip.
        guard let compressed = try? Data(contentsOf: log),
              let data = SandboxSupport.gunzip(compressed) else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        let pattern = #"(/[^\r\n"]+?\.swift):(\d+):(\d+): error: ([^\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var result: [WatchDiagnostic] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let line = Int(ns.substring(with: match.range(at: 2))),
                  let column = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let message = ns.substring(with: match.range(at: 4))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            let diagnostic = WatchDiagnostic(path: ns.substring(with: match.range(at: 1)),
                                             line: line, column: column, message: message, kind: .build)
            // The same error appears several times in a log (summary, per-architecture…).
            if seen.insert("\(diagnostic.path):\(line):\(message)").inserted { result.append(diagnostic) }
        }
        return result
    }

    /// When Xcode last touched its build database. This changes as soon as a
    /// build STARTS (the log only appears when it ends), so a save followed by
    /// this changing means "⌘B / ⌘R in progress".
    static func lastBuildActivity(for projectFolder: URL, in derivedData: URL) -> Date? {
        var newest: Date?
        for folder in derivedDataFolders(for: projectFolder, in: derivedData) {
            let buildData = folder.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
            let items = (try? FileManager.default.contentsOfDirectory(
                at: buildData, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in items {
                if let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   newest == nil || date > newest! {
                    newest = date
                }
            }
        }
        return newest
    }
}
