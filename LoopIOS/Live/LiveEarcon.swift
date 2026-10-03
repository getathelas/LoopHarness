import AVFoundation

/// Short, quiet, click-free cues synthesized locally.
enum LiveEarcon: CaseIterable {
    case connected, ended, disconnected, speaking, tool, muted, unmuted
    var notes: [(frequency: Double, duration: Double)] {
        switch self {
        case .connected: return [(523.25, 0.09), (783.99, 0.14)]
        case .ended: return [(783.99, 0.09), (523.25, 0.15)]
        case .disconnected: return [(392, 0.10), (0, 0.06), (311.13, 0.18)]
        case .speaking: return [(1046.50, 0.055)]
        case .tool: return [(659.25, 0.055), (0, 0.035), (659.25, 0.055)]
        case .muted: return [(440, 0.07), (349.23, 0.08)]
        case .unmuted: return [(349.23, 0.07), (440, 0.08)]
        }
    }
    func buffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let count = notes.reduce(0) { $0 + Int($1.duration * format.sampleRate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        var offset = 0
        for note in notes {
            let frames = Int(note.duration * format.sampleRate)
            for i in 0..<frames {
                let t = Double(i) / format.sampleRate
                let edge = min(1, Double(min(i, frames - 1 - i)) / (format.sampleRate * 0.012))
                let envelope = (0.5 - 0.5 * cos(.pi * edge)) * exp(-3 * t)
                samples[offset + i] = Float(sin(2 * .pi * note.frequency * t) * envelope * (self == .speaking ? 0.065 : 0.11))
            }
            offset += frames
        }
        return buffer
    }
}
