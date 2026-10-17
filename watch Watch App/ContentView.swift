//
//  ContentView.swift
//  watch Watch App
//
//  Created by Reynard Amadeus  on 13/10/26.
//
//  • Turn the Digital Crown to move between errors.
//  • Wrist flick (or the Open button) opens the selected error in Xcode.
//  • Double tap your fingers (Series 9 / Ultra 2 and later), the Read button,
//    or tapping the card reads the error aloud on the Mac via VoiceOver.
//

import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var bridge: WatchBridge
    @StateObject private var flick = FlickDetector()
    @StateObject private var workout = WorkoutKeeper()
    @AppStorage("keepRunning") private var keepRunning = true
    @AppStorage("flickEnabled") private var flickEnabled = true
    @AppStorage("flickThreshold") private var flickThreshold = 8.0
    @AppStorage("speakErrors") private var speakErrors = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var crown = 0.0
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                if let code = bridge.pairingCode {
                    pairingView(code)
                } else if !bridge.hasLoaded {
                    ProgressView()
                    Text(bridge.status).font(.footnote).multilineTextAlignment(.center)
                } else if let error = bridge.selected {
                    errorCard(error)
                    HStack {
                        Button {
                            bridge.openSelected()
                        } label: {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                        .accessibilityLabel("Open in Xcode")
                        .accessibilityHint("Or flick your wrist")

                        Button {
                            bridge.speakSelectedOnMac()
                        } label: {
                            Label("Read", systemImage: "speaker.wave.2")
                        }
                        .handGestureShortcut(.primaryAction)   // double tap (finger pinch)
                        .accessibilityLabel("Read error on Mac")
                        .accessibilityHint("Or double tap your fingers")
                    }
                    if !bridge.isConnected {
                        Text(bridge.status).font(.footnote).foregroundStyle(.orange)
                    }
                } else {
                    Label("No syntax errors", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(bridge.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .digitalCrownRotation($crown, from: 0, through: Double(max(bridge.errors.count - 1, 0)),
                                  by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { settings }
        }
        .onChange(of: crown) { _, value in
            let index = Int(value.rounded())
            if index != bridge.selectedIndex {
                bridge.selectedIndex = index
                bridge.readSelected()          // turning the crown reads the new error
            }
        }
        .onChange(of: bridge.selectedIndex) { _, index in
            if Int(crown.rounded()) != index { crown = Double(index) }
        }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? resume() : pause()
        }
        .onChange(of: flickEnabled) { _, _ in resume() }
        .onChange(of: keepRunning) { _, on in on ? workout.start() : workout.stop() }
        .onChange(of: flickThreshold) { _, value in flick.threshold = value }
        .onAppear { resume() }
    }

    private func errorCard(_ error: WatchDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(bridge.selectedIndex + 1) of \(bridge.errors.count)")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Line \(error.line)")
                .font(.title2).bold()
            Text(error.fileName)
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Text(error.message)
                .font(.footnote).lineLimit(3).minimumScaleFactor(0.8)
            if error.kind == .needsBuild {
                Label("Press ⌘B to re-check", systemImage: "hammer")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { bridge.speakSelectedOnMac() }   // same as double tap
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Error \(bridge.selectedIndex + 1) of \(bridge.errors.count). \(error.spokenSummary)"
                            + (error.kind == .needsBuild ? ". Press Command B to re-check." : ""))
    }

    /// Shown (not spoken) while pairing, so people nearby can't hear the code.
    private func pairingView(_ code: String) -> some View {
        VStack(spacing: 4) {
            Text("Pair with your Mac").font(.headline)
            Text(code)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Code " + code.map(String.init).joined(separator: " "))
            Text("If your Mac shows the same code, press Allow on the Mac.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        List {
            Button("Forget this Mac", role: .destructive) {
                bridge.forgetMac()
                showSettings = false
            }
            Toggle("Keep app running", isOn: $keepRunning)
            Text("Uses a workout session so the app stays alive and a wrist flick can't close it. \(workout.status).")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Speak errors aloud", isOn: $speakErrors)
            Text("When VoiceOver is on, VoiceOver reads them instead.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Wrist flick opens error", isOn: $flickEnabled)
            VStack(alignment: .leading) {
                Text("Flick strength: \(Int(flickThreshold))")
                Slider(value: $flickThreshold, in: 4...16, step: 1)
                Text("Lower is more sensitive.").font(.footnote).foregroundStyle(.secondary)
            }
            if !flick.isAvailable {
                Text("Motion sensors aren't available on this device.").font(.footnote)
            }
        }
    }

    private func resume() {
        bridge.connect()
        if keepRunning { workout.start() }
        flick.threshold = flickThreshold
        let watchBridge = bridge
        flick.onFlick = { [weak watchBridge] in
            guard let watchBridge, watchBridge.selected != nil else { return }   // no buzz for stray flicks
            watchBridge.openSelected()
        }
        if flickEnabled { flick.start() } else { flick.stop() }
    }

    private func pause() {
        flick.stop()   // no flick detection while the screen is off (avoids accidental opens)
        // With "Keep app running" on, stay connected in the background so new errors
        // still buzz and an open request sent just before the screen turned off completes.
        if !workout.isRunning { bridge.disconnect() }
    }
}

#Preview {
    ContentView(bridge: .shared)
}
