import AVFoundation
import Foundation
import UIKit

final class LevelGuidanceAudioController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func playMeasurementSample() {
        ensureAudioRunning()
        playTone(frequency: 1_050, duration: 0.055, pan: 0, click: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func playMeasurementCompleted() {
        ensureAudioRunning()
        player.stop()
        playSequence([(740, 0.08), (1_040, 0.08), (1_480, 0.14)], pan: 0)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func stop() {
        player.stop()
    }

    private func ensureAudioRunning() {
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            try? engine.start()
        }
    }

    private func playSequence(_ tones: [(Double, TimeInterval)], pan: Double) {
        ensureAudioRunning()
        for (frequency, duration) in tones {
            if let buffer = makeBuffer(
                frequency: frequency,
                duration: duration,
                pan: pan,
                click: false
            ) {
                player.scheduleBuffer(buffer)
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func playTone(
        frequency: Double,
        duration: TimeInterval,
        pan: Double,
        click: Bool
    ) {
        guard let buffer = makeBuffer(
            frequency: frequency,
            duration: duration,
            pan: pan,
            click: click
        ) else { return }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private func makeBuffer(
        frequency: Double,
        duration: TimeInterval,
        pan: Double,
        click: Bool
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        let clampedPan = min(1, max(-1, pan))
        let leftGain = sqrt((1 - clampedPan) / 2)
        let rightGain = sqrt((1 + clampedPan) / 2)

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let progress = Double(frame) / Double(frameCount)
            let envelope = sin(.pi * progress)
            var sample = sin(2 * .pi * frequency * time)
            if click { sample += 0.35 * sin(2 * .pi * frequency * 2.2 * time) }
            let value = Float(sample * envelope * 0.22)
            channels[0][frame] = value * Float(leftGain)
            channels[1][frame] = value * Float(rightGain)
        }
        return buffer
    }
}
