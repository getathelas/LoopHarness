import Combine
import Foundation
import GroupActivities
import simd

/// The SharePlay activity everyone in a Loop HQ session joins.
struct LoopHQActivity: GroupActivity {
    static let activityIdentifier = "com.bhat.intel.hq.park"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Loop HQ — The Campanile"
        metadata.subtitle = "Meet under the tower"
        metadata.type = .generic
        return metadata
    }
}

/// One participant's pose, broadcast a few times a second. Everything is in
/// the shared world frame (deterministic voxel generation guarantees every
/// device built the same plaza), so a position means the same spot for every
/// participant regardless of their physical room.
struct HQPoseMessage: Codable {
    var name: String
    var position: SIMD3<Float>
    var yaw: Float
}

/// A remote participant as known locally.
struct HQRemotePlayer: Identifiable {
    let id: UUID
    var name: String
    var position: SIMD3<Float>
    var yaw: Float
    var lastSeen: Date
}

/// SharePlay-backed presence: joins `LoopHQActivity` sessions, broadcasts the
/// local player's pose, and tracks everyone else's.
@MainActor
@Observable
final class HQMultiplayer {

    enum State: Equatable {
        case idle
        case waiting
        case joined(participants: Int)
    }

    private(set) var state: State = .idle
    private(set) var remotePlayers: [UUID: HQRemotePlayer] = [:]

    /// Shown above the local player's avatar on other headsets.
    var displayName: String =
        UserDefaults.standard.string(forKey: "hq.displayName") ?? "Visitor" {
        didSet { UserDefaults.standard.set(displayName, forKey: "hq.displayName") }
    }

    private var groupSession: GroupSession<LoopHQActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: Set<Task<Void, Never>> = []
    private var subscriptions: Set<AnyCancellable> = []
    private var lastBroadcast = Date.distantPast

    /// Starts listening for sessions (ours or ones we're invited to).
    func configure() {
        let task = Task {
            for await session in LoopHQActivity.sessions() {
                join(session)
            }
        }
        tasks.insert(task)
    }

    /// Offers the activity to the active FaceTime/SharePlay context.
    func startSharing() {
        Task {
            do {
                _ = try await LoopHQActivity().activate()
            } catch {
                print("HQMultiplayer: activation failed: \(error)")
            }
        }
    }

    /// Called from the locomotion loop; rate-limits itself.
    func broadcastPoseIfDue(position: SIMD3<Float>, yaw: Float) {
        guard let messenger, groupSession?.state == .joined else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBroadcast) > 0.1 else { return }
        lastBroadcast = now
        let message = HQPoseMessage(name: displayName, position: position, yaw: yaw)
        Task {
            try? await messenger.send(message)
        }
    }

    func leave() {
        groupSession?.leave()
        reset()
    }

    // MARK: Session plumbing

    private func join(_ session: GroupSession<LoopHQActivity>) {
        reset()
        groupSession = session
        let messenger = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        self.messenger = messenger
        state = .waiting

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessionState in
                if case .invalidated = sessionState {
                    self?.reset()
                }
            }
            .store(in: &subscriptions)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                state = .joined(participants: participants.count)
                // Drop avatars for participants who left.
                let activeIDs = Set(participants.map(\.id))
                remotePlayers = remotePlayers.filter { activeIDs.contains($0.key) }
            }
            .store(in: &subscriptions)

        let receiveTask = Task {
            for await (message, context) in messenger.messages(of: HQPoseMessage.self) {
                let senderID = context.source.id
                guard senderID != session.localParticipant.id else { continue }
                remotePlayers[senderID] = HQRemotePlayer(
                    id: senderID,
                    name: message.name,
                    position: message.position,
                    yaw: message.yaw,
                    lastSeen: Date()
                )
            }
        }
        tasks.insert(receiveTask)

        session.join()
    }

    private func reset() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        messenger = nil
        groupSession = nil
        remotePlayers = [:]
        state = .idle
        configure()
    }
}
