//
//  LocomotionController.swift
//  LoopHQ
//
//  Translates hand-tracking pinch gestures into grounded first-person
//  locomotion. Called every frame from the RealityKit scene-update callback.
//
//  Left-hand pinch + drag  → 2D movement on the ground plane (relative to
//                             the player's current yaw).
//  Right-hand pinch + drag → yaw/pitch camera rotation.
//
//  The player is always pinned to the terrain at `eyeHeight` above the
//  surface; there is no jump, no fly, and no clipping through the ground.
//

import simd
import RealityKit

@MainActor
final class LocomotionController {

    // MARK: - State

    /// Horizontal facing angle (radians, 0 = −Z, positive = counter-clockwise
    /// when viewed from above — standard visionOS convention).
    private(set) var yaw: Float   = 0
    /// Vertical tilt (radians, positive = looking up).
    private(set) var pitch: Float = 0

    /// World-space position of the player's feet (y = terrain height).
    private(set) var position: SIMD3<Float> = .zero

    private let hands: HandTrackingSystem

    init(hands: HandTrackingSystem) {
        self.hands = hands
    }

    // MARK: - Per-frame update

    /// Called from `SceneEvents.Update`. `dt` is `event.deltaTime`.
    func update(dt: Float, cameraRig: Entity) {
        applyLook(dt: dt)
        applyMovement(dt: dt)
        snapToTerrain()
        applyCameraRig(cameraRig)
    }

    // MARK: - Look (right hand)

    private func applyLook(dt: Float) {
        guard hands.right.isPinching else { return }
        let drag = hands.right.drag
        // Horizontal drag → yaw, vertical drag → pitch.
        let sensitivity = HQConfiguration.lookSensitivity
        yaw   -= drag.x * sensitivity
        pitch += drag.y * sensitivity
        pitch  = min(max(pitch, -HQConfiguration.maxPitch), HQConfiguration.maxPitch)
    }

    // MARK: - Movement (left hand)

    private func applyMovement(dt: Float) {
        guard hands.left.isPinching else { return }
        let drag = hands.left.drag
        // Project drag onto the ground plane (xz). The drag is in device
        // space; we interpret x as strafe and z as forward/back.
        let rawLen = simd_length(SIMD2<Float>(drag.x, drag.z))
        guard rawLen > 0.001 else { return }

        let t = min(rawLen / HQConfiguration.maxDragDistance, 1)
        let speed = HQConfiguration.moveSpeed * t
            * (rawLen > HQConfiguration.maxDragDistance
                ? HQConfiguration.sprintMultiplier : 1)

        // Direction relative to current yaw.
        let cosY = cosf(yaw)
        let sinY = sinf(yaw)
        let localDir = SIMD2<Float>(drag.x, drag.z)
        let normDir  = normalize(localDir)

        let worldDx =  normDir.x * cosY + normDir.y * sinY
        let worldDz = -normDir.x * sinY + normDir.y * cosY

        position.x += worldDx * speed * dt
        position.z += worldDz * speed * dt
    }

    // MARK: - Terrain pinning

    private func snapToTerrain() {
        let groundY = WorldRenderer.sampleHeight(x: position.x, z: position.z)
        position.y = groundY
    }

    // MARK: - Camera rig

    private func applyCameraRig(_ rig: Entity) {
        let eyeOffset = SIMD3<Float>(0, HQConfiguration.eyeHeight, 0)
        rig.position = position + eyeOffset
        // Build orientation: yaw around Y, pitch around X.
        let qYaw   = simd_quatf(angle: yaw,   axis: SIMD3<Float>(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch,  axis: SIMD3<Float>(1, 0, 0))
        rig.orientation = qYaw * qPitch
    }
}
