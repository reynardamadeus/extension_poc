//
//  Home.swift
//  extension_poc
//
//  Created by Reynard Amadeus  on 12/10/26.
//

import SwiftUI
import AppKit

struct Home: View {
    // Stored in the shared App Group, so the Xcode extension sees the same values.
    @AppStorage(SharedSettings.Key.style, store: SharedSettings.defaults)
    private var style: BracketSetting = .beginEnd

    @AppStorage(SharedSettings.Key.includeContext, store: SharedSettings.defaults)
    private var includeContext: Bool = true

    @AppStorage(SharedSettings.Key.annotateNewBlocks, store: SharedSettings.defaults)
    private var annotateNewBlocks: Bool = true

    private let sample = """
    struct Greeting {
        func greet(isMorning: Bool) {
            if isMorning {
                print("Good morning")
            } else {
                print("Hello")
            }
        }
    }
    """

    private var previewLines: [String] {
        let lines = sample.components(separatedBy: "\n")
        return BraceAnnotator(style: style, includeContext: includeContext).annotating(lines)
    }

    var body: some View {
        Form {
            Section("How VoiceOver should hear braces") {
                Picker("Words", selection: $style) {
                    ForEach(BracketSetting.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle("Say which block is ending (e.g. \u{201C}end if isMorning\u{201D})",
                       isOn: $includeContext)
            }

            Section("Open Block (Smart Return)") {
                Toggle("Add \(style.openWord) / \(style.closeWord) comments to new blocks",
                       isOn: $annotateNewBlocks)
                Text("Type a line such as add() and press your shortcut (we suggest ⌥Return). The extension adds { and }, and puts the cursor inside. Set the shortcut in Xcode → Settings → Key Bindings, search \u{201C}Open Block\u{201D}.")
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                VStack(alignment: .leading, spacing: 2) {
                    // One Text per line so VoiceOver can read it line by line.
                    ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Preview of annotated code")
            }

            Section("Set up the Xcode extension") {
                Label(SharedSettings.isAppGroupAvailable
                      ? "Settings are shared with the extension"
                      : "App Group missing: the extension cannot see these settings",
                      systemImage: SharedSettings.isAppGroupAvailable
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(SharedSettings.isAppGroupAvailable ? .green : .orange)

                Text("1. Open System Settings → General → Login Items & Extensions → Xcode Source Editor, and turn this extension on.")
                Text("2. Quit and reopen Xcode.")
                Text("3. In Xcode, choose Editor → Brace Reader → Annotate Braces.")
                Text("Changing the words here applies the next time you run the command. No Xcode restart needed.")
                    .foregroundStyle(.secondary)

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
