//
//  WatchBridge.swift
//  watch Watch App
//
//  Talks to the Mac directly over Bluetooth (MacLink). The Mac pushes the
//  error list whenever it changes; this plays haptics only (never speaks:
//  speech on the watch would overlap with VoiceOver on the Mac), and sends
//  "open this error in Xcode" requests. The Mac reads the error after the jump.
//

import Combine
import Foundation
import SwiftUI
import WatchKit

final class WatchBridge: ObservableObject {
    static let shared = WatchBridge()

    @Published private(set) var snapshot = DiagnosticSnapshot.empty
    @Published private(set) var status = "Starting…"
    @Published private(set) var isConnected = false
    @Published private(set) var hasLoaded = false
    /// 4-digit code to compare with the Mac while pairing (shown, not spoken).
    @Published private(set) var pairingCode: String?
    @Published var selectedIndex = 0

    private let link = MacLink()

    var errors: [WatchDiagnostic] { snapshot.diagnostics }

    var selected: WatchDiagnostic? {
        errors.indices.contains(selectedIndex) ? errors[selectedIndex] : nil
    }

    private init() {
        link.onStatus = { [weak self] text, connected in
            guard let self else { return }
            self.status = text
            if connected != self.isConnected {
                self.isConnected = connected
                WKInterfaceDevice.current().play(connected ? .start : .stop)
            }
        }
        link.onPairingCode = { [weak self] code in
            self?.pairingCode = code
            if code != nil { WKInterfaceDevice.current().play(.notification) }   // a tap, no speech
        }
        link.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
        link.onResult = { [weak self] ok, message in self?.handleOpenResult(ok: ok, message: message) }
    }

    // MARK: - Connection

    func connect() { link.connect() }

    /// Watch button "Find my Mac again".
    func rediscover() {
        WKInterfaceDevice.current().play(.click)
        status = "Searching for your Mac…"
        link.rediscover()
    }
    func disconnect() { link.disconnect() }

    /// Removes the pairing with the Mac; the next connection pairs again.
    func forgetMac() {
        snapshot = .empty
        hasLoaded = false
        link.forgetMac()
    }

    // MARK: - Error list

    /// What to tell the user is decided by the shared FeedbackPlanner (same rules as the Mac);
    /// here it becomes a haptic only. The Mac speaks.
    private func handle(_ new: DiagnosticSnapshot) {
        let old = snapshot
        let firstLoad = !hasLoaded
        let highlighted = selected
        snapshot = new
        hasLoaded = true

        let feedback = FeedbackPlanner.plan(old: old, new: new, highlighted: highlighted, firstLoad: firstLoad)

        // Keep the highlight on the same problem even if its line number moved.
        if let highlighted, let index = new.diagnostics.firstIndex(where: { $0.isSameProblem(as: highlighted) }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(new.diagnostics.count - 1, 0))
        }

        let device = WKInterfaceDevice.current()
        switch feedback {
        case .none: return
        case .firstErrors, .buildFailed, .newError: device.play(.failure)
        case .buildSucceeded, .allClear, .fixed: device.play(.success)
        case .checkedClear: device.play(.click)
        case .needsBuild: device.play(.directionUp)
        case .stillThere: device.play(.retry)
        case .lingeringError(let error):
            // Live detection: this error stayed (default 10 s). Highlight it so the next
            // double tap jumps straight to it, then buzz.
            if let index = new.diagnostics.firstIndex(where: { $0.isSameProblem(as: error) }) {
                selectedIndex = index
            }
            device.play(.failure)
        }
    }

    // MARK: - Navigation

    func move(by step: Int) {
        guard !errors.isEmpty else { return }
        selectedIndex = (selectedIndex + step + errors.count) % errors.count
        WKInterfaceDevice.current().play(.click)
    }

    /// Double tap: the Mac reads the highlighted error through VoiceOver,
    /// or says "No errors yet" when there are none. The watch itself stays silent.
    func readOnMac() {
        let sent = selected != nil
            ? link.speak(generation: snapshot.generation, index: selectedIndex)
            : link.requestStatus()
        WKInterfaceDevice.current().play(sent ? .click : .failure)
        if !sent { status = "Not connected to your Mac" }
    }

    /// Double tap (non-sandboxed Mac): Xcode jumps to the highlighted error's line, then the
    /// Mac reads it with context. No errors → the Mac says "No errors yet".
    func goToSelected() {
        guard selected != nil else { readOnMac(); return }
        openSelected()
    }

    /// Opens the highlighted error in Xcode on the Mac. The highlight stays on it
    /// until it's fixed (success tap), then moves to the next error.
    func openSelected() {
        guard let target = selected else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        guard link.open(generation: snapshot.generation, index: selectedIndex) else {
            WKInterfaceDevice.current().play(.failure)
            status = "Not connected to your Mac"
            return
        }
        WKInterfaceDevice.current().play(.click)
        status = "Opening line \(target.line)…"
    }

    /// Silent on purpose: the Mac speaks the error after Xcode jumps to it.
    /// The watch only taps (success / failure).
    private func handleOpenResult(ok: Bool, message: String) {
        status = message
        if ok {
            WKInterfaceDevice.current().play(.success)
        } else {
            WKInterfaceDevice.current().play(.failure)
        }
    }
}
