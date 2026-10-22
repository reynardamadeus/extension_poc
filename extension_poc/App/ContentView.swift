//
//  ContentView.swift
//  extension_poc
//
//  Created by Reynard Amadeus  on 12/10/26.
//

import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var relay = RelayModel()

    var body: some View {
        TabView {
            Home()
                .tabItem { Label("Commands", systemImage: "waveform") }
            RelayView(model: relay)
                .tabItem { Label("Watch Relay", systemImage: "applewatch") }
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            relay.start()
            LineContextPanelController.shared.start()
        }
        .alert(
            "Allow \u{201C}\(relay.pairingRequest?.watchName ?? "Apple Watch")\u{201D} to receive your errors?",
            isPresented: Binding(
                get: { relay.pairingRequest != nil },
                set: { shown in if !shown { relay.answerPairing(allow: false) } }),
            presenting: relay.pairingRequest
        ) { _ in
            Button("Allow") { relay.answerPairing(allow: true) }
            Button("Don't Allow", role: .cancel) { relay.answerPairing(allow: false) }
        } message: { request in
            Text("Code \(request.code). Only allow if the watch shows the same code.")
        }
    }
}

#Preview {
    ContentView()
}
