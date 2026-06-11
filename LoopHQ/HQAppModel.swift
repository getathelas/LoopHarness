import Foundation
import RealityKit
import simd

/// Session-wide state for Loop HQ: the world, the player, the input
/// providers, and multiplayer presence, plus the per-frame loop that stitches
/// them together.
@MainActor
@Observable
final class HQAppModel {

    static let immersiveSpaceID = "hq.park"

    let world = HQWorld()
    let player = HQPlayer()
    let controls = HQControls()
    let multiplayer = HQMultiplayer()

    private(set) var isImmersed = false

    private let avatarsRoot = Entity()
    private var avatarEntities: [UUID: HQAvatarEntity] = [:]
    private var worldBuildTask: Task<Void, Never>?

    /// Demo stand-in for a second participant (simulator has no SharePlay).
    private(set) var testAvatarEnabled = false
    private var testAvatarPhase: Float = 0
    private let testAvatarID = UUID()

    init() {
        avatarsRoot.name = "hq.avatars"
        world.root.addChild(avatarsRoot)
        multiplayer.configure()
    }

    // MARK: Lifecycle

    func enteredPark() async {
        isImmersed = true
        player.resetToSpawn()
        await controls.start()
        // Build in an app-owned task, never the immersive view's `.task`:
        // SwiftUI cancels that task whenever the view is torn down (including
        // transient teardowns while the space opens), and the cancellation
        // propagates into URLSession, killing in-flight tile downloads with
        // NSURLError -999. The world outlives the view, so its build must too.
        if worldBuildTask == nil {
            let key = googleTilesKey
            worldBuildTask = Task { [world] in
                await world.build(googleTilesKey: key)
            }
        }
    }

    func leftPark() {
        isImmersed = false
        controls.stop()
    }

    /// One frame: inputs → locomotion → presence → avatars.
    func tick(dt: Float) {
        guard isImmersed, dt > 0 else { return }
        let dt = min(dt, 1.0 / 30.0) // Don't lurch after a hitch.
        player.update(
            dt: dt,
            intent: controls.intent,
            headPosition: controls.headPosition(),
            world: world
        )
        multiplayer.broadcastPoseIfDue(position: player.position, yaw: player.yaw)
        syncAvatars(dt: dt)
    }

    // MARK: Avatars

    private func syncAvatars(dt: Float) {
        var players = multiplayer.remotePlayers
        if testAvatarEnabled {
            players[testAvatarID] = nextTestAvatarPose(dt: dt)
        }

        for (id, remote) in players {
            let entity: HQAvatarEntity
            if let existing = avatarEntities[id] {
                entity = existing
            } else {
                entity = HQAvatarEntity()
                entity.position = remote.position
                avatarEntities[id] = entity
                avatarsRoot.addChild(entity)
            }
            entity.apply(remote, tintSeed: abs(id.hashValue))
            entity.tick(dt: dt, localPlayerPosition: player.position)
        }
        for (id, entity) in avatarEntities where players[id] == nil {
            entity.removeFromParent()
            avatarEntities.removeValue(forKey: id)
        }
    }

    func toggleTestAvatar() {
        testAvatarEnabled.toggle()
    }

    /// Ambles a small loop near spawn so there's someone to walk up to.
    private func nextTestAvatarPose(dt: Float) -> HQRemotePlayer {
        testAvatarPhase += dt * 0.35
        let radius: Float = 4
        let position = SIMD3(sin(testAvatarPhase) * radius, 0, cos(testAvatarPhase) * radius - 6)
        let heading = testAvatarPhase + .pi / 2
        return HQRemotePlayer(
            id: testAvatarID,
            name: "Loopy (demo)",
            position: position,
            yaw: heading,
            lastSeen: Date()
        )
    }

    // MARK: Configuration

    /// Google Maps Tiles API key: runtime override (set in the lobby) wins,
    /// then the build-time value injected from Secrets.xcconfig via
    /// Info.plist. Nil → satellite-imagery fallback world.
    var googleTilesKey: String? {
        if let override = UserDefaults.standard.string(forKey: "hq.googleTilesKey"),
           !override.isEmpty {
            return override
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "GoogleTilesAPIKey") as? String,
           !baked.isEmpty, !baked.hasPrefix("$(") {
            return baked
        }
        return nil
    }
}
