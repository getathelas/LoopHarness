// Offline iOS simulator smoke test. See docs/gpt-live.md. Captured samples are discarded.
import UIKit
import AVFoundation

final class SmokeDelegate: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 let audio = LiveAudio()
 var music: AVAudioPlayer?
 var bytes = 0
 func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  let w = UIWindow(frame: UIScreen.main.bounds); w.rootViewController = UIViewController(); w.makeKeyAndVisible(); window = w
  DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run() }
  return true
 }
 func run() {
  do {
   audio.onInput = { [weak self] data, _ in self?.bytes += data.count }
   try audio.start()
   precondition(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
   let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
   let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
   buffer.frameLength = 24000
   for i in 0..<24000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i) * 2 * .pi * 220 / 24000) }
   let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-music-smoke.caf")
   let file = try AVAudioFile(forWriting: url, settings: format.settings)
   try file.write(from: buffer)
   music = try AVAudioPlayer(contentsOf: url)
   music!.numberOfLoops = -1; music!.volume = 0.05
   precondition(music!.play())
   try audio.play(Data(repeating: 0, count: 4800))
   DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    precondition(self.music!.isPlaying && self.audio.isRunning && self.bytes > 0)
    self.music!.pause()
    precondition(self.music!.play() && self.audio.isRunning)
    print("PASS: music playback and voice-processing capture coexist; input bytes: \(self.bytes)")
    self.music!.stop(); self.audio.stop()
    exit(0)
   }
  } catch { print("FAIL: \(error)"); exit(1) }
 }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SmokeDelegate.self))
