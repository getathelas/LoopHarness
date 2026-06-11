//
//  HandTrackingSystem.swift
//  LoopHQ
//
//  ARKit hand-tracking provider that detects independent left/right pinch
//  gestures and exposes drag vectors for the locomotion controller.
//
//  Pinch detection: thumb-tip to index-tip distance < `pinchThreshold`.
//  The pinch origin is captured on the first frame that crosses the
//  threshold; subsequent frames produce a drag vector (current midpoint −
//  origin). Release is detected when the distance exceeds
//  `releaseThreshold` (hysteresis prevents flicker).
//
//  All hand positions are in the device-anchored coordinate space returned
//  by ARKit; the locomotion controller reprojects them into the world
//  frame as needed.
//

import ARKit
import simd
import Observation

@Observable
@MainActor
final class HandTrackingSystem {

    // MARK: - Public state

    struct PinchState {
        var isPinching: Bool = false
        /// World-space position where the pinch began (midpoint of thumb+index).
        var origin: SIMD3<Float> = .zero
        /// Current midpoint while pinching.
        var current: SIMD3<Float> = .zero
        /// Drag vector: `current − origin`.
        var drag: SIMD3<Float> { current - origin }
    }

    private(set) var left  = PinchState()
    private(set) var right = PinchState()

    // MARK: - Thresholds

    /// Distance (m) between thumb-tip and index-tip to trigger a pinch.
    private let pinchThreshold: Float  = 0.025
    /// Distance (m) to release a pinch (wider than trigger for hysteresis).
    private let releaseThreshold: Float = 0.045

    // MARK: - ARKit plumbing

    private let session = ARKitSession()
    private let handProvider = HandTrackingProvider()

    /// Call once when the immersive space opens.
    func start() async {
        do {
            try await session.run([handProvider])
        } catch {
            // Hand tracking unavailable (simulator, permissions denied).
            // The world is still explorable via system gestures fallback.
            return
        }
        await consumeUpdates()
    }

    func stop() {
        session.stop()
    }

    // MARK: - Update loop

    private func consumeUpdates() async {
        for await update in handProvider.anchorUpdates {
            let anchor = update.anchor
            guard anchor.isTracked else { continue }
            switch anchor.chirality {
            case .left:  updatePinch(for: anchor, state: &left)
            case .right: updatePinch(for: anchor, state: &right)
            @unknown default: break
            }
        }
    }

    private func updatePinch(for anchor: HandAnchor, state: inout PinchState) {
        guard
            let skeleton = anchor.handSkeleton,
            let thumbTip = skeleton.joint(.thumbTip) as HandSkeleton.Joint?,
            let indexTip = skeleton.joint(.indexFingerTip) as HandSkeleton.Joint?,
            thumbTip.isTracked, indexTip.isTracked
        else { return }

        let thumbPos = matrix_multiply(
            anchor.originFromAnchorTransform,
            thumbTip.anchorFromJointTransform
        ).columns.3.xyz
        let indexPos = matrix_multiply(
            anchor.originFromAnchorTransform,
            indexTip.anchorFromJointTransform
        ).columns.3.xyz

        let distance = simd_length(thumbPos - indexPos)
        let midpoint = (thumbPos + indexPos) / 2

        if state.isPinching {
            if distance > releaseThreshold {
                state.isPinching = false
            } else {
                state.current = midpoint
            }
        } else {
            if distance < pinchThreshold {
                state.isPinching = true
                state.origin  = midpoint
                state.current = midpoint
            }
        }
    }
}

// MARK: - simd helpers

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
