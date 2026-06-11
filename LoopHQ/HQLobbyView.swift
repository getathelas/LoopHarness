import GroupActivities
import SwiftUI

/// The launcher window: enter the park, start SharePlay, and (mainly for the
/// simulator, where hand tracking doesn't exist) a pair of on-screen
/// joysticks that mirror the pinch-drag controls. The window stays visible
/// inside the immersive space.
struct HQLobbyView: View {
    @Environment(HQAppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var tilesKeyDraft =
        UserDefaults.standard.string(forKey: "hq.googleTilesKey") ?? ""

    var body: some View {
        @Bindable var multiplayer = model.multiplayer

        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Loop HQ")
                    .font(.extraLargeTitle2)
                Text("Salesforce Park · San Francisco")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if !model.isImmersed {
                VStack(spacing: 14) {
                    TextField("Your name", text: $multiplayer.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    if model.googleTilesKey == nil {
                        VStack(spacing: 6) {
                            Text("No Google Maps Tiles API key — you'll get flat satellite imagery instead of photorealistic 3D.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            TextField("Google Maps Tiles API key (optional)", text: $tilesKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .frame(maxWidth: 360)
                                .onSubmit {
                                    UserDefaults.standard.set(tilesKeyDraft, forKey: "hq.googleTilesKey")
                                }
                        }
                    }

                    Button {
                        Task { await openImmersiveSpace(id: HQAppModel.immersiveSpaceID) }
                    } label: {
                        Label("Enter the Park", systemImage: "figure.walk")
                            .font(.title3)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                statusSection
                controlsSection
                Button("Leave the Park", role: .destructive) {
                    Task { await dismissImmersiveSpace() }
                }
            }

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
                Label("Building Salesforce Park…", systemImage: "globe.americas")
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
                Text("Pinch + drag: left hand walks, right hand looks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hand tracking unavailable — use the pads below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 60) {
                HQJoystickPad(label: "Walk") { vector in
                    model.controls.virtualIntent.move = vector
                }
                HQJoystickPad(label: "Look") { vector in
                    model.controls.virtualIntent.look = vector
                }
            }
        }
    }

    private var multiplayerSection: some View {
        VStack(spacing: 10) {
            Divider()
            switch model.multiplayer.state {
            case .idle:
                Label("Start a FaceTime call, then share the park", systemImage: "shareplay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waiting:
                Label("Joining session…", systemImage: "shareplay")
            case .joined(let count):
                Label("\(count) in the park", systemImage: "person.2.fill")
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

/// A drag-anywhere joystick pad: deflection is the drag vector from the
/// gesture's start, saturating at the pad radius. Mirrors the hand-stick
/// mapping (up = forward / look up).
struct HQJoystickPad: View {
    let label: String
    let onChange: (SIMD2<Float>) -> Void

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
                        // Screen-up is negative height; sticks treat up as +.
                        onChange(SIMD2(Float(dx / radius), Float(-dy / radius)))
                    }
                    .onEnded { _ in
                        knobOffset = .zero
                        onChange(.zero)
                    }
            )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
