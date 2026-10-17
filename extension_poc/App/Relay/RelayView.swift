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

    var body: some View {
        Form {
            Section("1. Project folder to watch") {
                Text(model.folder?.path ?? "No folder chosen")
                    .textSelection(.enabled)
                Button("Choose Folder…") { model.chooseFolder() }
                Text("Syntax errors update when you save (⌘S). All other errors (types, missing names…) update when you build or run (⌘B / ⌘R).")
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
