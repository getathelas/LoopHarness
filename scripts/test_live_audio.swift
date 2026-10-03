// Local-only hardware smoke test; requires existing microphone permission. Captured samples are discarded.
import Foundation
import AVFoundation

@main struct Smoke {
    static func main() {
        do {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP: local diagnostic process does not have microphone permission")
            return
        }
        let audio = LiveAudio()
        var capturedBytes = 0
        var peakLevel: Float = 0
        audio.onInput = { data, level in
            capturedBytes += data.count
            peakLevel = max(peakLevel, level)
        }
        defer { audio.stop() }
        try audio.start()
        try audio.play(Data(repeating: 0, count: 4800))
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        precondition(audio.isRunning)
        precondition(capturedBytes > 0)
        print("PASS: voice-processing engine started, capture bytes arrived, silent playback queued")
        print("Captured bytes: \(capturedBytes); peak level: \(peakLevel)")
        if peakLevel == 0 { print("WARNING: capture contains only silence; speech capture is not verified") }
        } catch { print("FAIL: audio initialization \((error as NSError).code)"); exit(1) }
    }
}
