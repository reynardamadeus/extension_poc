//
//  Home.swift
//  extension_poc
//
//  Created by Reynard Amadeus  on 12/10/26.
//
//  Lists the Xcode extension's commands (CodeVoice + Open Block + Jump to Error)
//  and how to turn the extension on.
//

import SwiftUI
import AppKit

struct Home: View {
    @AppStorage(SharedSettings.Key.showLineContextPanel, store: SharedSettings.defaults)
    private var showPanel = true
    private struct Command: Identifiable {
        let name: String
        let says: String
        var id: String { name }
    }

    private let codeVoice: [Command] = [
        .init(name: "Show Lines in Panel", says: "Shows the real code around your cursor (or your selection) in the floating panel"),
        .init(name: "Read Line Context", says: "\u{201C}Inside struct Greeting. Line 5. Code: \u{2026}\u{201D}"),
        .init(name: "Read Line Context v2", says: "\u{201C}Line 5: variable name within struct Greeting.\u{201D}"),
        .init(name: "Read Line Context v3", says: "\u{201C}Line 5: func greet inside struct Greeting.\u{201D}"),
        .init(name: "Read Code Structure", says: "Line, nesting level, and the block's start and end lines"),
        .init(name: "Check Code Errors", says: "Bracket and quote problems, then an AI check of the file"),
        .init(name: "Summarize File", says: "How many structs, classes and functions, plus a one-sentence summary"),
        .init(name: "Explain Selected Code", says: "A plain-English sentence about the selected code"),
        .init(name: "Analyze Line Impact", says: "What the line belongs to and what changing it affects"),
    ]

    var body: some View {
        Form {
            Section("CodeVoice: hear where you are") {
                ForEach(codeVoice) { command in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.name).font(.headline)
                        Text(command.says).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("AI commands use Apple Intelligence on this Mac (on-device). If it's off or unavailable, they fall back to a shorter answer.")
                    .foregroundStyle(.secondary)
            }

            Section("Line Context panel") {
                Toggle("Show Read Line Context results in a floating panel", isOn: $showPanel)
                Text("The panel appears in the top-right corner without taking focus from Xcode, and hides after 8 seconds unless you tick Keep open. Press ⌃⇧⌘L to move focus into the panel so VoiceOver reads it; press Esc to close it and go back to Xcode. This app must be running.")
                    .foregroundStyle(.secondary)
                Button("Show Test Panel") {
                    LineContextPanelController.shared.showTest()
                }
            }

            Section("Editing and errors") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Block (Smart Return)").font(.headline)
                    Text("Type a line such as add() and press your shortcut (we suggest ⌥Return). The extension adds { and } and puts the cursor inside.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jump to Error Line").font(.headline)
                    Text("After the watch or ⌃⇧⌘N opens an error's file, this moves the cursor to the error's line.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Section("Set up the Xcode extension") {
                Label(SharedSettings.isAppGroupAvailable
                      ? "Settings are shared with the extension"
                      : "App Group missing: the extension cannot see these settings",
                      systemImage: SharedSettings.isAppGroupAvailable
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(SharedSettings.isAppGroupAvailable ? .green : .orange)

                Text("1. Open System Settings → General → Login Items & Extensions → Xcode Source Editor, and turn this extension on.")
                Text("2. Quit and reopen Xcode. The commands are in the Editor menu under this extension's name.")
                Text("3. Give the ones you use most a shortcut: Xcode → Settings → Key Bindings, search the command name.")

                Button("Open Extension Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.dt.Xcode.extension.source-editor")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 620)
    }
}

#Preview {
    Home()
}
