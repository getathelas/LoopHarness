import ARKit
import Foundation
import QuartzCore
import simd

/// Comfort setting for vertical reorientation. Continuous keeps the 1:1
/// pinch-drag mapping; the snap modes turn the same drag into discrete
/// tilts for users who prefer stepwise pitch changes.
enum HQPitchComfort: String, CaseIterable, Identifiable {
    case continuous
    case snap15
    case snap30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuous: return "Smooth"
        case .snap15: return "Snap 15°"
        case .snap30: return "Snap 30°"
        }
    }

    /// Discrete tilt size, nil for continuous.
    var snapAngle: Float? {
        switch self {
        case .continuous: return nil
        case .snap15: return 15 * .pi / 180
        case .snap30: return 30 * .pi / 180
        }
    }
}

/// Turns the wearer's hands into the locomotion inputs.
///
/// The scheme (per spec — joystick pitch was the nausea culprit, so pitch
/// is never a rate):
///
///  * **Left hand — virtual joystick.** Pinch (thumb tip to index tip) to
///    plant a stick origin; drag away from it to walk. Drag distance maps
///    to deflection, saturating at `saturationDistance`. Forward/back/
///    strafe only, relative to where the head faces. Release to stop.
///
///  * **Head — free look.** Untouched; the headset is the camera.
///
///  * **Right hand — pinch-and-drag reorientation.** Pinching grabs the
///    world: while pinched, the angular change of the head→hand ray is
///    applied *inversely* to the view, exactly 1:1 — drag the sky down to
///    look up, pull the world sideways to yaw, like Google Earth VR's drag
///    locomotion. Release to commit, re-pinch anywhere to continue. The
///    1:1 hand mapping keeps the vestibular system calm; there is no
///    analog pitch acceleration anywhere.
///
/// Also owns the `WorldTrackingProvider`, which supplies the head pose the
/// locomotion math pivots around. On the simulator (no hand tracking) the
/// lobby window's on-screen pads feed the same intent instead.
@MainActor
@Observable
final class HQControls {

    /// Pinch begins under this thumb–index distance (m)…
    private static let pinchStartDistance: Float = 0.022
    /// …and ends above this one (hysteresis so the gesture doesn't flutter).
    private static let pinchEndDistance: Float = 0.04
    /// Left stick: drag distance (m) for full deflection.
    private static let saturationDistance: Float = 0.14
    /// Left stick: drags shorter than this are ignored.
    private static let deadZone: Float = 0.012
    /// Right grab: hand rays shorter than this are angularly unstable.
    private static let minGrabRayLength: Float = 0.15
    /// Snap modes: hand arc (radians) that triggers one discrete tilt.
    private static let snapThreshold: Float = 0.2
    /// On-screen look pad: radians per pad unit of drag.
    private static let padLookGain: Float = 1.2

    var pitchComfort: HQPitchComfort {
        didSet { UserDefaults.standard.set(pitchComfort.rawValue, forKey: "hq.pitchComfort") }
    }

    /// Move intent from the on-screen walk pad (simulator / accessibility).
    var virtualMove = SIMD2<Float>.zero

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
    /// Head→hand ray angles at the previous frame of an active right grab.
    private var rightGrabSample: (azimuth: Float, elevation: Float)?
    private var snapAccumulator: Float = 0
    private var lastHeadPosition = SIMD3<Float>(0, 1.4, 0)
    private var updatesTask: Task<Void, Never>?

    /// Look-pad drag deltas accumulated since the last frame. Deltas (not
    /// positions) so releasing the pad commits the view instead of
    /// springing it back.
    private var pendingPadLook = SIMD2<Float>.zero
    private var lastPadLook: SIMD2<Float>?

