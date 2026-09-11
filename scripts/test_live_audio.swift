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
        audio.onInput = { data, _ in capturedBytes += data.count }
        defer { audio.stop() }
        try audio.start()
        try audio.play(Data(repeating: 0, count: 4800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(audio.isRunning)
        precondition(capturedBytes > 0)
        print("PASS: voice-processing engine started, capture bytes arrived, silent playback queued")
        } catch { print("FAIL: audio initialization \((error as NSError).code)"); exit(1) }
    }
}
