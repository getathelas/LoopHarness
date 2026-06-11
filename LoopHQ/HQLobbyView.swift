import GroupActivities
import SwiftUI

/// The launcher window: enter the world, comfort settings, SharePlay, and
/// (mainly for the simulator, where hand tracking doesn't exist) a pair of
/// on-screen pads that mirror the hand controls. The window stays visible
/// inside the immersive space.
struct HQLobbyView: View {
    @Environment(HQAppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        @Bindable var multiplayer = model.multiplayer

        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Loop HQ")
                    .font(.extraLargeTitle2)
                Text("The Campanile · UC Berkeley")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if !model.isImmersed {
                VStack(spacing: 14) {
                    TextField("Your name", text: $multiplayer.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    Button {
                        Task { await openImmersiveSpace(id: HQAppModel.immersiveSpaceID) }
                    } label: {
                        Label("Visit the Campanile", systemImage: "figure.walk")
                            .font(.title3)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                statusSection
                controlsSection
                Button("Leave", role: .destructive) {
                    Task { await dismissImmersiveSpace() }
                }
            }

            comfortSection
            multiplayerSection
        }
        .padding(28)
        .frame(minWidth: 480)
    }

    // MARK: Sections

    private var statusSection: some View {
        Group {
            switch model.world.status {
            case .idle, .building:
                Label("Building the Campanile…", systemImage: "building.columns")
            case .ready(let detail):
                Label(detail, systemImage: "checkmark.circle")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var controlsSection: some View {
        VStack(spacing: 10) {
            if model.controls.handTrackingActive {
                Text("Left pinch + drag walks · turn your head to look · right pinch + drag tilts the view")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Hand tracking unavailable — use the pads below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 60) {
                HQJoystickPad(label: "Walk") { vector in
                    model.controls.virtualMove = vector
                } onEnded: {
                    model.controls.virtualMove = .zero
                }
                HQJoystickPad(label: "Drag look") { vector in
                    model.controls.padLookChanged(vector)
                } onEnded: {
                    model.controls.padLookEnded()
                }
            }
        }
    }

    /// Pitch comfort: continuous 1:1 drag, or discrete snap tilts.
    private var comfortSection: some View {
        @Bindable var controls = model.controls
        return VStack(spacing: 6) {
            Picker("Pitch", selection: $controls.pitchComfort) {
                ForEach(HQPitchComfort.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Text("How vertical drags tilt the view — snap if smooth tilting ever feels off")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var multiplayerSection: some View {
        VStack(spacing: 10) {
            Divider()
            switch model.multiplayer.state {
            case .idle:
                Label("Start a FaceTime call, then share the plaza", systemImage: "shareplay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waiting:
                Label("Joining session…", systemImage: "shareplay")
            case .joined(let count):
                Label("\(count) at the tower", systemImage: "person.2.fill")
            }

            HStack(spacing: 16) {
                Button {
                    model.multiplayer.startSharing()
                } label: {
                    Label("SharePlay", systemImage: "shareplay")
                }

                Button {
                    model.toggleTestAvatar()
                } label: {
                    Label(
                        model.testAvatarEnabled ? "Remove demo visitor" : "Add demo visitor",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
                .disabled(!model.isImmersed)
            }

            if !model.multiplayer.remotePlayers.isEmpty {
                Text(model.multiplayer.remotePlayers.values.map(\.name).sorted().joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A drag-anywhere pad: deflection is the drag vector from the gesture's
/// start, saturating at the pad radius. The walk pad treats it as a stick
/// (release = stop); the look pad consumes position *changes*, mirroring
/// pinch-drag (release = commit).
struct HQJoystickPad: View {
    let label: String
    let onChange: (SIMD2<Float>) -> Void
    let onEnded: () -> Void

    @State private var knobOffset = CGSize.zero
    private let radius: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: radius * 2, height: radius * 2)
                Circle()
                    .fill(.thinMaterial)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                    .frame(width: 44, height: 44)
                    .offset(knobOffset)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var dx = value.translation.width
                        var dy = value.translation.height
                        let length = (dx * dx + dy * dy).squareRoot()
                        if length > radius {
                            dx *= radius / length
                            dy *= radius / length
                        }
                        knobOffset = CGSize(width: dx, height: dy)
                        // Screen-up is negative height; pads treat up as +.
                        onChange(SIMD2(Float(dx / radius), Float(-dy / radius)))
                    }
                    .onEnded { _ in
                        knobOffset = .zero
                        onEnded()
                    }
            )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