    init() {
        let stored = UserDefaults.standard.string(forKey: "hq.pitchComfort")
        pitchComfort = stored.flatMap(HQPitchComfort.init(rawValue:)) ?? .continuous
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
        rightGrabSample = nil
        snapAccumulator = 0
        lastPadLook = nil
        pendingPadLook = .zero
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

    // MARK: Per-frame intent

    /// Reads both hands and the on-screen pads, returning this frame's
    /// intent. Called exactly once per tick — look deltas are consumed.
    func consumeIntent() -> HQControlIntent {
        var intent = HQControlIntent()

        // Left hand: virtual joystick for translation.
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
        intent.move = simd_clamp(intent.move + virtualMove, SIMD2(repeating: -1), SIMD2(repeating: 1))

        // Right hand: 1:1 drag-the-world reorientation.
        var look = SIMD2<Float>.zero
        if let sample = currentGrabSample() {
            rightPinching = true
            if let previous = rightGrabSample {
                // Wrap so a drag across ±π doesn't whip the view.
                let dAzimuth = atan2(
                    sinf(sample.azimuth - previous.azimuth),
                    cosf(sample.azimuth - previous.azimuth)
                )
                let dElevation = sample.elevation - previous.elevation
                // World follows the hand, so the view moves inversely:
                // dragging the hand down pulls the world down = look up.
                look += SIMD2(-dAzimuth, -dElevation)
            }
            rightGrabSample = sample
        } else {
            rightPinching = false
            rightGrabSample = nil
        }

        // On-screen look pad (look-direction semantics: drag up = look up).
        look += pendingPadLook * Self.padLookGain
        pendingPadLook = .zero

        // Comfort filter: yaw is always continuous (it's 1:1 and benign);
        // pitch optionally quantises into discrete snap tilts.
        if let snapAngle = pitchComfort.snapAngle {
            intent.lookDelta.x = look.x
            snapAccumulator += look.y
            if abs(snapAccumulator) >= Self.snapThreshold {
                intent.lookDelta.y = snapAccumulator > 0 ? snapAngle : -snapAngle
                snapAccumulator = 0
            }
            if !rightPinching, lastPadLook == nil {
                snapAccumulator = 0
            }
        } else {
            intent.lookDelta = look
        }

        return intent
    }

    // MARK: On-screen look pad

    func padLookChanged(_ value: SIMD2<Float>) {
        if let last = lastPadLook {
            pendingPadLook += value - last
        }
        lastPadLook = value
    }

    func padLookEnded() {
        lastPadLook = nil
    }

    // MARK: Hands

    /// Midpoint of the thumb/index tips and their gap, or nil while the
    /// hand isn't reliably tracked.
    private static func pinchPoint(of anchor: HandAnchor?) -> (point: SIMD3<Float>, gap: Float)? {
        guard let anchor, anchor.isTracked,
              let skeleton = anchor.handSkeleton else { return nil }
        let thumb = skeleton.joint(.thumbTip)
        let index = skeleton.joint(.indexFingerTip)
        guard thumb.isTracked, index.isTracked else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        let thumbColumn = (originFromAnchor * thumb.anchorFromJointTransform).columns.3
        let indexColumn = (originFromAnchor * index.anchorFromJointTransform).columns.3
        let thumbPos = SIMD3(thumbColumn.x, thumbColumn.y, thumbColumn.z)
        let indexPos = SIMD3(indexColumn.x, indexColumn.y, indexColumn.z)
        return ((thumbPos + indexPos) / 2, simd_distance(thumbPos, indexPos))
    }

    /// Left-stick drag vector from the planted origin, or nil when not
    /// pinching.
    private func stickDrag(for anchor: HandAnchor?, origin: inout SIMD3<Float>?) -> SIMD3<Float>? {
        guard let pinch = Self.pinchPoint(of: anchor) else {
            origin = nil
            return nil
        }
        if origin == nil {
            guard pinch.gap < Self.pinchStartDistance else { return nil }
            origin = pinch.point
            return .zero
        }
        guard pinch.gap < Self.pinchEndDistance, let stickOrigin = origin else {
            origin = nil
            return nil
        }
        return pinch.point - stickOrigin
    }

    /// The right hand's head→pinch ray angles while grabbing, or nil.
    private func currentGrabSample() -> (azimuth: Float, elevation: Float)? {
        guard let pinch = Self.pinchPoint(of: latestRight) else { return nil }
        let engaged = rightGrabSample != nil
        let threshold = engaged ? Self.pinchEndDistance : Self.pinchStartDistance
        guard pinch.gap < threshold else { return nil }

        let ray = pinch.point - headPosition()
        let length = simd_length(ray)
        guard length > Self.minGrabRayLength else { return rightGrabSample }
        let azimuth = atan2(ray.x, -ray.z)
        let elevation = asin(min(max(ray.y / length, -1), 1))
        return (azimuth, elevation)
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
