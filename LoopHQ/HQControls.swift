import ARKit
import Foundation
import QuartzCore
import simd

/// Turns the wearer's hands into a pair of virtual joysticks.
///
/// The control scheme (per spec): nothing happens while hands are relaxed.
/// **Pinching** (thumb tip touching index tip) plants a joystick origin at
/// the pinch point; **dragging** the pinched hand away from that origin
/// deflects the stick. Drag distance maps to deflection magnitude, saturating
/// at `saturationDistance`.
///
///  * Left hand  → `move`: drag on the ground plane = walk (forward/back/
///    strafe), expressed relative to where the wearer's head faces.
///  * Right hand → `look`: drag right/left = turn, drag up/down = pitch.
///
/// Releasing the pinch recentres the stick instantly (you stop).
///
/// Also owns the `WorldTrackingProvider`, which supplies the head pose the
/// locomotion math pivots around. On the simulator (no hand tracking) the
/// lobby window's on-screen joysticks feed `virtualIntent` instead.
@MainActor
@Observable
final class HQControls {

    /// Pinch begins under this thumb–index distance (m)…
    private static let pinchStartDistance: Float = 0.022
    /// …and ends above this one (hysteresis so the stick doesn't flutter).
    private static let pinchEndDistance: Float = 0.04
    /// Drag distance (m) for full stick deflection.
    private static let saturationDistance: Float = 0.14
    /// Drags shorter than this are ignored (pinch-in-place ≠ walk).
    private static let deadZone: Float = 0.012

    /// Intent from on-screen joysticks (simulator / accessibility path).
    var virtualIntent = HQControlIntent()

    /// True once hand-tracking data is flowing (device only).
    private(set) var handTrackingActive = false
    private(set) var leftPinching = false
    private(set) var rightPinching = false

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let handTracking = HandTrackingProvider()

    private var latestLeft: HandAnchor?
    private var latestRight: HandAnchor?
    private var leftStickOrigin: SIMD3<Float>?
    private var rightStickOrigin: SIMD3<Float>?
    private var lastHeadPosition = SIMD3<Float>(0, 1.4, 0)
    private var updatesTask: Task<Void, Never>?

    /// Hand intent + virtual joysticks, clamped.
    var intent: HQControlIntent {
        handIntent + virtualIntent
    }

    func start() async {
        var providers: [any DataProvider] = []
        if WorldTrackingProvider.isSupported {
            providers.append(worldTracking)
        }
        if HandTrackingProvider.isSupported {
            providers.append(handTracking)
        }
        guard !providers.isEmpty else { return }
        do {
            try await session.run(providers)
        } catch {
            print("HQControls: ARKit session failed: \(error)")
            return
        }
        guard HandTrackingProvider.isSupported else { return }
        updatesTask = Task { [weak self] in
            guard let handTracking = self?.handTracking else { return }
            for await update in handTracking.anchorUpdates {
                guard let self else { return }
                self.handTrackingActive = true
                switch update.anchor.chirality {
                case .left: self.latestLeft = update.event == .removed ? nil : update.anchor
                case .right: self.latestRight = update.event == .removed ? nil : update.anchor
                }
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        session.stop()
        handTrackingActive = false
        leftStickOrigin = nil
        rightStickOrigin = nil
    }

    /// Current head position in immersive-space coordinates; the pivot for
    /// the world-inverse transform. Falls back to a standing-height guess
    /// until tracking delivers a pose.
    func headPosition() -> SIMD3<Float> {
        if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
            let m = anchor.originFromAnchorTransform
            lastHeadPosition = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        return lastHeadPosition
    }

    // MARK: Hand sticks

    private var handIntent: HQControlIntent {
        var intent = HQControlIntent()
        let (headRight, headForward) = headGroundAxes()

        if let drag = stickDrag(for: latestLeft, origin: &leftStickOrigin) {
            leftPinching = true
            // Project the drag onto the wearer's ground-plane axes: pushing
            // the pinched hand away walks forward, sideways strafes.
            let planar = SIMD3(drag.x, 0, drag.z)
            intent.move = Self.deflection(SIMD2(
                simd_dot(planar, headRight),
                simd_dot(planar, headForward)
            ))
        } else {
            leftPinching = false
        }

        if let drag = stickDrag(for: latestRight, origin: &rightStickOrigin) {
            rightPinching = true
            // Horizontal drag turns, vertical drag pitches.
            let planar = SIMD3(drag.x, 0, drag.z)
            intent.look = Self.deflection(SIMD2(
                simd_dot(planar, headRight),
                drag.y
            ))
        } else {
            rightPinching = false
        }
        return intent
    }

    /// Drag vector from the planted stick origin, or nil when not pinching.
    private func stickDrag(for anchor: HandAnchor?, origin: inout SIMD3<Float>?) -> SIMD3<Float>? {
        guard let anchor, anchor.isTracked,
              let skeleton = anchor.handSkeleton else {
            origin = nil
            return nil
        }
        let thumb = skeleton.joint(.thumbTip)
        let index = skeleton.joint(.indexFingerTip)
        guard thumb.isTracked, index.isTracked else {
            origin = nil
            return nil
        }
        let originFromAnchor = anchor.originFromAnchorTransform
        let thumbPos = (originFromAnchor * thumb.anchorFromJointTransform).columns.3
        let indexPos = (originFromAnchor * index.anchorFromJointTransform).columns.3
        let pinchGap = simd_distance(SIMD3(thumbPos.x, thumbPos.y, thumbPos.z),
                                     SIMD3(indexPos.x, indexPos.y, indexPos.z))
        let pinchPoint = SIMD3(
            (thumbPos.x + indexPos.x) / 2,
            (thumbPos.y + indexPos.y) / 2,
            (thumbPos.z + indexPos.z) / 2
        )

        if origin == nil {
            guard pinchGap < Self.pinchStartDistance else { return nil }
            origin = pinchPoint
            return .zero
        }
        guard pinchGap < Self.pinchEndDistance, let stickOrigin = origin else {
            origin = nil
            return nil
        }
        return pinchPoint - stickOrigin
    }

    /// The wearer's right/forward axes flattened onto the ground plane, so
    /// drags are interpreted relative to where they're facing.
    private func headGroundAxes() -> (right: SIMD3<Float>, forward: SIMD3<Float>) {
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return (SIMD3(1, 0, 0), SIMD3(0, 0, -1))
        }
        let m = anchor.originFromAnchorTransform
        var right = SIMD3(m.columns.0.x, 0, m.columns.0.z)
        var forward = SIMD3(-m.columns.2.x, 0, -m.columns.2.z)
        right = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        return (right, forward)
    }

    /// Dead-zoned, saturating drag → stick deflection in [−1, 1]².
    private static func deflection(_ drag: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(drag)
        guard length > deadZone else { return .zero }
        let scaled = (length - deadZone) / (saturationDistance - deadZone)
        return drag / length * min(scaled, 1)
    }
}
