//
//  WatchDiagnostics.swift
//  Shared by the Mac app, the iPhone app ("watch") and the Watch app.
//  (Tick all three targets in this folder's Target Membership.)
//

import Foundation

/// One syntax error, sent from the Mac → iPhone → Watch.
nonisolated struct WatchDiagnostic: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case syntax        // found by the quick check on save
        case build         // found by Xcode's last build
        case needsBuild    // from the last build, but its file changed since: press ⌘B to re-check
    }

    var path: String
    var line: Int
    var column: Int
    var message: String
    var kind: Kind = .syntax

    var id: String { "\(path):\(line):\(column)" }
    var fileName: String { (path as NSString).lastPathComponent }
    /// What VoiceOver should say for this error.
    var spokenSummary: String { "Line \(line), \(fileName). \(message)" }
}

/// Everything the Mac currently knows.
nonisolated struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    var generation: Int
    var projectName: String
    var diagnostics: [WatchDiagnostic]
    /// Goes up by one every time Xcode finishes a build (⌘B / ⌘R).
    var build: Int = 0
    var buildFailed: Bool = false
    /// Goes up by one every time a saved file was re-checked (⌘S, or the save before ⌘B / ⌘R),
    /// even if the errors didn't change, so the watch can say "still there".
    var check: Int = 0

    static let empty = DiagnosticSnapshot(generation: 0, projectName: "", diagnostics: [])
}

/// Keys used in HTTP (Mac ⇄ iPhone) and WatchConnectivity (iPhone ⇄ Watch).
nonisolated enum RelayKeys {
    static let command = "cmd"
    static let fetch = "fetch"
    static let open = "open"
    static let id = "id"
    static let snapshot = "snapshot"
    static let error = "error"
    static let ok = "ok"
    /// HTTP header carrying the pairing code shown in the Mac app.
    static let pairingHeader = "X-Pairing-Code"
    static let defaultPort: UInt16 = 8765
    /// Bonjour service the Mac advertises so the iPhone can find it automatically.
    static let bonjourType = "_errorrelay._tcp"
}

// MARK: - Bluetooth LE (Mac ⇄ Watch directly)

/// The Mac app is a Bluetooth LE peripheral; the watch app connects to it.
///   message  (notify)  Mac → Watch   JSON `BLEMessage`s, sent in chunks
///   command  (write)   Watch → Mac   text: hello / auth / pair / sec
/// Only paired watches get data, and all errors/commands are encrypted.
nonisolated enum BLEKeys {
    static let serviceUUID = "A228CAE2-D5AF-4AC0-B961-011076BD5905"
    static let messageUUID = "4792EEDA-217B-4AEB-893C-5BC5C4211FEA"
    static let commandUUID = "3F50B35E-922A-4613-AFF1-B1CECD04F681"
    static let localName = "Error Relay"

    /// First byte of every notification chunk.
    static let chunkStart: UInt8 = 0x01
    static let chunkEnd: UInt8 = 0x02

    /// Splits `data` into notification-sized chunks with start/end flags.
    static func chunks(_ data: Data, size: Int) -> [Data] {
        var result: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= chunkStart }
            if end == data.count { flags |= chunkEnd }
            result.append(Data([flags]) + data.subdata(in: offset..<end))
            offset = end
        } while offset < data.count
        return result
    }
}

/// Mac → Watch message.
///   challenge(n)  prove you know our shared key
///   unpaired      I don't know you (or your proof was wrong): pair first
///   pairing(k)    my public key; compare the 4-digit code
///   paired / denied / authed
///   snap(d)       encrypted CompactSnapshot
///   res(d)        encrypted BLEResult
nonisolated struct BLEMessage: Codable, Sendable {
    var t: String
    var n: String? = nil
    var k: String? = nil
    var d: String? = nil
}

/// Small version of DiagnosticSnapshot for Bluetooth (no full paths, max 30 errors).
nonisolated struct CompactSnapshot: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable {
        var f: String   // file name
        var l: Int      // line
        var m: String   // message
        var k: String   // kind
    }
    var g: Int          // generation
    var p: String       // project name
    var e: [Entry]
    var b: Int          // build number
    var bf: Bool        // last build failed
    var c: Int          // check (save) number

    init(_ snapshot: DiagnosticSnapshot) {
        g = snapshot.generation
        p = snapshot.projectName
        b = snapshot.build
        bf = snapshot.buildFailed
        c = snapshot.check
        e = snapshot.diagnostics.prefix(30).map {
            Entry(f: $0.fileName, l: $0.line, m: String($0.message.prefix(140)), k: $0.kind.rawValue)
        }
    }

    var snapshot: DiagnosticSnapshot {
        DiagnosticSnapshot(generation: g, projectName: p, diagnostics: e.map {
            WatchDiagnostic(path: $0.f, line: $0.l, column: 0, message: $0.m,
                            kind: WatchDiagnostic.Kind(rawValue: $0.k) ?? .syntax)
        }, build: b, buildFailed: bf, check: c)
    }
}

nonisolated struct BLEResult: Codable, Sendable {
    var ok: Bool
    var message: String
}
