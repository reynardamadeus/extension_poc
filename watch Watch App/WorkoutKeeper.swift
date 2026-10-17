//
//  WorkoutKeeper.swift
//  watch Watch App
//
//  "Keep app running": starts a workout session so watchOS keeps this app
//  alive in the background (Bluetooth, haptics and the open request keep
//  working even if the system's wrist flick goes to the watch face), and
//  brings the app back when the wrist is raised.
//
//  No workout data is recorded or saved.
//  ⚠️ Fine for development / research builds. The App Store only allows
//  workout sessions for real workouts, so remove this before submitting.
//

import Combine
import Foundation
import HealthKit

final class WorkoutKeeper: NSObject, ObservableObject, HKWorkoutSessionDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off"

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    func start() {
        guard session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { status = "Not available on this device"; return }
        status = "Starting…"
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let message { self.status = "Health permission error: \(message)"; return }
                self.begin()
            }
        }
    }

    func stop() {
        session?.end()
        session = nil
        isRunning = false
        status = "Off"
    }

    private func begin() {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            session.delegate = self
            session.startActivity(with: Date())
            self.session = session
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
        }
    }

    // MARK: - HKWorkoutSessionDelegate (background queue)

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            self.isRunning = toState == .running
            switch toState {
            case .running: self.status = "On: app stays open"
            case .ended, .stopped: self.status = "Off"; self.session = nil
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.status = "Failed: \(message)"
            self.session = nil
            self.isRunning = false
        }
    }
}
