//
//  SpatialAudio.swift
//  extension_poc
//
//  "Mac sounds" feedback for users without a watch. All sounds AND the error
//  voice play in ONE ear (left by default), so they stay apart from VoiceOver
//  reading your code. Tones are generated in code (no sound files).
//

import AVFoundation

final class SpatialAudio {
    enum Ear: String, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
        var pan: Float { self == .left ? -1 : 1 }
    }

    var ear: Ear = .left { didSet { applyPan() } }

    private let engine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private let speechPlayer = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var speechFormat: AVAudioFormat?

    init() {
        engine.attach(tonePlayer)
        engine.attach(speechPlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
        applyPan()
    }

    private func applyPan() {
        tonePlayer.pan = ear.pan
        speechPlayer.pan = ear.pan
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
        case .firstErrors, .buildFailed, .newError: tones([(440, 0.12), (330, 0.18)])        // down: problem
        case .buildSucceeded, .allClear, .fixed:    tones([(523, 0.10), (659, 0.10), (784, 0.16)])  // up: good
        case .checkedClear:                         tones([(1200, 0.03)], volume: 0.25)       // tick: checked
        case .needsBuild:                           tones([(440, 0.10), (554, 0.14)], volume: 0.4)  // "build me"
        case .stillThere:                           tones([(500, 0.08), (0, 0.06), (500, 0.08)])    // double: still
        case .lineLeft:                             tones([(392, 0.09)], volume: 0.3)         // soft: gentle hint
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

    // MARK: - One-ear voice

    /// Speaks in the chosen ear only (English voice; compiler messages are English).
    func speak(_ text: String) {
        guard startIfNeeded() else { return }
        speechPlayer.stop()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        Self.render(utterance, with: synthesizer, to: self)
    }

    /// The synthesizer hands back audio on its own thread; play it on the main thread.
    nonisolated private static func render(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer,
                                           to target: SpatialAudio) {
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            nonisolated(unsafe) let audio = pcm
            DispatchQueue.main.async { MainActor.assumeIsolated { target.schedule(audio) } }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if speechFormat != buffer.format {
            speechPlayer.stop()
            engine.connect(speechPlayer, to: engine.mainMixerNode, format: buffer.format)
            speechFormat = buffer.format
            applyPan()
        }
        speechPlayer.scheduleBuffer(buffer, completionHandler: nil)
        if !speechPlayer.isPlaying { speechPlayer.play() }
    }
}
