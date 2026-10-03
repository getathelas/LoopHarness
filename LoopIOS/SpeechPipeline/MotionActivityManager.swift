//
//  MotionActivityManager.swift
//  Loop
//
//  Monitors Core Motion activity transitions and exposes a reactive
//  `isBiking` flag that the audio pipeline consumes. When biking (or
//  automotive motion) is detected the audio session switches to voice-
//  isolation mode and a high-pass wind-rumble filter is engaged.
//
//  Graceful fallback: if CMMotionActivityManager is unavailable or the
//  user denies permission, `isBiking` stays false and the audio pipeline
//  behaves exactly as before.
//

#if os(iOS)
import Foundation
import CoreMotion

final class MotionActivityManager {
    static let shared = MotionActivityManager()

    /// True when Core Motion reports cycling or automotive activity with
    /// reasonable confidence. Other parts of the app (MessageBox, audio
    /// session helpers) observe this to engage wind-noise mitigation.
    private(set) var isBiking: Bool = false {
        didSet {
            guard isBiking != oldValue else { return }
            let active = isBiking
            print("MotionActivityManager: isBiking → \(active)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .motionBikingStateDidChange,
                    object: nil,
                    userInfo: ["isBiking": active]
                )
            }
        }
    }

    private let activityManager = CMMotionActivityManager()
    private var monitoring = false

    private init() {}

    // MARK: - Public API

    /// Begin monitoring activity transitions. Idempotent — calling while
    /// already monitoring is a no-op.
    func startMonitoring() {
        guard !monitoring else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("MotionActivityManager: activity monitoring unavailable on this device")
            return
        }

        monitoring = true
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            self.handleActivity(activity)
        }
        print("MotionActivityManager: started monitoring")
    }

    /// Stop monitoring. Safe to call even if never started.
    func stopMonitoring() {
        guard monitoring else { return }
        activityManager.stopActivityUpdates()
        monitoring = false
        isBiking = false
        print("MotionActivityManager: stopped monitoring")
    }

    // MARK: - Internal

    private func handleActivity(_ activity: CMMotionActivity) {
        // Only trust medium/high confidence updates to avoid flip-flopping
        // on noisy accelerometer data.
        guard activity.confidence == .medium || activity.confidence == .high else { return }
        isBiking = activity.cycling || activity.automotive
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main queue whenever the biking/motion state changes.
    /// `userInfo["isBiking"]` carries the new `Bool` value.
    static let motionBikingStateDidChange = Notification.Name("motionBikingStateDidChange")
}
#endif
