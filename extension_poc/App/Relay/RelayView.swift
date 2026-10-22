//
//  RelayView.swift
//  extension_poc
//

import Combine
import SwiftUI

struct RelayView: View {
    @ObservedObject var model: RelayModel
    @AppStorage("speakOnMac") private var speakOnMac = true
    @AppStorage("holdEditedLines") private var holdEditedLines = false
    @AppStorage("feedbackMode") private var feedbackMode = RelayModel.FeedbackMode.automatic.rawValue
    @AppStorage("ear") private var ear = SpatialAudio.Ear.left.rawValue
    @AppStorage("oneEarVoice") private var oneEarVoice = true
    @AppStorage("autoSpeakMacSounds") private var autoSpeakMacSounds = true
    @AppStorage("liveChecking") private var liveChecking = true
    @AppStorage("checkMode") private var checkMode = RelayModel.CheckMode.buildOnly.rawValue
    @AppStorage("appStoreMode") private var appStoreMode = true
    @AppStorage("lineLeaveTap") private var lineLeaveTap = true

    var body: some View {
        Form {
            Section("1. Project folder to watch") {
                Text(model.folder?.path ?? "No folder chosen")
                    .textSelection(.enabled)
                Button("Choose Folder…") { model.chooseFolder() }
                Text("Syntax errors update when you save (⌘S). All other errors (types, missing names…) update when you build or run (⌘B / ⌘R).")
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Picker("Send feedback to", selection: $feedbackMode) {
                    ForEach(RelayModel.FeedbackMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                LabeledContent("Now using", value: model.feedbackRoute)
                Picker("Ear for error sounds and voice", selection: $ear) {
                    Text("Left").tag(SpatialAudio.Ear.left.rawValue)
                    Text("Right").tag(SpatialAudio.Ear.right.rawValue)
                }
                .pickerStyle(.segmented)
                Toggle("Speak errors in that ear only (not through VoiceOver)", isOn: $oneEarVoice)
                Toggle("Mac sounds: also say new errors and build results", isOn: $autoSpeakMacSounds)
                Button("Test sounds") { model.testSounds() }
                Text("Without a watch: ⌃⇧⌘E reads the error nearest your cursor, ⌃⇧⌘N jumps to the next error. Use headphones: VoiceOver stays in both ears, errors come from one side.")
                    .foregroundStyle(.secondary)
            }

            Section("App Store-safe mode") {
                if model.isSandboxed {
                    Label("Running in the App Sandbox: only App Store-safe features are available",
                          systemImage: "lock.shield")
                } else {
                    Toggle("Use only features the App Store allows", isOn: $appStoreMode)
                }
                Text(model.appStoreMode
                     ? "On: checks on ⌘B / ⌘R only · Xcode opens the error's file, then the extension command \u{201C}Jump to Error Line\u{201D} moves the cursor · one-ear or system voice · no live checking, no Wi-Fi relay."
                     : "Off (research only): live checking, ⌘S checks, exact-line jumps with xed, VoiceOver via AppleScript. Needs the App Sandbox off, so it can't ship on the App Store.")
                    .foregroundStyle(.secondary)
                LabeledContent("Build results folder", value: model.derivedDataDescription)
                Button("Choose DerivedData Folder…") { model.chooseDerivedData() }
                    .help("Needed in the App Sandbox so the app can read ⌘B / ⌘R results")
                if model.appStoreMode {
                    Text("Tip: in Xcode → Settings → Key Bindings, give \u{201C}Jump to Error Line\u{201D} a shortcut (e.g. ⌥⌘J).")
                        .foregroundStyle(.secondary)
                }
            }

            Section("When to check") {
                Picker("Check for errors", selection: $checkMode) {
                    ForEach(RelayModel.CheckMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.appStoreMode)
                Text(model.checkMode == .buildOnly
                     ? "Build only: press ⌘B or ⌘R and you get one complete answer from Xcode's build: every error, including types. This is what the App Store version can do."
                     : "Full: also checks syntax when you save (⌘S) and while you type. Research only: needs the App Sandbox off, so it can't ship on the App Store.")
                    .foregroundStyle(.secondary)
            }

            Section("Live checking while typing") {
                Group {
                    Toggle("Check unsaved code as you type", isOn: $liveChecking)
                    Toggle("Gentle tap when you leave a line that's still broken", isOn: $lineLeaveTap)
                }
                .disabled(model.checkMode == .buildOnly)
                if model.accessibilityGranted {
                    Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Needs Accessibility permission to read Xcode's editor and use the shortcuts",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Grant Accessibility Permission…") { LiveEditorMonitor.requestTrust() }
                }
                LabeledContent("Status", value: model.liveStatus)
                Text("Errors on the line you're typing, and \u{201C}expected '}'\u{201D} while a block is still open, are ignored until you move on.")
                    .foregroundStyle(.secondary)
            }

            Section("2. Apple Watch (Bluetooth)") {
                LabeledContent("Status", value: model.bluetoothStatus)
                Text("Open the watch app near this Mac. The first time, both show a 4-digit code: if they match, press Allow here. After that it connects by itself.")
                    .foregroundStyle(.secondary)
                if model.trustedWatches.isEmpty {
                    Text("No paired watches yet")
                }
                ForEach(model.trustedWatches) { watch in
                    HStack {
                        Label(watch.name, systemImage: "applewatch")
                        Spacer()
                        Button("Forget") { model.forget(watch) }
                            .accessibilityLabel("Forget \(watch.name)")
                    }
                }
            }

            if !model.appStoreMode {
                Section("Optional: iPhone relay (old method)") {
                    LabeledContent("Server", value: model.serverStatus)
                    LabeledContent("Pairing code", value: model.pairingCode)
                    ForEach(model.addresses, id: \.self) { address in
                        Text(address)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("The iPhone app finds this Mac automatically. Just enter the pairing code there. (These addresses are only needed if automatic discovery fails.)")
                        .foregroundStyle(.secondary)
                }

            }

            Section("3. Syntax errors (\(model.snapshot.diagnostics.count))") {
                if model.snapshot.diagnostics.isEmpty {
                    Text(model.folder == nil ? "Choose a folder first" : "No syntax errors")
                }
                Label(model.buildDescription, systemImage: "hammer")
                    .foregroundStyle(.secondary)
                Toggle("Hold new errors on the lines being edited (experimental)", isOn: $holdEditedLines)
                if let held = model.heldDescription {
                    Label(held, systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .help("Errors on the lines you're typing are sent to the watch when you edit somewhere else, or after 45 seconds.")
                }
                ForEach(model.snapshot.diagnostics) { diagnostic in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(diagnostic.fileName), line \(diagnostic.line)").bold()
                            Text(diagnostic.message).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open in Xcode") { model.open(diagnostic, source: "Mac app") }
                            .accessibilityLabel("Open \(diagnostic.fileName) line \(diagnostic.line) in Xcode")
                    }
                }
                LabeledContent("Last action", value: model.lastEvent)
                Toggle("Read the error aloud on the Mac when the watch opens it", isOn: $speakOnMac)
                Text("With VoiceOver on, VoiceOver itself reads it right after the line. First enable VoiceOver Utility → General → \u{201C}Allow VoiceOver to be controlled with AppleScript\u{201D}.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
