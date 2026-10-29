//
//  FeedbackPlanner.swift
//  Shared by the Mac app and the Watch app.
//
//  ONE set of rules decides what to tell the user when the error list changes.
//  The watch turns the answer into haptics; the Mac (no watch) into one-ear sounds.
//

import Foundation

nonisolated enum Feedback: Equatable, Sendable {
    case none
    case firstErrors(String)     // app just connected and there are errors
    case buildFailed(String)     // ⌘B / ⌘R failed
    case buildSucceeded          // ⌘B / ⌘R succeeded
    case allClear                // ⌘S: errors were there, now none
    case checkedClear            // ⌘S: still no errors
    case fixed                   // the highlighted error is gone
    case newError(String)        // ⌘S: a new error appeared
    case needsBuild              // ⌘S: the highlighted (type) error can only be confirmed by building
    case stillThere              // ⌘S: the highlighted error is still there
    /// Live (non-sandboxed): an error stayed in the unsaved code for the linger time
    /// (default 10 s, set in the Mac app). Error haptic; double tap jumps to it.
    case lingeringError(WatchDiagnostic)

    /// What to say (nil = sound/haptic only).
    var speech: String? {
        switch self {
        case .firstErrors(let text), .buildFailed(let text), .newError(let text): return text
        case .buildSucceeded: return "Build succeeded"
        case .allClear: return "No errors"
        case .needsBuild: return "Saved. Press Command B to check."
        case .lingeringError(let error): return "Error. \(error.spokenSummary)"
        default: return nil
        }
    }
}

nonisolated enum FeedbackPlanner {

    /// - highlighted: the error the user is working on (watch selection / last jumped-to on the Mac).
    static func plan(old: DiagnosticSnapshot, new: DiagnosticSnapshot,
                     highlighted: WatchDiagnostic?, firstLoad: Bool) -> Feedback {
        // Pausing is silent. Reopening the project is like starting fresh: errors → error haptic.
        if new.paused { return .none }
        if firstLoad || (old.paused && !new.paused) {
            guard let first = new.diagnostics.first else { return .none }
            return .firstErrors("\(count(new.diagnostics.count)). \(first.spokenSummary)")
        }

        let finishedBuild = new.build != old.build
        let saved = new.check != old.check
        let liveTap = new.liveTap != old.liveTap

        let current = highlighted.flatMap { h in new.diagnostics.first { $0.isSameProblem(as: h) } }
        let wasThere = highlighted.map { h in old.diagnostics.contains { $0.isSameProblem(as: h) } } ?? false
        let solved = wasThere && current == nil
        let added = new.diagnostics.filter { candidate in
            !old.diagnostics.contains { $0.isSameProblem(as: candidate) }
        }

        if finishedBuild {
            guard new.buildFailed else { return .buildSucceeded }
            let about = (current ?? new.diagnostics.first)?.spokenSummary ?? ""
            return .buildFailed("Build failed. \(count(new.diagnostics.count)). \(about)")
        }
        if saved {
            if new.diagnostics.isEmpty { return old.diagnostics.isEmpty ? .checkedClear : .allClear }
            if solved { return .fixed }
            if let first = added.first { return .newError("New error. \(first.spokenSummary)") }
            if current?.kind == .needsBuild { return .needsBuild }
            return .stillThere
        }
        // Live, the error near the cursor: re-checked as you type.
        if new.liveFixed != old.liveFixed { return .fixed }
        if new.liveStill != old.liveStill, !new.diagnostics.isEmpty { return .stillThere }
        if liveTap, let lingering = added.first ?? new.diagnostics.first { return .lingeringError(lingering) }
        if solved { return .fixed }          // fixed while typing (live)
        return .none
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 error" : "\(n) errors" }
}

extension WatchDiagnostic {
    /// Same error even if editing above it moved it to another line.
    nonisolated func isSameProblem(as other: WatchDiagnostic) -> Bool {
        fileName == other.fileName && message == other.message
    }
}
