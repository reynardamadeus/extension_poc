//
//  RelayModel.swift
//  extension_poc
//
//  Watches a project folder for syntax errors and serves them to the iPhone.
//

import AppKit
import AVFoundation
import Carbon.HIToolbox
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

    // MARK: Live checking (reads Xcode's editor through the Accessibility API while you type)
    private var liveText = ""
    private var liveTextChangedAt = Date.distantPast
    private var liveCheckedText = ""
    private var livePath: String?
    private var liveMatchedText = ""
    private var liveCursorLine = 0
    /// All syntax errors in the unsaved editor text.
    private var liveErrors: [WatchDiagnostic] = []
    /// After the quiet filters (not the cursor's line, not a block you're still writing).
    private var liveReportable: [WatchDiagnostic] = []
    private var liveReportedKeys = Set<String>()
    /// When each live error (file + message) was first seen. Gone → forgotten, so an
    /// error that comes back starts its linger timer again.
    private var liveFirstSeen: [String: Date] = [:]
    /// Live errors that already buzzed the watch (never buzz twice for the same one).
    private var liveAlerted = Set<String>()
    /// Shown in the Mac app: errors waiting out their linger time.
    @Published private(set) var lingerDescription: String?

    // Full live checking (types, names…) with the settings of the last build.
    private var compileSetups: [LiveTypeChecker.Setup] = []
    /// True when the open file's live result came from the full type check: then it
    /// replaces that file's build errors (they're older).
    private var liveSemantic = false
    /// Re-check the unsaved text even if it didn't change (another file was saved).
    private var liveRecheck = false
    @Published private(set) var typeCheckStatus = "Build once (⌘B) to turn on"
    private var liveTypeCheck: Bool { UserDefaults.standard.object(forKey: "liveTypeCheck") as? Bool ?? true }

    // Whole-project check (non-sandboxed): every file, types included, without building.
    // Runs when the project is opened (app start, folder chosen, project opened in Xcode)
    // and after each save. ⌘B / ⌘R results are still read and announced as before.
    private var projectErrors: [WatchDiagnostic] = []
    private var projectCheckWanted = true             // also on app start
    /// The check was asked for by opening a project: announce the result (haptic / sound).
    private var projectCheckAnnounce = true
    private var projectChecking = false
    /// Set once the build logs were looked at, so the first check uses their settings.
    private var buildLogsLooked = false
    private var projectWasOpenInXcode = false
    @Published private(set) var projectCheckDescription = "Not run yet"
    /// Live detection runs only while the watched project is open in Xcode.
    @Published private(set) var sessionPaused = false
    private var closedPolls = 0

    // The error near your cursor: re-checked as you type until it's fixed.
    private var focus: (error: WatchDiagnostic, since: Date)?
    private let focusMargin = 2
    private var liveFixedNumber = 0
    private var liveStillNumber = 0
    private var liveFirstCheck = true
    /// Right after ⌘S / a build: show everything until you type again.
    private var liveShowAll = false
    private var liveTapNumber = 0
    private var liveChecking = false
    private var liveTask: Task<Void, Never>?
    @Published private(set) var accessibilityGranted = LiveEditorMonitor.isTrusted
    @Published private(set) var liveStatus = "Off"
    /// "Build only" (default, App Store-safe): every answer comes from ⌘B / ⌘R.
    /// "Full": also checks on save and while typing (needs the sandbox off).
    enum CheckMode: String, CaseIterable, Identifiable {
        case buildOnly, full
        var id: String { rawValue }
        var label: String {
            switch self {
            case .buildOnly: return "Build only (⌘B / ⌘R)"
            case .full: return "Full (typing + save + build)"
            }
        }
    }
    var checkMode: CheckMode {
        if appStoreMode { return .buildOnly }            // the sandbox allows build checks only
        // Non-sandboxed build: full (live) checking unless the user picked build-only.
        return CheckMode(rawValue: UserDefaults.standard.string(forKey: "checkModeV2") ?? "") ?? .full
    }

    // MARK: Sandboxed (App Store-safe) vs non-sandboxed build
    /// Decided by the BUILD, not a switch in the app: ENABLE_APP_SANDBOX in project.yml.
    /// The team now ships the non-sandboxed version (live error detection, xed jumps,
    /// VoiceOver through AppleScript). A sandboxed build still works in App Store-safe mode.
    var appStoreMode: Bool { isSandboxed }
    var isSandboxed: Bool { SandboxSupport.isSandboxed }
    /// Xcode's DerivedData folder (build logs). In the sandbox the user must pick it once.
    private var derivedDataRoot: URL? = SandboxSupport.resolveBookmark(key: "derivedDataBookmark")
    /// What automatic build-results setup did last (shown under the folder, and spoken).
    @Published private(set) var buildSetupMessage: String?
    var derivedDataDescription: String {
        if let derivedDataRoot { return derivedDataRoot.path }
        if let local = projectDerivedData { return "\(local.path) (inside the project folder)" }
        return isSandboxed ? "Not allowed yet: build results can't be read"
                           : "\(SandboxSupport.defaultDerivedData.path) (default)"
    }
    /// The folder to read build logs from right now (nil = not allowed in the sandbox yet).
    private var buildLogRoot: URL? {
        derivedDataRoot ?? projectDerivedData ?? (isSandboxed ? nil : SandboxSupport.defaultDerivedData)
    }
    /// A "DerivedData" folder inside the chosen project folder, up to 3 levels down
    /// (next to the .xcodeproj, or inside it, depending on the Xcode version).
    /// Xcode puts it there when Derived Data is "Project-relative Location".
    /// Already covered by the project folder's permission, so no second prompt.
    private var projectDerivedData: URL? {
        guard let folder else { return nil }
        let manager = FileManager.default
        var level = [folder]
        for _ in 0..<3 {
            var next: [URL] = []
            for base in level {
                let items = (try? manager.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if item.lastPathComponent == "DerivedData" { return item }
                    if !["build", ".build", "Pods", "node_modules"].contains(item.lastPathComponent) { next.append(item) }
                }
            }
            level = next
        }
        return nil
    }
    private let hotKeys = HotKeyCenter()
    private var buildOnly: Bool { checkMode == .buildOnly }
    private var liveEnabled: Bool {
        !buildOnly && (UserDefaults.standard.object(forKey: "liveChecking") as? Bool ?? true)
    }
    /// Live error detection: an error must stay in the unsaved code this long before the
    /// watch gets an error haptic (Mac app → "Live error detection"). Default 10 s.
    private var lingerSeconds: Double {
        let value = UserDefaults.standard.double(forKey: "lingerSeconds")
        return value > 0 ? value : 10
    }
    private var lingerAlerts: Bool { UserDefaults.standard.object(forKey: "lingerAlerts") as? Bool ?? true }
    /// How much context is spoken with an error (Mac app → "Error detail").
    private var errorDetail: ErrorContext.Detail {
        ErrorContext.Detail(rawValue: UserDefaults.standard.string(forKey: "errorDetail") ?? "") ?? .full
    }

    // MARK: Feedback route: Apple Watch, or one-ear sounds on the Mac
    enum FeedbackMode: String, CaseIterable, Identifiable {
        case automatic, watch, mac
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic (watch when connected)"
            case .watch: return "Apple Watch only"
            case .mac: return "Mac sounds only (no watch)"
            }
        }
    }
    let audio = SpatialAudio()
    /// The error you're working on when there's no watch (last one jumped to / spoken).
    private var macHighlighted: WatchDiagnostic?
    /// App Store-safe jumps: the error to read once the extension's "Jump to Error Line"
    /// has really moved the cursor (so VoiceOver isn't told about a line you're not on).
    private var awaitingJump: WatchDiagnostic?
    private var jumpObserver: NSObjectProtocol?
    private var hotkeysTrusted = false
    @Published private(set) var feedbackRoute = "…"
    var feedbackMode: FeedbackMode {
        FeedbackMode(rawValue: UserDefaults.standard.string(forKey: "feedbackMode") ?? "") ?? .automatic
    }
    private var autoSpeakMacSounds: Bool { UserDefaults.standard.object(forKey: "autoSpeakMacSounds") as? Bool ?? true }
    /// True when feedback goes to the watch; false → Mac plays one-ear sounds.
    var usingWatch: Bool {
        switch feedbackMode {
        case .watch: return true
        case .mac: return false
        case .automatic: return bluetooth.verifiedWatchCount > 0
        }
    }
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
        if let saved = SandboxSupport.resolveBookmark(key: "folderBookmark") {
            folder = saved
        } else if !SandboxSupport.isSandboxed, let path = defaults.string(forKey: Key.folder) {
            folder = URL(fileURLWithPath: path)              // older builds stored a plain path
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil, scanTask == nil else { return }
        TrustedWatches.removeDuplicates()                 // leftovers from reinstalled watch apps
        trustedWatches = TrustedWatches.all
        if let root = derivedDataRoot, !isUsable(derivedData: root) {
            derivedDataRoot = nil                                   // a wrong folder picked earlier
            UserDefaults.standard.removeObject(forKey: "derivedDataBookmark")
        }
        // Old iPhone relay (Wi-Fi): off unless asked for; it would trigger the firewall prompt.
        if !appStoreMode, UserDefaults.standard.bool(forKey: "iPhoneRelay") { startIPhoneRelayServer() }
        startWatchAndChecks()
    }

    /// Old iPhone relay (Wi-Fi). Not used in App Store-safe mode.
    private func startIPhoneRelayServer() {
        let server = RelayServer(
            handler: { [weak self] request in
                self?.handle(request) ?? .error(503, "Unavailable")
            },
            onStatus: { [weak self] status in
                self?.serverStatus = status
            })
        server.start(port: port, advertisedHost: Self.localHostName)
        self.server = server
    }

    private func startWatchAndChecks() {
        // Direct Bluetooth link to the watch (no iPhone needed).
        bluetooth.onStatus = { [weak self] status in self?.bluetoothStatus = status }
        bluetooth.currentSnapshot = { [weak self] in self?.snapshot ?? .empty }
        bluetooth.onOpen = { [weak self] generation, index in
            self?.openFromWatch(generation: generation, index: index) ?? (ok: false, message: "Mac app not ready")
        }
        bluetooth.onPairingRequest = { [weak self] request in
            self?.pairingRequest = request
            NSApp.activate()          // bring the alert to the front (VoiceOver reads it)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)   // even if the window was behind Xcode
        }
        bluetooth.onPairingCancelled = { [weak self] watchID in
            if self?.pairingRequest?.watchID == watchID { self?.pairingRequest = nil }
        }
        bluetooth.onTrustedChanged = { [weak self] in self?.trustedWatches = TrustedWatches.all }
        bluetooth.onSpeak = { [weak self] generation, index in
            self?.speakFromWatch(generation: generation, index: index) ?? (ok: false, message: "Mac app not ready")
        }
        bluetooth.onStatusRequest = { [weak self] in
            self?.speakStatusFromWatch() ?? (ok: false, message: "Mac app not ready")
        }
        bluetooth.start()

        jumpObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedSettings.jumpedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.extensionJumped() }   // queue: .main
        }

        installHotkeys()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.liveTick()
                try? await Task.sleep(for: .seconds(0.5))
            }
        }

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                await self?.checkBuildLog()
                self?.noticeProjectOpenedInXcode()
                await self?.runProjectCheckIfWanted()
                await self?.resolvePendingSave()
                self?.publish()        // also releases held errors once their time is up
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// In the sandbox the app can't see DerivedData until the user picks it once.
    func chooseDerivedData() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SandboxSupport.defaultDerivedData
        panel.message = "This is Xcode's DerivedData folder. Don't open anything inside it: just press Allow."
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard isUsable(derivedData: url) else {
            // Easy mistake: clicking into one of the folders inside DerivedData.
            say("That folder is inside DerivedData. Choose DerivedData itself: just press Allow without opening anything.")
            chooseDerivedData()
            return
        }
        SandboxSupport.saveBookmark(for: url, key: "derivedDataBookmark")
        _ = url.startAccessingSecurityScopedResource()
        derivedDataRoot = url
        processedLogDate = nil
        pendingLog = nil
        objectWillChange.send()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project folder to watch for syntax errors"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        SandboxSupport.saveBookmark(for: url, key: "folderBookmark")
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
        projectErrors = []
        compileSetups = []
        buildLogsLooked = false
        projectCheckWanted = true                 // "first opening": check the whole project
        projectCheckAnnounce = true
        publish()
        setUpBuildResults(for: url)
    }

    /// DerivedData itself, or this project's own folder inside it. Any other folder inside
    /// (another project, Xcode's temporary "Files-…" folders for loose files) never holds
    /// this project's builds.
    private func isUsable(derivedData url: URL) -> Bool {
        let info = url.appendingPathComponent("info.plist")
        guard FileManager.default.fileExists(atPath: info.path) else { return true }   // DerivedData itself
        guard let folder, let plist = NSDictionary(contentsOf: info),
              let workspace = plist["WorkspacePath"] as? String else { return false }
        return workspace.hasPrefix(folder.standardizedFileURL.path)
    }

    /// After choosing a project: if the app can't read Xcode's build results yet, open the
    /// DerivedData picker right away (already pointed at the right folder: one press of Allow).
    /// It does NOT change any Xcode setting: moving build files into the project folder
    /// broke code signing for projects in iCloud-synced folders like Documents.
    private func setUpBuildResults(for folder: URL) {
        // Not sandboxed: the default DerivedData folder is readable, nothing to ask.
        guard isSandboxed, derivedDataRoot == nil, projectDerivedData == nil else { buildSetupMessage = nil; return }
        buildSetupMessage = "Press Allow in the next window so the app can read build results."
        say(buildSetupMessage ?? "")
        chooseDerivedData()
        if derivedDataRoot != nil { buildSetupMessage = nil }
    }

    // MARK: - Scanning

    /// Re-checks only the files whose modification date changed.
    func scan() async {
        guard let folder, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let devDir = self.developerDir
        let syntaxCheck = !buildOnly                 // build-only mode: no checks on save
        let current = await Task.detached { SwiftSyntaxChecker.swiftFiles(in: folder) }.value
        let changed = current.filter { stamps[$0.key] != $0.value }.map(\.key)
        let removed = Set(stamps.keys).subtracting(current.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return }

        let (results, newContents) = await Task.detached {
            (syntaxCheck ? SwiftSyntaxChecker.check(files: changed, developerDir: devDir) : [:],
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
        // File dates are still tracked in build-only mode: a file saved after the last
        // build marks its build errors "press ⌘B to re-check".
        if syntaxCheck {
            if !stamps.isEmpty {
                pendingSave = Date()                      // a save happened (not the very first scan)
                projectCheckWanted = true                 // re-check the whole project (types too)
            }
            for (path, errors) in results { errorsByFile[path] = errors.isEmpty ? nil : errors }
        } else {
            errorsByFile = [:]
        }
        stamps = current
        liveRecheck = true          // a saved file can fix (or break) the open file's errors
        publish()
    }

    /// Picks up a finished Xcode build and loads all its errors.
    func checkBuildLog() async {
        guard let folder else {
            buildDescription = "Choose your project folder first"
            return
        }
        guard let root = buildLogRoot else {
            buildDescription = "No build results yet. Reopen the project in Xcode once, then build with ⌘B."
            return
        }
        let latest = await Task.detached { BuildLogReader.latestBuildLog(for: folder, in: root) }.value
        if latest == nil { buildLogsLooked = true }
        if latest == nil, processedLogDate == nil {
            buildDescription = "Can read \(root.path), but no build of this project is there yet. Build with ⌘B."
        }
        guard let latest, latest.date != processedLogDate else { return }
        // Wait one round until the log stops changing.
        guard let pending = pendingLog, pending.url == latest.url, pending.date == latest.date else {
            pendingLog = latest
            return
        }
        pendingLog = nil
        guard let errors = await Task.detached(operation: { BuildLogReader.errors(in: latest.url) }).value else { return }
        guard self.folder == folder else { return }
        await loadCompileSetups(folder: folder, root: root)
        buildLogsLooked = true

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
            liveShowAll = true
            updateLiveReportable(countTap: false)
        }
        let time = latest.date.formatted(date: .omitted, time: .shortened)
        buildDescription = errors.isEmpty
            ? "Last build at \(time): succeeded"
            : "Last build at \(time): failed with \(errors.count) error\(errors.count == 1 ? "" : "s")"
    }

    /// Reads how Xcode compiled each module, for the full live check.
    private func loadCompileSetups(folder: URL, root: URL) async {
        guard !isSandboxed else { return }
        let found = await Task.detached { LiveTypeChecker.setups(for: folder, in: root) }.value
        guard self.folder == folder else { return }
        compileSetups = found
        typeCheckStatus = found.isEmpty
            ? "No compile settings in the build logs yet. Build once with ⌘B."
            : "Ready: " + found.map(\.module).sorted().joined(separator: ", ")
        liveRecheck = true
    }

    /// Notices the watched project being opened in Xcode (window title starts with its name)
    /// and checks the whole project right away, without a build.
    private func noticeProjectOpenedInXcode() {
        // Without Accessibility we can't see Xcode's windows: never pause on a guess.
        guard !isSandboxed, !buildOnly, let folder, LiveEditorMonitor.isTrusted else {
            if sessionPaused { resumeSession() }
            return
        }
        let names = projectNames(in: folder)
        let open = LiveEditorMonitor.xcodeWindowTitles().contains { title in
            names.contains { title == $0 || title.hasPrefix($0 + " ") }
        }
        if open {
            closedPolls = 0
            if !projectWasOpenInXcode {
                if sessionPaused { resumeSession() }
                projectCheckWanted = true
                projectCheckAnnounce = true
                lastEvent = "Project opened in Xcode: checking all files"
            }
        } else {
            closedPolls += 1                          // 2 checks in a row (3 s): not a window reload
            if closedPolls >= 2, !sessionPaused { pauseSession(folder: folder) }
        }
        projectWasOpenInXcode = open
    }

    /// The project was closed in Xcode: stop live detection. Nothing is checked or buzzed;
    /// the watch keeps its list (marked paused), and a double tap reopens the project.
    private func pauseSession(folder: URL) {
        sessionPaused = true
        resetLive()
        liveFirstSeen = [:]
        liveAlerted = []
        focus = nil
        lingerDescription = nil
        projectCheckWanted = false
        projectCheckAnnounce = false
        pendingSave = nil
        awaitingBuildSince = nil
        liveStatus = "Paused: \(folder.lastPathComponent) isn't open in Xcode"
        lastEvent = "Project closed in Xcode: live detection stopped"
        publish()
    }

    private func resumeSession() {
        sessionPaused = false
        closedPolls = 0
        lastEvent = "Live detection resumed"
    }

    /// Names of the .xcodeproj / .xcworkspace in the folder (2 levels), or the folder (package).
    private func projectNames(in folder: URL) -> Set<String> {
        var names: Set<String> = [folder.lastPathComponent]
        let manager = FileManager.default
        var level = [folder]
        for _ in 0..<2 {
            var next: [URL] = []
            for base in level {
                for item in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])) ?? [] {
                    if ["xcodeproj", "xcworkspace"].contains(item.pathExtension) {
                        names.insert(item.deletingPathExtension().lastPathComponent)
                    } else if item.hasDirectoryPath { next.append(item) }
                }
            }
            level = next
        }
        return names
    }

    /// Checks every file of the project as saved: with the last build's settings that's a full
    /// type check (all errors), otherwise the syntax check of every file (already done by scan).
    private func runProjectCheckIfWanted() async {
        if buildLogsLooked, stamps.isEmpty { projectCheckAnnounce = false }   // no Swift files: nothing to wait for
        guard projectCheckWanted, !projectChecking, !isSandboxed, !buildOnly, !sessionPaused,
              let folder, buildLogsLooked, !stamps.isEmpty else { return }
        projectCheckWanted = false
        projectChecking = true
        defer { projectChecking = false }
        let announce = projectCheckAnnounce
        defer { projectCheckAnnounce = false }        // publish waits until the result is in
        let root = folder.standardizedFileURL.path
        let setups = compileSetups.filter { setup in setup.files.contains { $0.hasPrefix(root) } }
        let devDir = developerDir
        projectCheckDescription = "Checking all files…"

        var errors: [WatchDiagnostic] = []
        var notes: [String] = []
        for setup in setups {
            switch await Task.detached(operation: { LiveTypeChecker.checkModule(setup: setup, developerDir: devDir) }).value {
            case .errors(let found): errors += found
            case .unavailable(let reason): notes.append("\(setup.module): \(reason)")
            }
        }
        guard self.folder == folder else { return }
        // Same error found in two targets (shared files): once.
        var seen = Set<String>()
        projectErrors = errors.filter { seen.insert($0.id + $0.message).inserted }
        let time = Date().formatted(date: .omitted, time: .shortened)
        let count = errorsByFile.values.reduce(0) { $0 + $1.count }
        if setups.isEmpty {
            projectCheckDescription = "\(time): syntax only (\(FeedbackPlanner.count(count))). Build once with ⌘B so types are checked too."
        } else {
            projectCheckDescription = "\(time): \(FeedbackPlanner.count(projectErrors.count)) in "
                + setups.map(\.module).sorted().joined(separator: ", ")
                + (notes.isEmpty ? "" : " · " + notes.joined(separator: "; "))
        }
        if announce, pendingSave == nil {
            checkNumber += 1                          // tell the watch: errors found / no errors
            liveShowAll = true                        // the open file: report everything now
            updateLiveReportable(countTap: false)
        }
    }

    /// Decides how to answer a save: wait for the build (⌘B / ⌘R) or answer now (⌘S).
    func resolvePendingSave() async {
        if buildOnly {                            // saves are never answered in build-only mode
            pendingSave = nil
            awaitingBuildSince = nil
            return
        }
        guard let saveAt = pendingSave, let folder else { return }
        // The project check after a save answers together with the save (one answer).
        guard !projectChecking, !projectCheckWanted else { return }
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
        let root = buildLogRoot
        let activity = await Task.detached { root.flatMap { BuildLogReader.lastBuildActivity(for: folder, in: $0) } }.value
        if let activity, activity >= saveAt.addingTimeInterval(-1) {
            awaitingBuildSince = saveAt            // a build is running: its result will answer
        } else {
            pendingSave = nil                      // plain ⌘S: answer now
            liveShowAll = true                     // you asked: include the line you're on
            updateLiveReportable(countTap: false)
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
        // Paused: send the same list once, marked paused, then nothing until the project reopens.
        if sessionPaused {
            guard !snapshot.paused else { return }
            var frozen = snapshot
            frozen.generation += 1
            frozen.paused = true
            snapshot = frozen
            if feedbackMode != .mac { bluetooth.send(frozen) }
            return
        }
        // While a save is still being answered, send nothing (avoids double answers).
        guard pendingSave == nil else { return }
        // A project was just opened: wait for its full check, so the watch gets ONE answer
        // with every error (error haptic) instead of the syntax errors first, then the rest.
        guard !(projectCheckAnnounce && !isSandboxed && !buildOnly && folder != nil) else { return }
        let now = Date()
        // For the file open in Xcode, live (unsaved) errors are newer than the saved ones.
        // (Kept while you type: the last live result is newer than the saved file, and switching
        // back to the saved file's errors mid-typing would fake a "fixed" haptic.)
        let liveActive = liveEnabled && livePath != nil && !liveCheckedText.isEmpty
        var liveErrors: [WatchDiagnostic] = []
        if !buildOnly {
            liveErrors = errorsByFile.filter { !(liveActive && $0.key == livePath) }.values.flatMap { $0 }
            liveErrors += projectErrors.filter { !(liveActive && $0.path == livePath) }
        }
        if liveActive { liveErrors += liveReportable }
        // Only live (syntax) errors outside the area being edited go to the watch.
        // Editing somewhere else, the hold limit, or ⌘B / ⌘R releases them.
        let shownLive = liveErrors.filter { !isHeld($0, now: now) }
        let heldCount = liveErrors.count - shownLive.count
        // Build errors are never held: you asked for them with ⌘B / ⌘R.
        var merged: [WatchDiagnostic] = []
        var seen = Set<String>()
        // Build errors in files saved after that build can't be trusted any more.
        // ⌘B / ⌘R errors are always kept. Two cases only:
        //  • the live check found the same problem → that one is shown (same error, newer line);
        //  • the full live check of your unsaved code no longer finds it → "press ⌘B to re-check".
        let checkedBuildErrors = buildErrors.compactMap { error -> WatchDiagnostic? in
            var error = error
            if liveActive, error.path == livePath, liveSemantic {
                if liveErrors.contains(where: { $0.isSameProblem(as: error) }) { return nil }
                error.kind = .needsBuild
            } else if liveErrors.contains(where: { $0.path == error.path && $0.isSameProblem(as: error) }) {
                return nil
            }
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
        updateRouteDescription()
        guard all != snapshot.diagnostics || name != snapshot.projectName || buildNumber != snapshot.build
                || checkNumber != snapshot.check || liveTapNumber != snapshot.liveTap
                || liveFixedNumber != snapshot.liveFixed || liveStillNumber != snapshot.liveStill
                || snapshot.paused else { return }                    // resuming: always send
        let previous = snapshot
        snapshot = DiagnosticSnapshot(generation: snapshot.generation + 1, projectName: name, diagnostics: all,
                                      build: buildNumber, buildFailed: lastBuildFailed, check: checkNumber,
                                      liveTap: liveTapNumber, liveFixed: liveFixedNumber, liveStill: liveStillNumber)
        if feedbackMode != .mac { bluetooth.send(snapshot) }       // keeps the watch in sync
        if !usingWatch { playMacFeedback(old: previous, new: snapshot) }
    }

    // MARK: - Live checking

    func liveTick() async {
        accessibilityGranted = LiveEditorMonitor.isTrusted
        guard liveEnabled else {
            if livePath != nil { resetLive() }
            liveStatus = buildOnly ? "Off (build-only mode)" : "Off"
            return
        }
        guard accessibilityGranted else { liveStatus = "Needs Accessibility permission"; return }
        guard !sessionPaused else { return }                       // project closed in Xcode
        guard let reading = LiveEditorMonitor.read() else { liveStatus = "Waiting for Xcode's code editor…"; return }

        let now = Date()
        liveCursorLine = reading.cursorLine
        if reading.text != liveText {                      // still typing: do nothing yet
            liveText = reading.text
            liveTextChangedAt = now
            liveShowAll = false
            liveStatus = "Typing…"
            return
        }
        // Which file is this? (Xcode often doesn't say, so match it with the saved files.)
        let path: String?
        if let document = reading.documentPath { path = document }
        else if liveText == liveMatchedText, let livePath { path = livePath }
        else { path = matchFile(for: liveText); liveMatchedText = liveText }
        guard let path else { liveStatus = "Can't tell which file is open (save it once)"; return }
        if path != livePath {
            livePath = path
            liveErrors = []
            liveCheckedText = ""
            liveReportedKeys = []
            liveSemantic = false
            liveFirstCheck = true
        }
        // About 2 seconds after typing stops: check the unsaved text. Full type check when the
        // last build's settings are known (types, names…), else syntax only.
        if liveText != liveCheckedText || liveRecheck, now.timeIntervalSince(liveTextChangedAt) >= 2, !liveChecking {
            liveChecking = true
            liveRecheck = false
            let text = liveText
            let devDir = developerDir
            let setup = liveTypeCheck ? compileSetups.first(where: { $0.files.contains(path) }) : nil
            let result = await Task.detached { () -> (errors: [WatchDiagnostic], semantic: Bool, note: String?) in
                var note: String?
                if let setup {
                    switch LiveTypeChecker.check(text: text, path: path, setup: setup, developerDir: devDir) {
                    case .errors(let errors): return (errors, true, nil)
                    case .unavailable(let reason): note = reason
                    }
                }
                return (SwiftSyntaxChecker.check(text: text, reportAs: path, developerDir: devDir), false, note)
            }.value
            liveChecking = false
            if let setup, let note = result.note {
                compileSetups.removeAll { $0 == setup }          // until the next build
                typeCheckStatus = "\(setup.module): syntax only (\(note))"
            }
            guard livePath == path, liveText == text else { return }     // changed meanwhile
            liveErrors = result.errors
            liveSemantic = result.semantic
            liveCheckedText = text
        }
        guard liveText == liveCheckedText else { return }                 // not checked yet
        updateLiveReportable(countTap: true)
        trackFocus(path: path, now: now)
        let file = (path as NSString).lastPathComponent
        let kind = liveSemantic ? "error" : "syntax error"
        liveStatus = "\(file), line \(liveCursorLine): \(liveErrors.count) \(kind)\(liveErrors.count == 1 ? "" : "s") (\(liveReportable.count) sent)"
            + (liveSemantic ? " · full check" : " · syntax only")
    }

    /// Keeps re-checking the error your cursor is on (or within 2 lines of). Every live check
    /// (2 s after you stop typing, or when another file is saved) asks: is it still there?
    ///  • Gone, and no other error at that spot → "fixed" (success haptic).
    ///  • Turned into another error at the same spot while you edit → follow that one, quietly.
    ///  • You move the cursor away and it's still there → "still there" haptic, once.
    private func trackFocus(path: String, now: Date) {
        if let current = focus {
            if current.error.path != path {
                // Switched files: a reminder if it's still in the list.
                if snapshot.diagnostics.contains(where: { $0.isSameProblem(as: current.error) }),
                   now.timeIntervalSince(current.since) >= 2 { liveStillNumber += 1 }
                focus = nil
            } else if let same = liveErrors.first(where: { $0.isSameProblem(as: current.error) }) {
                focus = (same, current.since)                         // follows the line if it moved
                if abs(liveCursorLine - same.line) > focusMargin {
                    if now.timeIntervalSince(current.since) >= 2 {
                        liveStillNumber += 1
                        lastEvent = "Still there: \(same.fileName), line \(same.line)"
                    }
                    focus = nil
                }
            } else if let other = liveErrors.first(where: { abs($0.line - current.error.line) <= focusMargin }) {
                focus = (other, current.since)                        // still being edited
            } else {
                liveFixedNumber += 1
                lastEvent = "Fixed: \(current.error.fileName), line \(current.error.line)"
                if macHighlighted?.isSameProblem(as: current.error) == true { macHighlighted = nil }
                focus = nil
            }
        }
        guard focus == nil else { return }
        // Only errors the live check can confirm (build-only errors need the full check).
        let candidates = snapshot.diagnostics.filter {
            $0.path == path && $0.kind == .syntax && abs($0.line - liveCursorLine) <= focusMargin
        }
        if let nearest = candidates.min(by: { abs($0.line - liveCursorLine) < abs($1.line - liveCursorLine) }) {
            focus = (nearest, now)
        }
    }

    /// Live error detection (non-sandboxed). An error reaches the watch only after it has
    /// stayed in the unsaved code for `lingerSeconds` (default 10): a typo you fix right away
    /// never buzzes. When it does, the watch plays an error haptic and highlights it, so a
    /// double tap jumps straight to it. Errors already reported stay visible (no fake "fixed").
    private func updateLiveReportable(countTap: Bool) {
        let now = Date()
        let keys = Set(liveErrors.map(Self.key))
        liveFirstSeen = liveFirstSeen.filter { keys.contains($0.key) }      // fixed → timer resets
        liveAlerted.formIntersection(keys)
        for key in keys where liveFirstSeen[key] == nil { liveFirstSeen[key] = now }

        var waiting = 0
        let reportable = liveShowAll ? liveErrors : liveErrors.filter { error in
            let key = Self.key(error)
            if shownKeys.contains(key) || liveAlerted.contains(key) { return true }
            guard now.timeIntervalSince(liveFirstSeen[key] ?? now) >= lingerSeconds else { waiting += 1; return false }
            return true
        }
        let reportableKeys = Set(reportable.map(Self.key))
        let fresh = reportableKeys.subtracting(liveAlerted).subtracting(shownKeys)
        if countTap, lingerAlerts, !liveFirstCheck, !fresh.isEmpty {
            liveTapNumber += 1                      // stayed for the linger time: error haptic
        }
        liveFirstCheck = false
        liveAlerted.formUnion(reportableKeys)
        liveReportedKeys = reportableKeys
        liveReportable = reportable
        let text: String? = waiting == 0 ? nil
            : "\(waiting) new error\(waiting == 1 ? "" : "s") waiting \(Int(lingerSeconds)) s before the watch is told"
        if lingerDescription != text { lingerDescription = text }
    }

    /// Finds the saved file most similar to the editor text.
    private func matchFile(for text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var best: (path: String, score: Int)?
        for (path, saved) in contents {
            let limit = min(lines.count, saved.count)
            var prefix = 0
            while prefix < limit, lines[prefix] == saved[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, lines[lines.count - 1 - suffix] == saved[saved.count - 1 - suffix] { suffix += 1 }
            if best == nil || prefix + suffix > best!.score { best = (path, prefix + suffix) }
        }
        guard let best, best.score * 2 >= max(lines.count, 1) else { return nil }
        return best.path
    }

    private func resetLive() {
        livePath = nil
        liveText = ""
        liveCheckedText = ""
        liveErrors = []
        liveReportable = []
        liveReportedKeys = []
    }

    // MARK: - Feedback without a watch (Mac sounds)

    private func updateRouteDescription() {
        let text: String
        switch feedbackMode {
        case .watch: text = "Apple Watch"
        case .mac: text = "Mac sounds"
        case .automatic:
            text = usingWatch ? "Apple Watch (connected)" : "Mac sounds (no watch connected)"
        }
        if feedbackRoute != text { feedbackRoute = text }
    }

    private func playMacFeedback(old: DiagnosticSnapshot, new: DiagnosticSnapshot) {
        let highlighted = macHighlighted ?? old.diagnostics.first
        let feedback = FeedbackPlanner.plan(old: old, new: new, highlighted: highlighted, firstLoad: old.generation == 0)
        if let highlighted, let same = new.diagnostics.first(where: { $0.isSameProblem(as: highlighted) }) {
            macHighlighted = same
        } else {
            macHighlighted = new.diagnostics.first
        }
        guard old.generation != 0 else { return }          // no sounds when the app starts
        audio.play(feedback)
        if autoSpeakMacSounds, let speech = feedback.speech {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.45))   // after the sound
                // Through VoiceOver when it's on, so it never talks over VoiceOver.
                // Not urgent: VoiceOver finishes what it's saying first.
                self?.say(speech, urgent: false)
            }
        }
    }

    /// Plays every sound once, then the voice.
    func testSounds() {
        let samples: [Feedback] = [.newError(""), .stillThere, .fixed, .needsBuild, .checkedClear]
        for (index, feedback) in samples.enumerated() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Double(index) * 0.9))
                self?.audio.play(feedback)
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(samples.count) * 0.9 + 0.3))
            self?.say("This is your error voice. Error, line 12: expected closing brace.")
        }
    }

    // MARK: - Keyboard shortcuts (for use without a watch)
    // ⌃⇧⌘E: read the error nearest the cursor · ⌃⇧⌘N: jump to the next error
    // (⌃⌥ is VoiceOver's own key, so we avoid it.)

    /// Registered hotkeys: allowed in the sandbox and need no Accessibility permission.
    private func installHotkeys() {
        guard !hotkeysTrusted else { return }
        hotkeysTrusted = true
        let modifiers = controlKey | shiftKey | cmdKey
        hotKeys.register(keyCode: kVK_ANSI_E, modifiers: modifiers) { [weak self] in self?.speakCurrentError() }
        hotKeys.register(keyCode: kVK_ANSI_N, modifiers: modifiers) { [weak self] in self?.openNextError() }
    }

    /// ⌃⇧⌘E: the error closest to your cursor in the open file (else the current one).
    func speakCurrentError() {
        let list = snapshot.diagnostics
        let inFile = list.filter { $0.path == livePath }
        let nearest = inFile.min { abs($0.line - liveCursorLine) < abs($1.line - liveCursorLine) }
        guard let target = nearest ?? macHighlighted ?? list.first else {
            speakNow("No errors")
            return
        }
        macHighlighted = target
        announceOnMac(target, after: 0, requested: true)
    }

    /// ⌃⇧⌘N: jump to the next error in Xcode.
    func openNextError() {
        let list = snapshot.diagnostics
        guard !list.isEmpty else {
            audio.play(.checkedClear)
            speakNow("No errors")
            return
        }
        let index = macHighlighted.flatMap { current in list.firstIndex { $0.isSameProblem(as: current) } }
        let next = list[index.map { ($0 + 1) % list.count } ?? 0]
        macHighlighted = next
        open(next, source: "Shortcut")
    }

    private func speakNow(_ text: String) {
        say(text)
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
    /// Never silent: if the watch's list is out of date, read the error at that position now
    /// (or the first one, or "No errors yet"). Returns what to tell the watch.
    private func speakFromWatch(generation: Int, index: Int) -> (ok: Bool, message: String) {
        let list = snapshot.diagnostics
        guard !list.isEmpty else { return speakStatusFromWatch() }
        let diagnostic = list.indices.contains(index) ? list[index] : list[0]
        lastEvent = "Watch asked to read \(diagnostic.fileName), line \(diagnostic.line)"
            + (generation == snapshot.generation ? "" : " (watch list was out of date)")
        announceOnMac(diagnostic, after: 0, requested: true)
        return (ok: true, message: "Reading line \(diagnostic.line) on your Mac")
    }

    /// Watch double tap while it shows no errors.
    @discardableResult
    private func speakStatusFromWatch() -> (ok: Bool, message: String) {
        if let first = snapshot.diagnostics.first {
            // The watch's list was out of date: read the error it hasn't got yet.
            lastEvent = "Watch asked: reading \(first.fileName), line \(first.line)"
            announceOnMac(first, after: 0, requested: true)
            return (ok: true, message: "Reading line \(first.line) on your Mac")
        }
        let text = processedLogDate != nil && !lastBuildFailed
            ? "No errors. The last build succeeded."
            : "No errors yet."
        lastEvent = "Watch asked: \(text)"
        say(text)
        return (ok: true, message: text)
    }

    /// "open:<generation>:<index>" from the watch over Bluetooth.
    private func openFromWatch(generation: Int, index: Int) -> (ok: Bool, message: String) {
        let list = snapshot.diagnostics
        guard !list.isEmpty else { return speakStatusFromWatch() }       // "No errors yet"
        // Never a dead double tap: if the watch's list is a step behind, take the error at
        // that position (or the first one). The Mac reads which one it is after the jump.
        let diagnostic = list.indices.contains(index) ? list[index] : list[0]
        if generation != snapshot.generation { lastEvent = "Watch list was out of date; opening \(diagnostic.fileName), line \(diagnostic.line)" }
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
            if appStoreMode {
                // The sandbox can't run `xed`: open the file, and the extension's
                // "Jump to Error Line" command moves the cursor to the line.
                XcodeNavigator.openSandboxed(path: diagnostic.path, line: diagnostic.line)
            } else {
                // Opens the file's project first if needed (else Xcode shows a bare file),
                // then jumps. The error is read only after the jump really happened.
                let announce = source.hasPrefix("Watch") || (source == "Shortcut" && !sameFile)
                let requested = source.hasPrefix("Watch")
                let devDir = developerDir
                Task { @MainActor [weak self] in
                    do {
                        try await XcodeNavigator.openInProject(path: diagnostic.path, line: diagnostic.line,
                                                               developerDir: devDir)
                        if announce { self?.announceOnMac(diagnostic, after: 1.5, requested: requested) }
                    } catch {
                        self?.lastEvent = "Could not open Xcode: \(error.localizedDescription)"
                    }
                }
            }
            currentFile = diagnostic.path
            lastEvent = "\(source) opened \(diagnostic.fileName), line \(diagnostic.line)"
                + (sameFile ? " (same file, silent)" : "")
            // Watch double tap = "take me there and tell me": the Mac reads the error
            // (the watch never speaks; that would overlap with VoiceOver here).
            if appStoreMode, source.hasPrefix("Watch") || source == "Shortcut" {
                // The cursor moves only when "Jump to Error Line" runs; read the error then.
                awaitingJump = diagnostic
            }   // not sandboxed: read after the jump (above)
            return .json([RelayKeys.ok: true])
        } catch {
            lastEvent = "Could not open Xcode: \(error.localizedDescription)"
            return .error(500, "Could not open Xcode")
        }
    }

    // MARK: - Reading the error on the Mac

    /// The extension moved the cursor to the pending error: read it now.
    /// Short pause so VoiceOver can start reading the line first instead of being cut off.
    private func extensionJumped() {
        guard let diagnostic = awaitingJump else { return }
        awaitingJump = nil
        lastEvent = "Cursor on \(diagnostic.fileName), line \(diagnostic.line)"
        announceOnMac(diagnostic, after: 0.8, requested: true)
    }

    private let macSpeaker = AVSpeechSynthesizer()

    /// After Xcode jumps to the line, tell the user what the error is (setting "speakOnMac").
    /// - after: seconds to wait (lets VoiceOver finish reading the line after a jump).
    /// - requested: true when the user asked (watch double tap), which ignores the auto-speak setting.
    private func announceOnMac(_ diagnostic: WatchDiagnostic, after delay: Double, requested: Bool) {
        guard requested || UserDefaults.standard.object(forKey: "speakOnMac") as? Bool ?? true else { return }
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.say(self.spokenError(diagnostic))
        }
    }

    /// The error with its context (ErrorContext): what's wrong, where (block), the code.
    /// Uses the unsaved editor text when it's the open file, so line numbers match.
    func spokenError(_ diagnostic: WatchDiagnostic) -> String {
        let lines: [String]?
        if diagnostic.path == livePath, !liveText.isEmpty {
            lines = liveText.components(separatedBy: "\n")
        } else {
            lines = contents[diagnostic.path] ?? EditTracker.readLines(diagnostic.path)
        }
        return ErrorContext.spoken(diagnostic, lines: lines, detail: errorDetail)
    }

    /// Non-sandboxed: VoiceOver speaks through AppleScript (no focus change). On by default;
    /// falls back to the brief panel when VoiceOver isn't scriptable.
    private var useVoiceOverAppleScript: Bool {
        !isSandboxed && (UserDefaults.standard.object(forKey: "voiceOverAppleScript") as? Bool ?? true)
    }
    @Published private(set) var voiceOverScriptState = VoiceOverBridge.State.unknown("not tried yet")

    /// Live reading of Xcode's editor needs Accessibility permission (macOS prompt, once).
    func requestAccessibility() {
        LiveEditorMonitor.requestTrust()
        accessibilityGranted = LiveEditorMonitor.isTrusted
    }

    func testVoiceOverAppleScript() {
        let ok = VoiceOverBridge.speak("This is how your errors will sound. Missing closing brace. Line 12, in func greet, inside struct Greeting.")
        voiceOverScriptState = VoiceOverBridge.state
        if !ok { say("VoiceOver can't be controlled yet. \(VoiceOverBridge.state.description).") }
    }

    /// "Read errors in VoiceOver's voice (brief panel)". On by default.
    private var readInPanel: Bool {
        UserDefaults.standard.object(forKey: "readErrorsInPanel") as? Bool ?? true
    }

    /// "Speak through VoiceOver (announcements)". Off by default: tested on macOS 26 with
    /// Xcode in front, VoiceOver ignores announcements from an app that isn't in front,
    /// so nothing was heard. Default = quiet VoiceOver (Control), then the system voice.
    private var useVoiceOverAnnouncements: Bool {
        UserDefaults.standard.object(forKey: "speakThroughVoiceOverV2") as? Bool ?? false
    }

    /// Who speaks on the Mac:
    /// 1. VoiceOver itself (announcement) when VoiceOver is on: the user's own voice and
    ///    speed, VoiceOver decides the order, and Control stops it.
    /// 2. VoiceOver on but "Speak through VoiceOver" off (fallback): quiet VoiceOver, then
    ///    the system voice, for things the user asked for only.
    /// 3. VoiceOver off: the system voice.
    /// - urgent: true when the user asked (double tap, shortcut): VoiceOver stops and says it now.
    ///   false for automatic news (build finished…): waits until VoiceOver is done talking.
    private func say(_ text: String, urgent: Bool = true) {
        let voiceOverOn = NSWorkspace.shared.isVoiceOverEnabled
        if voiceOverOn, urgent, useVoiceOverAppleScript {
            // Best path (non-sandboxed): VoiceOver says it in your voice, Xcode stays in front.
            let spoken = VoiceOverBridge.speak(text)
            voiceOverScriptState = VoiceOverBridge.state
            if spoken { lastEvent = "VoiceOver reading (AppleScript): \(text)"; return }
        }
        if voiceOverOn, urgent, readInPanel {
            // You asked to hear it: a brief panel comes to the front so VoiceOver itself
            // reads it (in your voice), then focus goes back to Xcode.
            ErrorReadoutPanel.shared.read(text)
            lastEvent = "VoiceOver reading (panel): \(text)"
            return
        }
        if voiceOverOn, useVoiceOverAnnouncements {
            announceWithVoiceOver(text, urgent: urgent)
        } else if voiceOverOn, !urgent {
            // Automatic news while VoiceOver is talking: don't talk over it.
            // The sound already played; double tap / ⌃⇧⌘E reads it when you want.
            lastEvent = "Not spoken (VoiceOver is on): \(text)"
            return
        } else if voiceOverOn, quietVoiceOverFirst, CGPreflightPostEventAccess() {
            // You asked to hear it: hush VoiceOver first (like pressing Control yourself),
            // then speak, so the two voices don't overlap.
            silenceVoiceOver()
            lastEvent = "Quieted VoiceOver, reading: \(text)"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.15))
                self?.speakInOwnVoice(text)
            }
        } else {
            speakInOwnVoice(text)
        }
    }

    private func speakInOwnVoice(_ text: String) {
        speakWithSynthesizer(text)
    }

    // MARK: - Quieting VoiceOver (sandbox-safe: event posting, not the Accessibility API)

    /// "Quiet VoiceOver before reading an error". On by default; only works once the user
    /// allowed key presses (System Settings → Privacy & Security → Accessibility).
    private var quietVoiceOverFirst: Bool {
        UserDefaults.standard.object(forKey: "quietVoiceOverFirst") as? Bool ?? true
    }

    var canPostKeys: Bool { CGPreflightPostEventAccess() }

    /// Shows macOS's own prompt to allow key presses (once).
    func requestKeyPressAccess() {
        _ = CGRequestPostEventAccess()
        objectWillChange.send()
    }

    /// Taps the Control key: VoiceOver's own "stop talking" key. On its own, Control
    /// does nothing in other apps. Sent only when the user asked to hear an error.
    private func silenceVoiceOver() {
        let source = CGEventSource(stateID: .hidSystemState)
        let control = CGKeyCode(kVK_Control)
        let down = CGEvent(keyboardEventSource: source, virtualKey: control, keyDown: true)
        down?.flags = .maskControl
        let up = CGEvent(keyboardEventSource: source, virtualKey: control, keyDown: false)
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Sandbox-safe: asks VoiceOver to speak `text`. Test question: does VoiceOver still read
    /// it while Xcode is the frontmost app? If it stays silent, turn the setting off.
    private func announceWithVoiceOver(_ text: String, urgent: Bool) {
        let app = NSApplication.shared
        let element: Any = app.mainWindow ?? app.windows.first ?? app
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: (urgent ? NSAccessibilityPriorityLevel.high
                                                           : .medium).rawValue])
        lastEvent = "Asked VoiceOver to read: \(text)"
    }

    private func speakWithSynthesizer(_ text: String) {
        macSpeaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        macSpeaker.speak(utterance)
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
