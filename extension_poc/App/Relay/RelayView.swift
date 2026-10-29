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
    @AppStorage("autoSpeakMacSounds") private var autoSpeakMacSounds = true
    @AppStorage("speakThroughVoiceOverV2") private var speakThroughVoiceOver = false
    @AppStorage("readErrorsInPanel") private var readErrorsInPanel = true
    @AppStorage("quietVoiceOverFirst") private var quietVoiceOverFirst = true
    // Non-sandboxed build
    @AppStorage("checkModeV2") private var checkMode = RelayModel.CheckMode.full.rawValue
    @AppStorage("lingerAlerts") private var lingerAlerts = true
    @AppStorage("lingerSeconds") private var lingerSeconds = 10.0
    @AppStorage("errorDetail") private var errorDetail = ErrorContext.Detail.full.rawValue
    @AppStorage("voiceOverAppleScript") private var voiceOverAppleScript = true
    @AppStorage("liveTypeCheck") private var liveTypeCheck = true

    var body: some View {
        Form {
            Section("1. Project folder to watch") {
                Text(model.folder?.path ?? "No folder chosen")
                    .textSelection(.enabled)
                Button("Choose Folder…") { model.chooseFolder() }
                if let message = model.buildSetupMessage {
                    Label(message, systemImage: "hammer")
                }
                Text("Errors update when you build or run (⌘B / ⌘R): every compiler error, not just syntax (types, missing names, wrong arguments…).")
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Picker("Send feedback to", selection: $feedbackMode) {
                    ForEach(RelayModel.FeedbackMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                LabeledContent("Now using", value: model.feedbackRoute)
                Picker("Error detail", selection: $errorDetail) {
                    ForEach(ErrorContext.Detail.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Read in this order: what's wrong, then where (line and the block it's in), then the code on the line. Example: \u{201C}Missing closing brace. Line 14, in func greet, inside struct Greeting, ContentView dot swift. The block opened on line 9 is never closed. Code: if isMorning {\u{201D}")
                    .foregroundStyle(.secondary)
                Toggle("Read errors in VoiceOver's voice (brief panel)", isOn: $readErrorsInPanel)
                Text("When you ask for an error (double tap, ⌃⇧⌘E), a small panel comes to the front for a moment so VoiceOver itself reads it, then you're back in Xcode. Escape returns early.")
                    .foregroundStyle(.secondary)
                Toggle("Speak through VoiceOver (experimental)", isOn: $speakThroughVoiceOver)
                Text("Off (recommended): the app quiets VoiceOver, then reads the error in the system voice. On: asks VoiceOver to read it, but VoiceOver ignores this while Xcode is in front, so you may hear nothing.")
                    .foregroundStyle(.secondary)
                if !speakThroughVoiceOver {
                    Toggle("Quiet VoiceOver before reading an error", isOn: $quietVoiceOverFirst)
                    if model.canPostKeys {
                        Label("Allowed: the app can press Control to quiet VoiceOver", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow Quieting VoiceOver…") { model.requestKeyPressAccess() }
                        Text("Lets the app press Control, VoiceOver's stop-talking key, right before it reads an error you asked for. macOS lists this under Privacy & Security → Accessibility.")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Mac sounds: also say new errors and build results", isOn: $autoSpeakMacSounds)
                Button("Test sounds") { model.testSounds() }
                Text("Without a watch: ⌃⇧⌘E reads the error nearest your cursor, ⌃⇧⌘N jumps to the next error.")
                    .foregroundStyle(.secondary)
            }

            if model.isSandboxed {
                Section("App Store-safe mode") {
                    Label("Runs in the App Sandbox (Mac App Store)", systemImage: "lock.shield")
                    Text("Checks on ⌘B / ⌘R · Xcode opens the error's file, then the extension command \u{201C}Jump to Error Line\u{201D} moves the cursor and the error is read.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Build results folder", value: model.derivedDataDescription)
                    Button("Use Xcode's Shared DerivedData Folder Instead…") { model.chooseDerivedData() }
                        .help("Optional. Normally not needed: choosing a project sets up build results automatically.")
                    Text("Tip: in Xcode → Settings → Key Bindings, give \u{201C}Jump to Error Line\u{201D} a shortcut (e.g. ⌥⌘J).")
                        .foregroundStyle(.secondary)
                }
            } else {
                nonSandboxedSection
                liveDetectionSection
            }

            Section("2. Apple Watch (Bluetooth)") {
                LabeledContent("Status", value: model.bluetoothStatus)
                if let request = model.pairingRequest {
                    // Also here, not only in the alert, in case the alert didn't show.
                    Text("\(request.watchName) wants to pair. Code \(request.code). Only allow if the watch shows the same code.")
                        .bold()
                    HStack {
                        Button("Allow") { model.answerPairing(allow: true) }
                        Button("Don't Allow") { model.answerPairing(allow: false) }
                    }
                }
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

            Section("3. Errors from the last build (\(model.snapshot.diagnostics.count))") {
                if model.snapshot.diagnostics.isEmpty {
                    Text(model.folder == nil ? "Choose a folder first" : "No errors")
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
                Text("It's read after \u{201C}Jump to Error Line\u{201D} puts the cursor on the line.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Non-sandboxed build

    /// What this build is and what it unlocks (the team's note on the non-sandboxed version).
    private var nonSandboxedSection: some View {
        Section("Non-sandboxed build") {
            Label("App Sandbox is off: direct distribution (Developer ID), not the Mac App Store",
                  systemImage: "lock.open")
            VStack(alignment: .leading, spacing: 4) {
                Text("Unlocked in this version:")
                Text("• Live error detection while you type, no build needed (syntax errors)")
                Text("• Double tap on the watch jumps Xcode straight to the error line, then reads it")
                Text("• VoiceOver reads errors in your own voice without leaving Xcode (AppleScript)")
                Text("• Build results are read from DerivedData automatically, no folder picker")
            }
            .accessibilityElement(children: .combine)
            Text("Type, missing-name and argument errors still need ⌘B / ⌘R: the live check reads syntax only.")
                .foregroundStyle(.secondary)
            LabeledContent("Build results folder", value: model.derivedDataDescription)
        }
    }

    private var liveDetectionSection: some View {
        Section("Live error detection") {
            Picker("Check errors", selection: $checkMode) {
                ForEach(RelayModel.CheckMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if model.accessibilityGranted {
                Label("Can read Xcode's editor", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow Reading Xcode's Editor…") { model.requestAccessibility() }
                Text("Needed to see your unsaved code. macOS lists it under Privacy & Security → Accessibility.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Now", value: model.liveStatus)
            LabeledContent("Whole project", value: model.projectCheckDescription)
            Text("All files are checked when the project is opened (app start, choosing the folder, or opening it in Xcode) and after every save, without building. ⌘B / ⌘R results are always read and announced too.")
                .foregroundStyle(.secondary)
            Toggle("Full live check: types, names and arguments, not just syntax", isOn: $liveTypeCheck)
            if liveTypeCheck {
                LabeledContent("Full check", value: model.typeCheckStatus)
                Text("Uses the compiler settings from your last ⌘B, so build once after opening a project. Without them, only syntax errors are found while typing.")
                    .foregroundStyle(.secondary)
            }
            Toggle("Error haptic when an error stays", isOn: $lingerAlerts)
            Stepper(value: $lingerSeconds, in: 3...60, step: 1) {
                LabeledContent("Wait before telling the watch", value: "\(Int(lingerSeconds)) seconds")
            }
            .accessibilityValue("\(Int(lingerSeconds)) seconds")
            Text("An error you fix within this time never buzzes. When one stays, the watch plays an error haptic and highlights it: double tap to jump to its line and hear it.")
                .foregroundStyle(.secondary)
            Text("While your cursor is on an error (or 2 lines around it), it's re-checked every time you pause typing: fixed → success haptic. Move away while it's still there → \u{201C}still there\u{201D} haptic.")
                .foregroundStyle(.secondary)
            if let waiting = model.lingerDescription {
                Label(waiting, systemImage: "timer").foregroundStyle(.secondary)
            }

            Toggle("VoiceOver reads errors without leaving Xcode (AppleScript)", isOn: $voiceOverAppleScript)
            if voiceOverAppleScript {
                LabeledContent("VoiceOver", value: model.voiceOverScriptState.description)
                HStack {
                    Button("Test VoiceOver") { model.testVoiceOverAppleScript() }
                    Button("Open VoiceOver Utility") { VoiceOverBridge.openVoiceOverUtility() }
                    if model.voiceOverScriptState == .automationDenied {
                        Button("Open Automation Settings") { VoiceOverBridge.openAutomationSettings() }
                    }
                }
                Text("One-time setup: in VoiceOver Utility → General, tick \u{201C}Allow VoiceOver to be controlled with AppleScript\u{201D}. The first test asks to control VoiceOver: press OK. Until then the brief panel is used.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
