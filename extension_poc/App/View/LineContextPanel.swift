//
//  LineContextPanel.swift
//  extension_poc
//
//  A floating NSPanel that shows the latest "Read Line Context" result.
//
//  How it works:
//  1. The Xcode extension builds the sentence, speaks it, saves it in the App Group,
//     and posts a distributed notification (extensions can't show windows themselves).
//  2. This app hears the notification and shows the text in an NSPanel.
//  3. The panel is "non-activating": it floats above Xcode but Xcode keeps the
//     keyboard focus, so typing continues. ⌃⇧⌘L moves focus into it on purpose.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

struct CodeLine: Identifiable, Equatable {
    let number: Int
    let code: String
    var id: Int { number }
}

final class LineContextModel: ObservableObject {
    /// Real lines sent by "Show Lines in Panel" (empty for Read Line Context and the test panel).
    @Published var lines: [CodeLine] = []
    @Published var command = "Read Line Context"
    @Published var text = ""
    @Published var line = 0
    @Published var pinned = false
}

final class LineContextPanelController: NSObject, NSWindowDelegate {
    static let shared = LineContextPanelController()

    private let model = LineContextModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var pinWatch: AnyCancellable?
    private let hotKeys = HotKeyCenter(signature: 0x4C43_5458)   // "LCTX"
    private var started = false
    private var tookFocus = false
    private let visibleSeconds = 8.0

    private var isEnabled: Bool {
        SharedSettings.defaults.object(forKey: SharedSettings.Key.showLineContextPanel) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(lineContextArrived(_:)),
            name: SharedSettings.lineContextNotification, object: nil)
        hotKeys.register(keyCode: kVK_ANSI_L, modifiers: controlKey | shiftKey | cmdKey) { [weak self] in
            self?.focusPanel()
        }
        pinWatch = model.$pinned.dropFirst().sink { [weak self] pinned in
            if pinned { self?.hideTask?.cancel() } else { self?.scheduleHide() }
        }
    }

    // MARK: Showing

    @objc private func lineContextArrived(_ note: Notification) {
        showLatest()
    }

    /// Reads the latest result from the App Group and shows it without stealing focus.
    func showLatest() {
        guard isEnabled,
              let info = SharedSettings.defaults.dictionary(forKey: SharedSettings.Key.lineContext),
              let text = info["text"] as? String else { return }
        let lines = (info["lines"] as? [[String: Any]] ?? []).compactMap { row -> CodeLine? in
            guard let number = row["n"] as? Int else { return nil }
            return CodeLine(number: number, code: row["code"] as? String ?? "")
        }
        show(text: text,
             command: info["command"] as? String ?? "Read Line Context",
             line: info["line"] as? Int ?? 0,
             lines: lines)
    }

    func showTest() {
        show(text: "Line 5: variable name within struct Greeting.", command: "Read Line Context v2 (test)", line: 5)
    }

    private func show(text: String, command: String, line: Int, lines: [CodeLine] = []) {
        model.text = text
        model.command = command
        model.line = line
        model.lines = lines
        let panel = makePanelIfNeeded()
        fitToContent(panel)
        panel.orderFrontRegardless()            // show it, but don't make it key (Xcode keeps typing)
        scheduleHide()
    }

    /// Grow or shrink with the content, keeping the panel's top edge where it was.
    private func fitToContent(_ panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: max(size.width, 420), height: min(size.height, 520)))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    /// ⌃⇧⌘L: bring focus into the panel so VoiceOver reads it.
    private func focusPanel() {
        if model.text.isEmpty { showLatest() }
        guard !model.text.isEmpty else { return }
        let panel = makePanelIfNeeded()
        hideTask?.cancel()
        tookFocus = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        returnFocusToXcode()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Code lines take longer to read, so they stay until closed.
        guard !model.pinned, !tookFocus, model.lines.isEmpty else { return }
        hideTask = Task { [weak self, visibleSeconds] in
            try? await Task.sleep(for: .seconds(visibleSeconds))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func returnFocusToXcode() {
        guard tookFocus else { return }
        tookFocus = false
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first?.activate()
    }

    // MARK: The panel

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Line Context"
        panel.isFloatingPanel = true                  // stays above normal windows
        panel.level = .floating
        panel.hidesOnDeactivate = false               // keep showing while Xcode is the active app
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LineContextPanelView(model: model) { [weak self] in
            self?.hide()
        })

        // First time: top-right of the screen. Afterwards macOS remembers where the user put it.
        if !panel.setFrameUsingName("LineContextPanel") {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 20,
                                         y: screen.maxY - panel.frame.height - 20))
        }
        panel.setFrameAutosaveName("LineContextPanel")
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        hideTask?.cancel()
        returnFocusToXcode()
    }
}

struct LineContextPanelView: View {
    @ObservedObject var model: LineContextModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.command)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.text)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.lines.isEmpty {
                CodeLinesView(lines: model.lines, current: model.line)
            }
            HStack {
                Toggle("Keep open", isOn: $model.pinned)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)      // Esc
            }
        }
        .padding(16)
        .frame(minWidth: 380)
    }
}

/// The real lines from Xcode: line number + code, the cursor's line highlighted.
/// Each row is one VoiceOver element: "Line 12, cursor: let name = ...".
struct CodeLinesView: View {
    let lines: [CodeLine]
    let current: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(line.number)")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                        Text(line.code.isEmpty ? " " : line.code)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(line.number == current ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Line \(line.number)\(line.number == current ? ", cursor" : ""): "
                                        + (line.code.trimmingCharacters(in: .whitespaces).isEmpty
                                           ? "empty" : line.code.trimmingCharacters(in: .whitespaces)))
                }
            }
            .textSelection(.enabled)
        }
        .frame(height: min(CGFloat(lines.count) * 24 + 8, 380))
    }
}
