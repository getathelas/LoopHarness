//
//  MotionActivityManager.swift
//  Loop
//
//  Monitors Core Motion activity transitions and exposes a reactive
//  `isBiking` flag that SwiftUI / UIKit views observe to enlarge tap
//  targets while the user is in motion.
//

#if os(iOS)
import Foundation
import CoreMotion
import os

final class MotionActivityManager {
    static let shared = MotionActivityManager()

    /// Posted on the main queue whenever `isBiking` changes.
    static let bikingStateDidChange = Notification.Name("motionActivityBikingStateDidChange")

    /// True when Core Motion reports `.cycling` or `.automotive` activity.
    private(set) var isBiking: Bool = false {
        didSet {
            guard isBiking != oldValue else { return }
            log.info("isBiking changed to \(self.isBiking)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.bikingStateDidChange, object: nil)
            }
        }
    }

    /// True once `startMonitoring` has been called and the manager is
    /// actively watching for activity updates.
    private(set) var isMonitoring: Bool = false

    private let activityManager = CMMotionActivityManager()
    private let log = Logger(subsystem: "com.bhat.intel", category: "motion")

    private init() {}

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            log.warning("Core Motion activity not available on this device")
            return
        }

        isMonitoring = true
        log.info("Starting motion activity monitoring")

        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.handleActivity(activity)
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        activityManager.stopActivityUpdates()
        isMonitoring = false
        isBiking = false
        log.info("Stopped motion activity monitoring")
    }

    // MARK: - Private

    private func handleActivity(_ activity: CMMotionActivity) {
        // Core Motion may report multiple flags simultaneously. We treat
        // both cycling and automotive as "in motion" — the user needs
        // enlarged targets in either case.
        let inMotion = activity.cycling || activity.automotive

        // Require at least medium confidence to avoid jittery toggling
        // from low-confidence guesses.
        guard activity.confidence == .medium || activity.confidence == .high else {
            return
        }

        isBiking = inMotion
    }
}
#endif
