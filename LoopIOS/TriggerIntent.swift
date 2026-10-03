//
//  TriggerIntent.swift
//  Loop
//
//  Created by Ash Bhat on 12/31/25.
//

import AppIntents
import UIKit

struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // your logic here
//        return .result()
        if let sceneDelegate = await currentSceneDelegate() {
            await sceneDelegate.handleMicURL()
        }
        return .result()
    }
    
    @MainActor
    func currentSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .delegate as? SceneDelegate
    }
}

/// Opens the foreground chat before acquiring microphone/audio resources.
struct StartLiveChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Live Chat"
    static var description = IntentDescription("Open Loop and start a live voice conversation.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveLaunchRequest.shared.request()
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            (scene.delegate as? SceneDelegate)?.handlePendingLiveLaunch()
        }
        return .result()
    }
}

/// Surfaces `StartDictationIntent` as a first-class App Shortcut.
///
/// Without this provider the intent only registers after the app's first
/// launch and never auto-populates; declaring it here makes the action
/// available in the Shortcuts app, Spotlight, Siri, and the Action Button
/// list without any user setup. App Shortcut phrases must reference
/// `\(.applicationName)`, which resolves from the app's display/bundle name.
struct LoopAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Start \(.applicationName) dictation",
                "Dictate with \(.applicationName)"
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StartLiveChatIntent(),
            phrases: [
                "Start live chat in \(.applicationName)",
                "Open \(.applicationName) in live mode",
                "Talk live with \(.applicationName)"
            ],
            shortTitle: "Start Live Chat",
            systemImageName: "waveform"
        )

        // iOS 27+ App Intents — guarded at the shortcut level so the
        // provider compiles on older SDKs but the entries only appear
        // when running on iOS 27.
        if #available(iOS 27.0, *) {
            AppShortcut(
                intent: AskLoopIntent(),
                phrases: [
                    "Ask \(.applicationName)",
                    "Hey \(.applicationName)",
                    "Tell \(.applicationName)"
                ],
                shortTitle: "Ask Loop",
                systemImageName: "bubble.left.fill"
            )

            AppShortcut(
                intent: CaptureToLoopIntent(),
                phrases: [
                    "Send this to \(.applicationName)",
                    "Capture this with \(.applicationName)",
                    "Share screen with \(.applicationName)"
                ],
                shortTitle: "Send to Loop",
                systemImageName: "camera.viewfinder"
            )

            AppShortcut(
                intent: LoopRememberIntent(),
                phrases: [
                    "Remember with \(.applicationName)",
                    "\(.applicationName) remember this",
                    "Note in \(.applicationName)"
                ],
                shortTitle: "Remember with Loop",
                systemImageName: "note.text"
            )

            AppShortcut(
                intent: SearchLoopIntent(),
                phrases: [
                    "Search \(.applicationName)",
                    "Find in \(.applicationName)",
                    "Search with \(.applicationName)"
                ],
                shortTitle: "Search Loop",
                systemImageName: "magnifyingglass"
            )
        }
    }
}
