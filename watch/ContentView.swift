//
//  ContentView.swift
//  watch (iPhone relay app)
//
//  Created by Reynard Amadeus  on 13/10/26.
//

import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var bridge: PhoneBridge

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    Text(bridge.discoveryStatus)
                    TextField("Pairing code (shown in the Mac app)", text: $bridge.pairingCode)
                        .keyboardType(.numberPad)
                    Button("Test Connection") { bridge.testConnection() }
                    Text(bridge.status)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Advanced") {
                        TextField("Mac address", text: $bridge.macAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("Filled in automatically. Change it only if discovery fails.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Apple Watch") {
                    Text(bridge.watchStatus)
                }

                Section("Latest syntax errors (\(bridge.snapshot.diagnostics.count))") {
                    if bridge.snapshot.diagnostics.isEmpty {
                        Text("None")
                    }
                    ForEach(bridge.snapshot.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(diagnostic.fileName), line \(diagnostic.line)").bold()
                            Text(diagnostic.message).font(.footnote)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section {
                    Text("This app relays errors between your Mac and your watch. The watch wakes it in the background, so after the first successful test you don't need to keep it open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Error Relay")
            .onAppear { bridge.startDiscovery() }
        }
    }
}

#Preview {
    ContentView(bridge: .shared)
}
