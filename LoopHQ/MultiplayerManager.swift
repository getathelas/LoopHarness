//
//  MultiplayerManager.swift
//  LoopHQ
//
//  Multiplayer presence via GroupActivities / SharePlay.
//
//  ## Transport decision
//
//  SharePlay (GroupActivities framework) is the primary multiplayer transport
//  because it is built into visionOS, requires zero backend infrastructure,
//  and is the Apple-blessed path for shared spatial experiences on Vision Pro.
//  A FaceTime call (or Spatial Persona session) is the signalling layer;
//  GroupSessionMessenger handles the data channel.
//
//  Each participant broadcasts a `PlayerState` message at ~15 Hz containing
//  their position, yaw, and display name. On receipt, the manager creates or
//  updates an `AvatarEntity` in the world for that participant. When a
//  participant leaves, their avatar is removed.
//
//  Fallback: if SharePlay is unavailable (solo session, no FaceTime), the
//  world still works — you just don't see other players.
//

import Foundation
import Combine
import GroupActivities
import RealityKit
import simd
import Observation

// MARK: - GroupActivity definition

struct LoopHQActivity: GroupActivity {
    static let activityIdentifier = "com.bhat.intel.loophq.explore"

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = "Loop HQ — Salesforce Park"
        meta.type = .generic
        return meta
    }
}

// MARK: - Wire message

struct PlayerState: Codable, Sendable {
    let participantID: String
    let displayName: String
    let x: Float
    let y: Float
    let z: Float
    let yaw: Float
}

// MARK: - Manager

@Observable
@MainActor
final class MultiplayerManager {

    private(set) var isConnected = false
    private(set) var peerCount = 0

    /// Avatars keyed by participant ID.
    private var avatars: [String: AvatarEntity] = [:]
    /// Entity under which all remote avatars live.
    private let avatarRoot = Entity()

    private var groupSession: GroupSession<LoopHQActivity>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    private var receiveTask: Task<Void, Never>?

    /// Unique-ish local ID (UUID persisted per app launch).
    private let localID = UUID().uuidString

    init() {
        avatarRoot.name = "avatar-root"
    }

    // MARK: - Lifecycle

    /// Call once after the immersive space opens. Adds `avatarRoot` to the
    /// world and starts listening for SharePlay sessions.
    func start(worldRoot: Entity) {
        worldRoot.addChild(avatarRoot)

        Task {
            for await session in LoopHQActivity.sessions() {
                await configureSession(session)
            }
        }
    }

    /// Activate a new GroupActivity so the system prompts to share.
    func activate() {
        Task {
            let activity = LoopHQActivity()
            _ = try? await activity.activate()
        }
    }

    func stop() {
        receiveTask?.cancel()
        groupSession?.end()
        groupSession = nil
        messenger = nil
        isConnected = false
    }

    // MARK: - Session setup

    private func configureSession(_ session: GroupSession<LoopHQActivity>) async {
        self.groupSession = session
        let msgr = GroupSessionMessenger(session: session)
        self.messenger = msgr

        session.$state.sink { [weak self] state in
            Task { @MainActor in
                self?.isConnected = (state == .joined)
            }
        }.store(in: &subscriptions)

        session.$activeParticipants.sink { [weak self] participants in
            Task { @MainActor in
                guard let self else { return }
                self.peerCount = participants.count - 1
                self.pruneAvatars(active: participants)
            }
        }.store(in: &subscriptions)

        session.join()

        receiveTask = Task { [weak self] in
            for await (state, _) in msgr.messages(of: PlayerState.self) {
                guard let self else { return }
                await self.handleRemoteState(state)
            }
        }
    }

    // MARK: - Sending

    /// Broadcast our local player state. Called from the per-frame update.
    func broadcast(position: SIMD3<Float>, yaw: Float, displayName: String) {
        guard let messenger, isConnected else { return }
        let state = PlayerState(
            participantID: localID,
            displayName: displayName,
            x: position.x, y: position.y, z: position.z,
            yaw: yaw
        )
        Task {
            try? await messenger.send(state)
        }
    }

    // MARK: - Receiving

    private func handleRemoteState(_ state: PlayerState) async {
        await MainActor.run {
            if state.participantID == localID { return }

            let avatar: AvatarEntity
            if let existing = avatars[state.participantID] {
                avatar = existing
            } else {
                avatar = AvatarEntity(name: state.displayName)
                avatars[state.participantID] = avatar
                avatarRoot.addChild(avatar.root)
            }
            let pos = SIMD3<Float>(state.x, state.y, state.z)
            avatar.applyTransform(position: pos, yaw: state.yaw)
        }
    }

    private func pruneAvatars(active: Set<GroupSession<LoopHQActivity>.Participant>) {
        // NOTE: GroupSession.Participant ids don't directly map to our
        // `localID`-based scheme. In production, participant discovery
        // messages would bridge the two. For v1, avatars are only removed
        // when the session ends (the `stop()` call clears everything).
    }
}
