//
//  RelayModel.swift
//  extension_poc
//
//  Watches a project folder for syntax errors and serves them to the iPhone.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI
import SystemConfiguration

final class RelayModel: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var snapshot = DiagnosticSnapshot.empty
    @Published private(set) var serverStatus = "Stopped"
    @Published private(set) var lastEvent = "Nothing yet"
    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothStatus = "Starting Bluetooth…"
    @Published private(set) var trustedWatches = TrustedWatches.all
    /// A watch asking to pair (shown as an alert).
    @Published var pairingRequest: PairingRequest?

    let pairingCode: String
    let port = RelayKeys.defaultPort

    private var stamps: [String: Date] = [:]
    private var errorsByFile: [String: [WatchDiagnostic]] = [:]

    // MARK: Hold back errors on the lines being edited
    /// Last saved content of each file, to see which lines changed.
    private var contents: [String: [String]] = [:]
    /// Where the person is typing right now. Errors here aren't sent to the watch yet.
    private var activeEdit: (path: String, lines: ClosedRange<Int>, at: Date)?
    /// Lines around the edit that also count as "being edited".
    private let editMargin = 3
    /// Safety net: after this long without any edit, held errors are released.
    private let holdLimit: TimeInterval = 45
    @Published private(set) var heldDescription: String?
    /// Errors already sent to the watch (file + message). These are never held
    /// back again, otherwise fixing a line would hide its own error and fake a success.
    private var shownKeys = Set<String>()
    /// Goes up on every save, so the watch can confirm "still there".
    private var checkNumber = 0
    /// A save we haven't answered yet. If a build starts right after it (⌘B / ⌘R),
    /// the build result answers instead, so the watch gets ONE answer, not two.
    private var pendingSave: Date?
    private var awaitingBuildSince: Date?
    /// File dates when the last build was read; a later save makes that file's
    /// build errors "needs build" instead of pretending they're still current.
    private var buildStamps: [String: Date] = [:]
    /// Off by default: since Xcode only saves on ⌘S / ⌘B / ⌘R, a save is an
    /// intentional check and should get a full answer.
    private var holdEditedLines: Bool { UserDefaults.standard.bool(forKey: "holdEditedLines") }
    /// The file you're most likely looking at in Xcode: the last one saved or jumped to.
    private var currentFile: String?

    // MARK: Errors from Xcode builds (⌘B / ⌘R)
    /// All errors from the last build: type errors, missing names, etc.
    private var buildErrors: [WatchDiagnostic] = []
    private var buildNumber = 0
    private var lastBuildFailed = false
    private var processedLogDate: Date?
    /// A log is read only once its date stops changing (Xcode may still be writing it).
    private var pendingLog: (url: URL, date: Date)?
    @Published private(set) var buildDescription = "No build yet"
    private var server: RelayServer?
    private let bluetooth = BLERelay()
    private var scanTask: Task<Void, Never>?
    private let developerDir = XcodeNavigator.developerDirectory()

    private enum Key {
        static let code = "relayPairingCode"
        static let folder = "relayFolder"
    }

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Key.code) {
            pairingCode = saved
        } else {
            let code = String(format: "%04d", Int.random(in: 0...9999))
            defaults.set(code, forKey: Key.code)
            pairingCode = code
        }
        if let path = defaults.string(forKey: Key.folder) {
            folder = URL(fileURLWithPath: path)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        let server = RelayServer(
            handler: { [weak self] request in
                self?.handle(request) ?? .error(503, "Unavailable")
            },
            onStatus: { [weak self] status in
                self?.serverStatus = status
            })
        server.start(port: port, advertisedHost: Self.localHostName)
        self.server = server

        // Direct Bluetooth link to the watch (no iPhone needed).
        bluetooth.onStatus = { [weak self] status in self?.bluetoothStatus = status }
        bluetooth.currentSnapshot = { [weak self] in self?.snapshot ?? .empty }
        bluetooth.onOpen = { [weak self] generation, index in
            self?.openFromWatch(generation: generation, index: index) ?? (ok: false, message: "Mac app not ready")
        }
        bluetooth.onPairingRequest = { [weak self] request in
            self?.pairingRequest = request
            NSApp.activate()          // bring the alert to the front (VoiceOver reads it)
        }
        bluetooth.onPairingCancelled = { [weak self] watchID in
            if self?.pairingRequest?.watchID == watchID { self?.pairingRequest = nil }
        }
        bluetooth.onTrustedChanged = { [weak self] in self?.trustedWatches = TrustedWatches.all }
        bluetooth.onSpeak = { [weak self] generation, index in
            self?.speakFromWatch(generation: generation, index: index)
        }
        bluetooth.start()

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                await self?.checkBuildLog()
                await self?.resolvePendingSave()
                self?.publish()        // also releases held errors once their time is up
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project folder to watch for syntax errors"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Key.folder)
        stamps = [:]
        errorsByFile = [:]
        contents = [:]
        activeEdit = nil
        buildErrors = []
        buildStamps = [:]
        pendingSave = nil
        awaitingBuildSince = nil
        shownKeys = []
        processedLogDate = nil
        pendingLog = nil
        buildDescription = "No build yet"
        publish()
    }

    // MARK: - Scanning

    /// Re-checks only the files whose modification date changed.
    func scan() async {
        guard let folder, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let devDir = self.developerDir
        let current = await Task.detached { SwiftSyntaxChecker.swiftFiles(in: folder) }.value
        let changed = current.filter { stamps[$0.key] != $0.value }.map(\.key)
        let removed = Set(stamps.keys).subtracting(current.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return }

        let (results, newContents) = await Task.detached {
            (SwiftSyntaxChecker.check(files: changed, developerDir: devDir),
             Dictionary(uniqueKeysWithValues: changed.compactMap { path in
                 EditTracker.readLines(path).map { (path, $0) }
             }))
        }.value
        guard self.folder == folder else { return }   // folder changed meanwhile

        // Remember where the person is typing (the lines that changed since the last save).
        for (path, lines) in newContents {
            if let old = contents[path], let range = EditTracker.editedRange(old: old, new: lines) {
                activeEdit = (path, range, Date())
                currentFile = path
            }
            contents[path] = lines
        }
        for path in removed { errorsByFile[path] = nil; contents[path] = nil }
        if !stamps.isEmpty { pendingSave = Date() }   // a save happened (not the very first scan)
        for (path, errors) in results { errorsByFile[path] = errors.isEmpty ? nil : errors }
        stamps = current
        publish()
    }

    /// Picks up a finished Xcode build and loads all its errors.
    func checkBuildLog() async {
        guard let folder else { return }
        let latest = await Task.detached { BuildLogReader.latestBuildLog(for: folder) }.value
        guard let latest, latest.date != processedLogDate else { return }
        // Wait one round until the log stops changing.
        guard let pending = pendingLog, pending.url == latest.url, pending.date == latest.date else {
            pendingLog = latest
            return
        }
        pendingLog = nil
        guard let errors = await Task.detached(operation: { BuildLogReader.errors(in: latest.url) }).value else { return }
        guard self.folder == folder else { return }

        let firstLoad = processedLogDate == nil      // log from before the app started: load quietly
        processedLogDate = latest.date
        buildErrors = errors
        lastBuildFailed = !errors.isEmpty
        buildStamps = stamps
        if !firstLoad {
            buildNumber += 1
            activeEdit = nil                         // ⌘B / ⌘R means "show me everything now"
            pendingSave = nil                        // the build result answers the save before it
            awaitingBuildSince = nil
        }
        let time = latest.date.formatted(date: .omitted, time: .shortened)
        buildDescription = errors.isEmpty
            ? "Last build at \(time): succeeded"
            : "Last build at \(time): failed with \(errors.count) error\(errors.count == 1 ? "" : "s")"
    }

    /// Decides how to answer a save: wait for the build (⌘B / ⌘R) or answer now (⌘S).
    func resolvePendingSave() async {
        guard let saveAt = pendingSave, let folder else { return }
        let now = Date()
        if let since = awaitingBuildSince {
            // Safety net if a build never reports back.
            if now.timeIntervalSince(since) > 180 {
                awaitingBuildSince = nil
                pendingSave = nil
                checkNumber += 1
            }
            return
        }
        guard now.timeIntervalSince(saveAt) >= 2 else { return }   // give Xcode time to start a build
        let activity = await Task.detached { BuildLogReader.lastBuildActivity(for: folder) }.value
        if let activity, activity >= saveAt.addingTimeInterval(-1) {
            awaitingBuildSince = saveAt            // a build is running: its result will answer
        } else {
            pendingSave = nil                      // plain ⌘S: answer now
            checkNumber += 1
        }
    }

    /// True for errors on (or near) the lines being edited right now.
    private func isHeld(_ diagnostic: WatchDiagnostic, now: Date) -> Bool {
        // Only NEW errors are held. One the watch already knows about stays visible,
        // so saving after a failed fix says "still there" instead of a fake success.
        guard holdEditedLines, !shownKeys.contains(Self.key(diagnostic)) else { return false }
        guard let edit = activeEdit, diagnostic.path == edit.path,
              now.timeIntervalSince(edit.at) < holdLimit else { return false }
        return diagnostic.line >= edit.lines.lowerBound - editMargin
            && diagnostic.line <= edit.lines.upperBound + editMargin
    }

    /// Same problem even if its line moved.
    private static func key(_ diagnostic: WatchDiagnostic) -> String {
        "\(diagnostic.path)|\(diagnostic.message)"
    }

    private func publish() {
        // While a save is still being answered, send nothing (avoids double answers).
        guard pendingSave == nil else { return }
        let now = Date()
        let liveErrors = errorsByFile.values.flatMap { $0 }
        // Only live (syntax) errors outside the area being edited go to the watch.
        // Editing somewhere else, the hold limit, or ⌘B / ⌘R releases them.
        let shownLive = liveErrors.filter { !isHeld($0, now: now) }
        let heldCount = liveErrors.count - shownLive.count
        // Build errors are never held: you asked for them with ⌘B / ⌘R.
        var merged: [WatchDiagnostic] = []
        var seen = Set<String>()
        // Build errors in files saved after that build can't be trusted any more.
        let checkedBuildErrors = buildErrors.map { error -> WatchDiagnostic in
            var error = error
            if let built = buildStamps[error.path], let saved = stamps[error.path], saved != built {
                error.kind = .needsBuild
            }
            return error
        }
        for diagnostic in shownLive + checkedBuildErrors
        where seen.insert("\(diagnostic.path):\(diagnostic.line):\(diagnostic.message)").inserted {
            merged.append(diagnostic)
        }
        let all = merged.sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
        if heldCount > 0, let edit = activeEdit {
            let file = (edit.path as NSString).lastPathComponent
            let plural = heldCount == 1 ? "" : "s"
            heldDescription = "\(heldCount) error\(plural) held while you edit \(file), lines \(edit.lines.lowerBound)–\(edit.lines.upperBound)"
        } else if heldDescription != nil {
            heldDescription = nil
        }
        let name = folder?.lastPathComponent ?? ""
        shownKeys = Set(all.map(Self.key))
        guard all != snapshot.diagnostics || name != snapshot.projectName
                || buildNumber != snapshot.build || checkNumber != snapshot.check else { return }
        snapshot = DiagnosticSnapshot(generation: snapshot.generation + 1, projectName: name, diagnostics: all,
                                      build: buildNumber, buildFailed: lastBuildFailed, check: checkNumber)
        bluetooth.send(snapshot)
    }

    // MARK: - Requests from the iPhone

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard request.headers[RelayKeys.pairingHeader.lowercased()] == pairingCode else {
            return .error(401, "Wrong pairing code")
        }
        switch (request.method, request.path) {
        case ("GET", "/snapshot"):
            return .json(snapshot)
        case ("POST", "/open"):
            // Only errors we reported can be opened, never arbitrary paths.
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body),
                  let id = body[RelayKeys.id],
                  let target = snapshot.diagnostics.first(where: { $0.id == id }) else {
                return .error(404, "Unknown error id")
            }
            return open(target, source: "Watch")
        default:
            return .error(404, "Not found")
        }
    }

    // MARK: - Pairing

    func answerPairing(allow: Bool) {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        bluetooth.answerPairing(watchID: request.watchID, allow: allow)
    }

    func forget(_ watch: TrustedWatch) {
        bluetooth.forget(watchID: watch.id)
        trustedWatches = TrustedWatches.all
    }

    /// Watch double tap: read the highlighted error aloud on the Mac, right now.
    private func speakFromWatch(generation: Int, index: Int) {
        guard generation == snapshot.generation, snapshot.diagnostics.indices.contains(index) else { return }
        let diagnostic = snapshot.diagnostics[index]
        lastEvent = "Watch asked to read \(diagnostic.fileName), line \(diagnostic.line)"
        announceOnMac(diagnostic, after: 0, requested: true)
    }

    /// "open:<generation>:<index>" from the watch over Bluetooth.
    private func openFromWatch(generation: Int, index: Int) -> (ok: Bool, message: String) {
        guard generation == snapshot.generation, snapshot.diagnostics.indices.contains(index) else {
            return (ok: false, message: "Errors changed. Try again.")
        }
        let diagnostic = snapshot.diagnostics[index]
        let response = open(diagnostic, source: "Watch")
        return response.status == 200
            ? (ok: true, message: "Opened \(diagnostic.fileName), line \(diagnostic.line)")
            : (ok: false, message: "Could not open Xcode")
    }

    @discardableResult
    func open(_ diagnostic: WatchDiagnostic, source: String) -> HTTPResponse {
        // Jumping inside the file you're already in → stay silent (you know where you are;
        // double tap on the watch reads the error). Landing in ANOTHER file → say what's wrong.
        let sameFile = currentFile == diagnostic.path
        do {
            try XcodeNavigator.open(path: diagnostic.path, line: diagnostic.line, developerDir: developerDir)
            currentFile = diagnostic.path
            lastEvent = "\(source) opened \(diagnostic.fileName), line \(diagnostic.line)"
                + (sameFile ? " (same file, silent)" : "")
            if source.hasPrefix("Watch"), !sameFile { announceOnMac(diagnostic, after: 1.5, requested: false) }
            return .json([RelayKeys.ok: true])
        } catch {
            lastEvent = "Could not open Xcode: \(error.localizedDescription)"
            return .error(500, "Could not open Xcode")
        }
    }

    // MARK: - Reading the error on the Mac

    private let macSpeaker = AVSpeechSynthesizer()

    /// After Xcode jumps to the line, tell the user what the error is.
    /// VoiceOver on → VoiceOver announcement; off → speech (setting "speakOnMac").
    /// - after: seconds to wait (lets VoiceOver finish reading the line after a jump).
    /// - requested: true when the user asked (watch double tap), which ignores the auto-speak setting.
    private func announceOnMac(_ diagnostic: WatchDiagnostic, after delay: Double, requested: Bool) {
        guard requested || UserDefaults.standard.object(forKey: "speakOnMac") as? Bool ?? true else { return }
        let text = "Error, line \(diagnostic.line): \(diagnostic.message)"
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            if NSWorkspace.shared.isVoiceOverEnabled {
                // macOS ignores announcements from background apps (Xcode is in front),
                // so ask VoiceOver itself to speak, in the user's VoiceOver voice.
                if let problem = Self.speakWithVoiceOver(text) {
                    self.lastEvent = problem
                    self.speakWithSynthesizer(text)          // fallback so the error is never lost
                }
            } else {
                self.speakWithSynthesizer(text)
            }
        }
    }

    private func speakWithSynthesizer(_ text: String) {
        macSpeaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        macSpeaker.speak(utterance)
    }

    /// Uses VoiceOver's AppleScript support. Returns nil on success, or what to fix.
    /// Needs: VoiceOver Utility → General → "Allow VoiceOver to be controlled with AppleScript",
    /// and the one-time "control VoiceOver" permission prompt answered with OK.
    private static func speakWithVoiceOver(_ text: String) -> String? {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"VoiceOver\" to output \"\(escaped)\"")?
            .executeAndReturnError(&error)
        guard let error else { return nil }
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -1743 {
            return "Allow extension_poc to control VoiceOver: System Settings → Privacy & Security → Automation"
        }
        return "Turn on VoiceOver Utility → General → \u{201C}Allow VoiceOver to be controlled with AppleScript\u{201D}"
    }

    // MARK: - Addresses to type into the iPhone

    /// e.g. "Reynards-MacBook-Pro.local"
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    var addresses: [String] {
        var list: [String] = []
        if let name = Self.localHostName {
            list.append("http://\(name):\(port)")
        }
        list += Self.ipv4Addresses().map { "http://\($0):\(port)" }
        return list
    }

    nonisolated private static func ipv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        return result
    }
}
