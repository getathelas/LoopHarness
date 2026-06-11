import Foundation
import RealityKit
import simd

/// Normalised control inputs for one frame, in player-relative terms.
/// Components are in [−1, 1].
struct HQControlIntent {
    /// x: strafe right, y: walk forward (relative to current heading).
    var move = SIMD2<Float>.zero
    /// x: turn right, y: look up. Interpreted as rates.
    var look = SIMD2<Float>.zero

    static func + (lhs: Self, rhs: Self) -> Self {
        func clamp(_ v: SIMD2<Float>) -> SIMD2<Float> {
            simd_clamp(v, SIMD2(repeating: -1), SIMD2(repeating: 1))
        }
        return Self(move: clamp(lhs.move + rhs.move), look: clamp(lhs.look + rhs.look))
    }
}

/// The player's virtual body in park space, and the world transform that
/// realises it.
///
/// visionOS doesn't let an app move the user's camera — the camera is the
/// headset. Walking through a world the size of a city block therefore works
/// by moving the *world* inversely: the player's park-space pose (position +
/// yaw/pitch) is integrated from the control intents, and `apply` writes the
/// inverse transform onto the world root so the park slides and rotates
/// around the wearer, pivoting at their head.
///
/// Gravity: the player's y is pinned to the terrain under them every frame
/// (raycast against streamed photogrammetry, flat deck as fallback), and the
/// world is positioned so their eyes sit exactly `eyeHeight` above that
/// surface — no flying, no clipping through the ground. Horizontal motion is
/// clamped to the park deck so you can't walk off the edge.
@MainActor
@Observable
final class HQPlayer {

    /// Eye height above the terrain: 5'10" in metres, per spec.
    static let eyeHeight: Float = 1.778

    /// Walking speed at full stick deflection. Brisk but comfortable.
    static let maxSpeed: Float = 3.0

    /// Turn/look rates at full deflection.
    static let maxYawRate: Float = 1.7      // rad/s
    static let maxPitchRate: Float = 1.0    // rad/s
    static let pitchLimit: Float = 0.55     // rad (~31°)

    /// Park-space position; y is the terrain height under the player.
    private(set) var position = SIMD3<Float>.zero
    /// Heading, radians clockwise from north (park −z). 0 looks up the bay.
    private(set) var yaw: Float = 0
    /// Virtual look pitch, radians; positive looks up.
    private(set) var pitch: Float = 0

    /// Integrates one frame of input and re-anchors the world.
    func update(
        dt: Float,
        intent: HQControlIntent,
        headPosition: SIMD3<Float>,
        world: HQWorld
    ) {
        // Heading-relative movement on the ground plane.
        let heading = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0, sin(yaw))
        let drive = right * intent.move.x + heading * intent.move.y
        position += drive * Self.maxSpeed * dt

        // Look.
        yaw += intent.look.x * Self.maxYawRate * dt
        pitch = min(max(pitch + intent.look.y * Self.maxPitchRate * dt, -Self.pitchLimit), Self.pitchLimit)

        // Stay on the deck, pinned to the terrain.
        position = HQGeo.clampToWalkableBounds(position)
        position.y = world.smoothedGroundHeight(atParkX: position.x, z: position.z, dt: dt)

        apply(to: world.root, headPosition: headPosition)
    }

    /// Writes the inverse-player transform onto the world root: the park
    /// point under the player renders exactly `eyeHeight` below the wearer's
    /// head, rotated so the player's heading faces render-forward.
    private func apply(to worldRoot: Entity, headPosition: SIMD3<Float>) {
        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let pitchRotation = simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
        let rotation = pitchRotation * yawRotation
        let anchor = SIMD3(headPosition.x, headPosition.y - Self.eyeHeight, headPosition.z)
        worldRoot.orientation = rotation
        worldRoot.position = anchor - rotation.act(position)
    }

    /// Spawn in the middle of the deck facing up the park's long axis.
    func resetToSpawn() {
        position = .zero
        yaw = Float(HQGeo.parkBearing)
        pitch = 0
    }
}
