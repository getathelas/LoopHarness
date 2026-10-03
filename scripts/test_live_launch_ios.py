#!/usr/bin/env python3
"""Exercise production Siri handoff code with fake audio/session on a booted simulator."""
import pathlib, plistlib, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
def block(path, marker):
    text = (root / path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
intent = block('LoopIOS/TriggerIntent.swift', 'struct StartLiveChatIntent:')
route = block('LoopIOS/SceneDelegate.swift', 'func handlePendingLiveLaunch()')
consume = block('LoopIOS/MainVC.swift', 'func consumePendingLiveLaunch()')
appear = block('LoopIOS/MainVC.swift', 'override func viewDidAppear(')
source = r'''
import UIKit
import AppIntents
final class LiveSession {
 static let shared = LiveSession()
 var isActive = false
 var starts = 0
 func start() { starts += 1; isActive = true }
}
final class VoiceLoopCoordinator {
 enum State { case idle, recording }
 static let shared = VoiceLoopCoordinator()
 var state: State = .idle
}
final class MainVC: UIViewController {
 var liveOrbController: NSObject?
 var messages: [String] = []
 var liveBaseMessages: [String] = []
 func startLiveChat() { liveOrbController = NSObject(); LiveSession.shared.start() }
 APPEAR
 CONSUME
}
INTENT
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
 var window: UIWindow?
 var tested = false
 ROUTE
 func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
  let window = UIWindow(windowScene: scene as! UIWindowScene)
  window.rootViewController = UINavigationController(rootViewController: MainVC())
  self.window = window; window.makeKeyAndVisible()
 }
 func sceneDidBecomeActive(_ scene: UIScene) {
  handlePendingLiveLaunch()
  guard !tested else { return }; tested = true
  Task { @MainActor in
   do {
    try await Task.sleep(nanoseconds: 800_000_000)
    precondition(LiveSession.shared.starts == 1, "Cold-start request was lost")
    _ = try await StartLiveChatIntent().perform()
    precondition(LiveSession.shared.starts == 1, "Active live call restarted")
    let nav = window!.rootViewController as! UINavigationController
    let main = nav.viewControllers[0] as! MainVC
    LiveSession.shared.isActive = false
    nav.pushViewController(UIViewController(), animated: false)
    _ = try await StartLiveChatIntent().perform()
    try await Task.sleep(nanoseconds: 800_000_000)
    precondition(nav.topViewController === main && LiveSession.shared.starts == 2, "Settings route failed")
    LiveSession.shared.isActive = false
    nav.present(UIViewController(), animated: false)
    try await Task.sleep(nanoseconds: 100_000_000)
    _ = try await StartLiveChatIntent().perform()
    try await Task.sleep(nanoseconds: 800_000_000)
    precondition(nav.presentedViewController == nil && LiveSession.shared.starts == 3, "Modal route failed starts=\(LiveSession.shared.starts) pending=\(LiveLaunchRequest.shared.isPending()) presented=\(String(describing: nav.presentedViewController)) window=\(String(describing: main.viewIfLoaded?.window))")
    LiveSession.shared.isActive = false
    VoiceLoopCoordinator.shared.state = .recording
    _ = try await StartLiveChatIntent().perform()
    precondition(LiveSession.shared.starts == 3 && LiveLaunchRequest.shared.isPending())
    VoiceLoopCoordinator.shared.state = .idle
    main.consumePendingLiveLaunch()
    precondition(LiveSession.shared.starts == 4)
    let request = LiveLaunchRequest()
    let now = Date()
    request.request(now: now)
    precondition(!request.consume(now: now.addingTimeInterval(61)))
    request.request(now: now)
    precondition(request.consume(now: now) && !request.consume(now: now))
    print("PASS: actual intent, cold-start handoff, warm Settings/modal routing, active-call idempotence, busy deferral and expiry")
    exit(0)
   } catch { fatalError("Intent test failed: \(error)") }
  }
 }
}
final class Delegate: UIResponder, UIApplicationDelegate {
 func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  // Same one-shot request the intent deposits before the storyboard exists.
  LiveLaunchRequest.shared.request()
  return true
 }
 func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
  let config = UISceneConfiguration(name: "Test", sessionRole: session.role)
  config.delegateClass = SceneDelegate.self
  return config
 }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
'''.replace('APPEAR', appear).replace('CONSUME', consume).replace('INTENT', intent).replace('ROUTE', route)
device = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='loop-siri-test-') as temp:
    folder = pathlib.Path(temp); app = folder / 'LiveLaunchTest.app'; app.mkdir()
    bundle = 'com.loop.live-launch-test'
    (folder / 'main.swift').write_text(source)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'LiveLaunchTest',
        'CFBundleName': 'LiveLaunchTest', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
          'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Test'}]}}
    }))
    sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun','swiftc','-sdk',sdk,'-target','arm64-apple-ios17.6-simulator',
      str(root/'LoopIOS/Live/LiveLaunchRequest.swift'),str(folder/'main.swift'),'-o',str(app/'LiveLaunchTest')],check=True)
    subprocess.run(['xcrun','simctl','install',device,str(app)],check=True)
    try:
        result = subprocess.run(['xcrun','simctl','launch','--console',device,bundle],capture_output=True,text=True,timeout=60)
        print(result.stdout)
        if 'PASS:' not in result.stdout: raise SystemExit(result.stderr + result.stdout)
    finally:
        subprocess.run(['xcrun','simctl','uninstall',device,bundle],check=False)
