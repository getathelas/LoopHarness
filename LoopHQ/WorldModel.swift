//
//  WorldModel.swift
//  LoopHQ
//
//  Shared observable state that the lobby and immersive views both read.
//

import Observation
import RealityKit

@Observable
final class WorldModel {

    static let immersiveSpaceID = "hq-world"

    enum Phase {
        case lobby
        case loading
        case immersed
    }

    private(set) var phase: Phase = .lobby
    private(set) var statusMessage: String = "Ready"

    // MARK: - World root

    /// The single RealityKit entity tree rooted here. `HQImmersiveView` adds
    /// it to the `RealityViewContent`; subsystems (terrain, avatars) attach
    /// children to it.
    let worldRoot = Entity()

    /// The player's virtual camera rig. Children of worldRoot; locomotion
    /// moves this, and the immersive view binds the head-tracked camera
    /// offset to it.
    let cameraRig = Entity()

    // MARK: - Subsystem handles

    var terrainEntity: ModelEntity?
    var multiplayerManager: MultiplayerManager?
    var locomotionController: LocomotionController?

    // MARK: - Phase transitions

    func beginLoading() {
        phase = .loading
        statusMessage = "Building world…"
    }

    func enterWorld() {
        phase = .immersed
        statusMessage = ""
    }

    func returnToLobby() {
        phase = .lobby
        statusMessage = "Ready"
    }
}
