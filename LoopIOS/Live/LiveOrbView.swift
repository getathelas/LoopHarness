import SwiftUI

struct LiveOrbView: View {
    @ObservedObject var session: LiveSession
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func caption(_ role: String) -> String {
        String(session.fragments.filter { $0.role == role }.map(\.delta).joined().suffix(220))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Live", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("GPT Live 1").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !session.isActive)) { context in
                let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let level = Double(max(session.inputLevel, session.outputLevel))
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.16)).blur(radius: 14)
                        .scaleEffect(1.05 + level * 0.12)
                    Circle().fill(RadialGradient(colors: [.white, .cyan, .blue, .indigo],
                        center: UnitPoint(x: 0.35 + sin(phase * 0.8) * 0.1, y: 0.3), startRadius: 2, endRadius: 100))
                    Ellipse().fill(.white.opacity(0.28)).blur(radius: 9)
                        .frame(width: 65, height: 28).rotationEffect(.degrees(phase * 18))
                        .offset(y: -22)
                }
                .frame(width: 110, height: 110)
                .scaleEffect(reduceMotion ? 1 : 1 + sin(phase * 2) * 0.025 + level * 0.12)
                .shadow(color: .blue.opacity(0.22), radius: 22, y: 10)
                .accessibilityHidden(true)
            }.frame(height: 132)
            Text(session.muted && session.state == .connected ? "Microphone muted" : session.status)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(session.thinking ? "LoopHarness is working" : session.status)
            VStack(alignment: .leading, spacing: 8) {
                if !caption("user").isEmpty {
                    Text("You · " + caption("user")).foregroundStyle(.secondary)
                }
                if !caption("assistant").isEmpty { Text(caption("assistant")) }
            }
            .font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                if session.state == .failed || session.state == .idle {
                    Button("Try again", systemImage: "arrow.clockwise") { session.start() }
                        .buttonStyle(.bordered)
                } else {
                    Button(action: { session.toggleMute() }) {
                        Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered).clipShape(Circle())
                    .disabled(session.state != .connected)
                    .accessibilityLabel(session.muted ? "Unmute microphone" : "Mute microphone")
                }
                Button(action: { session.stop(); onClose() }) {
                    Image(systemName: "phone.down.fill").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent).tint(.red).clipShape(Circle())
                .accessibilityLabel("End live chat")
            }
            Text("AI voice · You can interrupt at any time")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(22).frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.13), radius: 24, y: 12)
    }
}
