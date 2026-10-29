//
//  ErrorReadoutPanel.swift
//  extension_poc
//
//  Lets VoiceOver ITSELF read an error (the user's own voice and speed, one voice only).
//
//  Why a panel: VoiceOver ignores accessibility announcements from an app that isn't in
//  front, and Xcode always is. So for a moment this app comes to the front with a small
//  panel, asks VoiceOver to read the error, then closes and gives focus back to Xcode.
//
//  • Closes by itself after about the time the sentence takes to read.
//  • Escape or Return closes it right away (back to Xcode).
//  • Sandbox-safe: only activates our own app and Xcode, no Accessibility API.
//

import AppKit
import Combine
import SwiftUI

final class ErrorReadoutPanel: NSObject, NSWindowDelegate {
    static let shared = ErrorReadoutPanel()

    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private let model = ErrorReadoutModel()

    /// Reads `text` with VoiceOver, then returns focus to Xcode.
    func read(_ text: String) {
        let panel = makePanelIfNeeded()
        model.text = text
        closeTask?.cancel()
        installKeyMonitor()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        closeTask = Task { [weak self] in
            // Let VoiceOver finish saying the window switch, then read the error itself.
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
            // No "finished speaking" callback exists: wait about as long as reading takes
            // (≈ 15 characters a second, a typical VoiceOver speed), at least 2.5 s.
            let seconds = min(20, max(2.5, Double(text.count) / 15 + 1))
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.close()
        }
    }

    /// Hides the panel and puts the user back in Xcode where they were.
    func close() {
        closeTask?.cancel()
        removeKeyMonitor()
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first?.activate()
    }

    // MARK: Keys: Escape / Return close early

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.keyCode == 53 || event.keyCode == 36 else { return event }   // Escape, Return
            self.close()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: The panel

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Error"                          // short: VoiceOver says it on the switch
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ErrorReadoutView(model: model))
        panel.center()
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }
}

final class ErrorReadoutModel: ObservableObject {
    @Published var text = ""
}

private struct ErrorReadoutView: View {
    @ObservedObject var model: ErrorReadoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Closes by itself · Escape to go back to Xcode now")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)            // don't make VoiceOver read the hint every time
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
    }
}
