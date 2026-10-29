//
//  ContentView.swift
//  watch Watch App
//
//  Created by Reynard Amadeus  on 13/10/26.
//
//  • Turn the Digital Crown to move between errors.
//  • Double tap your fingers (Series 9 / Ultra 2 and later) or the Go button: Xcode jumps
//    to the error's line, then VoiceOver on the Mac reads it with context
//    ("Missing closing brace. Line 14, in func greet, inside struct Greeting…").
//    With no errors, the Mac says "No errors yet".
//  • Tapping the card or the Read button: hear the error without moving the cursor.
//  • Wrist flick: same as Go.
//  The watch itself never speaks (it would overlap with VoiceOver on the Mac).
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var crown = 0.0
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                if bridge.snapshot.paused, bridge.pairingCode == nil {
                    Label("Project closed in Xcode: paused", systemImage: "pause.circle")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityLabel("Paused. The project is closed in Xcode. Double tap to open it.")
                }
                if let code = bridge.pairingCode {
                    pairingView(code)
                    findMacButton          // the Mac didn't show the code? start over
                } else if !bridge.hasLoaded {
                    ProgressView()
                    Text(bridge.status).font(.footnote).multilineTextAlignment(.center)
                    findMacButton
                } else if let error = bridge.selected {
                    errorCard(error)
                    HStack {
                        Button {
                            bridge.goToSelected()
                        } label: {
                            Label("Go", systemImage: "arrow.right.to.line")
                        }
                        .handGestureShortcut(.primaryAction)   // double tap (finger pinch)
                        .accessibilityLabel("Go to error line in Xcode")
                        .accessibilityHint("Or double tap your fingers. Your Mac reads the error after the jump")

                        Button {
                            bridge.readOnMac()
                        } label: {
                            Label("Read", systemImage: "speaker.wave.2")
                        }
                        .accessibilityLabel("Read error on Mac")
                        .accessibilityHint("Reads it without moving the cursor")
                    }
                    if !bridge.isConnected {
                        Text(bridge.status).font(.footnote).foregroundStyle(.orange)
                        findMacButton
                    }
                } else {
                    Button {
                        bridge.readOnMac()              // the Mac says "No errors yet"
                    } label: {
                        Label("No errors", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .handGestureShortcut(.primaryAction)   // double tap works here too
                    .accessibilityHint("Double tap your fingers to hear it on your Mac")
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
                bridge.selectedIndex = index   // crown detents tick; nothing is spoken here
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
        .onTapGesture { bridge.readOnMac() }   // read only (double tap = go to the line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Error \(bridge.selectedIndex + 1) of \(bridge.errors.count). \(error.spokenSummary)"
                            + (error.kind == .needsBuild ? ". Press Command B to re-check." : ""))
    }

    /// Starts the search for the Mac over (e.g. the Mac never showed the pairing code).
    private var findMacButton: some View {
        Button {
            bridge.rediscover()
        } label: {
            Label("Find my Mac again", systemImage: "arrow.clockwise")
        }
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
            Button("Find my Mac again") {
                bridge.rediscover()
                showSettings = false
            }
            Button("Forget this Mac", role: .destructive) {
                bridge.forgetMac()
                showSettings = false
            }
            Toggle("Keep app running", isOn: $keepRunning)
            Text("Uses a workout session so the app stays alive and a wrist flick can't close it. \(workout.status).")
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
