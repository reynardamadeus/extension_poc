//
//  SpatialAudio.swift
//  extension_poc
//
//  "Mac sounds" feedback for users without a watch: short tones generated in
//  code (no sound files), in both ears. Spoken text goes through VoiceOver
//  (see RelayModel.say), not through here.
//

import AVFoundation

final class SpatialAudio {
    private let engine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    init() {
        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do { try engine.start(); return true } catch { return false }
    }

    // MARK: - Earcons

    /// A short sound for each kind of feedback (same meaning as the watch haptics).
    func play(_ feedback: Feedback) {
        switch feedback {
        case .none: return
        case .firstErrors, .buildFailed, .newError, .lingeringError:
                                                    tones([(440, 0.12), (330, 0.18)])        // down: problem
        case .buildSucceeded, .allClear, .fixed:    tones([(523, 0.10), (659, 0.10), (784, 0.16)])  // up: good
        case .checkedClear:                         tones([(1200, 0.03)], volume: 0.25)       // tick: checked
        case .needsBuild:                           tones([(440, 0.10), (554, 0.14)], volume: 0.4)  // "build me"
        case .stillThere:                           tones([(500, 0.08), (0, 0.06), (500, 0.08)])    // double: still
        }
    }

    private func tones(_ notes: [(frequency: Double, seconds: Double)], volume: Float = 0.5) {
        guard startIfNeeded() else { return }
        let rate = toneFormat.sampleRate
        let totalFrames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.seconds } * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: totalFrames),
              let samples = buffer.floatChannelData?[0] else { return }
        var index = 0
        for note in notes {
            let frames = Int(note.seconds * rate)
            for n in 0..<frames {
                let fade = min(1, Double(min(n, frames - n)) / (rate * 0.008))   // avoid clicks
                let value = note.frequency == 0 ? 0 : sin(2 * .pi * note.frequency * Double(n) / rate) * fade
                samples[index] = Float(value) * volume
                index += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(index)
        tonePlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
        tonePlayer.play()
    }
}
