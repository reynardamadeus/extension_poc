//
//  FlickDetector.swift
//  watch Watch App
//
//  Detects a quick wrist flick (a fast rotation) with Core Motion.
//  Only works while the app is on screen.
//

import CoreMotion
import Combine
import Foundation

final class FlickDetector: ObservableObject {
    /// Rotation speed in radians per second. Higher = you must flick harder.
    var threshold: Double = 8
    var onFlick: (() -> Void)?

    private let motion = CMMotionManager()
    private var lastFlick = Date.distantPast
    private var startedAt = Date.distantPast

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        startedAt = Date()
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let rate = data?.rotationRate else { return }
            let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
            let now = Date()
            guard speed > self.threshold,
                  now.timeIntervalSince(self.startedAt) > 1.0,    // ignore the wrist raise itself
                  now.timeIntervalSince(self.lastFlick) > 1.5 else { return }   // one flick = one action
            self.lastFlick = now
            self.onFlick?()
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
