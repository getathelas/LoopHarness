import Foundation
import RealityKit
import simd

/// Control inputs for one frame.
///
/// Movement is a rate (stick deflection in [−1, 1]²) but look is an
/// *absolute delta in radians* already integrated by the input layer. That
/// distinction is the comfort model: translation may accelerate under a
/// held stick, but reorientation only ever moves as far as the hand (or
/// pad) physically dragged this frame — there is no analog pitch or yaw
/// rate anywhere in the system.
struct HQControlIntent {
    /// x: strafe right, y: walk forward (relative to current heading).
    var move = SIMD2<Float>.zero
    /// Radians to apply this frame. x: yaw right, y: pitch up.
    var lookDelta = SIMD2<Float>.zero
}

/// The player's virtual body in world space, and the root transform that
/// realises it.
///
/// visionOS doesn't let an app move the user's camera — the camera is the
/// headset. Walking through the plaza therefore works by moving the *world*
/// inversely: the player's pose (position + yaw/pitch) is integrated from
/// the control intents, and `apply` writes the inverse transform onto the
/// world root so the plaza slides and rotates around the wearer, pivoting
/// at their head.
///
/// Gravity and collision come from the voxel grid: each frame the player's
/// y is pinned to the surface under them, and horizontal moves are rejected
/// when the destination column steps up more than `HQWorld.maxStepUp` —
/// so the pedestal stairs are walkable but walls, hedges and trunks block.
@MainActor
@Observable
final class HQPlayer {

    /// Eye height above the terrain: 5'10" in metres, per spec.
    static let eyeHeight: Float = 1.778

    /// Walking speed at full stick deflection. Brisk but comfortable.
    static let maxSpeed: Float = 3.0

    /// Virtual pitch limit (~63°) — enough to take in the lantern from the
    /// tower's base without flipping the world overhead.
    static let pitchLimit: Float = 1.1

    /// World-space position; y is the terrain height under the player.
    private(set) var position = HQCampanileScene.spawnPosition
    /// Heading, radians clockwise from north (world −z). 0 faces the tower.
    private(set) var yaw: Float = 0
    /// Virtual look pitch, radians; positive looks up.
    private(set) var pitch: Float = 0

    private var smoothedY: Float = 0
    private var groundTarget: Float = 0

    /// Integrates one frame of input and re-anchors the world.
    func update(
        dt: Float,
        intent: HQControlIntent,
        headPosition: SIMD3<Float>,
        world: HQWorld
    ) {
        // Look: direct deltas, pre-integrated by the input layer.
        yaw = atan2(sinf(yaw + intent.lookDelta.x), cosf(yaw + intent.lookDelta.x))
        pitch = min(max(pitch + intent.lookDelta.y, -Self.pitchLimit), Self.pitchLimit)

        // Heading-relative movement on the ground plane, blocked by voxels.
        let heading = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0, sin(yaw))
        let delta = (right * intent.move.x + heading * intent.move.y) * Self.maxSpeed * dt
        if simd_length_squared(delta) > 0 {
            // Axis-split fallback gives wall sliding instead of a dead stop.
            if !step(by: delta, in: world) {
                _ = step(by: SIMD3(delta.x, 0, 0), in: world)
                _ = step(by: SIMD3(0, 0, delta.z), in: world)
            }
        }

        // Gravity: ease eye height onto the surface so single-voxel steps
        // don't judder the camera.
        if let ground = world.walkableGround(atX: position.x, z: position.z, fromY: position.y) {
            groundTarget = ground
        }
        smoothedY += (groundTarget - smoothedY) * min(1, 10 * dt)
        position.y = smoothedY

        apply(to: world.root, headPosition: headPosition)
    }

    /// Attempts a horizontal move; true when the destination has standable
    /// ground within step range.
    private func step(by delta: SIMD3<Float>, in world: HQWorld) -> Bool {
        let candidate = HQWorld.clampToWalkable(position + delta)
        guard let ground = world.walkableGround(atX: candidate.x, z: candidate.z, fromY: position.y),
              ground - position.y <= HQWorld.maxStepUp else { return false }
        position.x = candidate.x
        position.z = candidate.z
        return true
    }

    /// Writes the inverse-player transform onto the world root: the world
    /// point under the player renders exactly `eyeHeight` below the
    /// wearer's head, rotated so the player's heading faces render-forward.
    private func apply(to worldRoot: Entity, headPosition: SIMD3<Float>) {
        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let pitchRotation = simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
        let rotation = pitchRotation * yawRotation
        let anchor = SIMD3(headPosition.x, headPosition.y - Self.eyeHeight, headPosition.z)
        worldRoot.orientation = rotation
        worldRoot.position = anchor - rotation.act(position)
    }

    /// Spawn on the south path looking at the tower.
    func resetToSpawn() {
        position = HQCampanileScene.spawnPosition
        smoothedY = position.y
        groundTarget = position.y
        yaw = 0
        pitch = 0
    }
}
