//
//  EditTracker.swift
//  extension_poc
//
//  Finds which lines changed between two saves of a file, so errors on the
//  lines the person is still typing can be held back (they're usually just
//  unfinished code, not real mistakes).
//

import Foundation

nonisolated enum EditTracker {

    /// Lines of a file (nil if unreadable).
    static func readLines(_ path: String) -> [String]? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n")
    }

    /// The changed region in the NEW file, as 1-based line numbers.
    /// Nil when nothing changed.
    static func editedRange(old: [String], new: [String]) -> ClosedRange<Int>? {
        guard old != new else { return nil }
        // Equal lines at the top…
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        // …and at the bottom (not overlapping the top part).
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let start = prefix + 1                       // first changed line (1-based)
        let end = max(start, new.count - suffix)     // a pure deletion still marks one line
        return start...end
    }
}
