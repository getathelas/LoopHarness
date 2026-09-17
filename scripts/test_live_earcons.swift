import AVFoundation

@main struct EarconTests {
    static func main() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        for cue in LiveEarcon.allCases {
            let buffer = cue.buffer(format: format)
            let samples = buffer.floatChannelData![0]
            let count = Int(buffer.frameLength)
            precondition(count > 0 && count <= 24000 / 2)
            precondition(abs(samples[0]) < 0.00001 && abs(samples[count - 1]) < 0.00001)
            var energy: Float = 0
            for i in 0..<count {
                precondition(samples[i].isFinite && abs(samples[i]) <= 0.12)
                energy += samples[i] * samples[i]
            }
            precondition(energy > 0)
        }
        print("PASS: all seven cues have bounded volume, non-silent PCM, short duration and click-free edges")
    }
}
