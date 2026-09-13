import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
            Text("AI voice · Continues in the background")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(22).frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.13), radius: 24, y: 12)
    }
}

/// The live identity occupies the existing navigation avatar slot.
struct LiveCompactOrb: View {
    @ObservedObject var session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !session.isActive)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let level = Double(max(session.inputLevel, session.outputLevel))
            Circle()
                .fill(RadialGradient(colors: [.white, .cyan, .blue, .indigo],
                    center: UnitPoint(x: 0.32 + sin(phase) * 0.06, y: 0.28), startRadius: 0, endRadius: 34))
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.7))
                .frame(width: 31, height: 31)
                .scaleEffect(reduceMotion ? 1 : 1 + level * 0.18 + sin(phase * 2) * 0.025)
                .shadow(color: .blue.opacity(session.isActive ? 0.6 : 0.15), radius: 5 + level * 4)
                .opacity(session.isActive ? 1 : 0.45)
                .frame(width: 44, height: 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.isActive ? "Live voice active" : "Live voice ended")
    }
}

/// Small, persistent call controls leave the conversation unobstructed.
struct LiveCallControls: View {
    @ObservedObject var session: LiveSession
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(session.isActive ? Color.cyan : .secondary).frame(width: 5, height: 5)
                    Text("Live").font(.subheadline.weight(.semibold))
                }
                Text(session.muted && session.state == .connected ? "Microphone muted" : session.status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.state == .failed || session.state == .idle {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
                }.accessibilityLabel("Retry live chat")
            } else {
                Button { session.toggleMute() } label: {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 40, height: 40)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .disabled(session.state != .connected)
                .accessibilityLabel(session.muted ? "Unmute microphone" : "Mute microphone")
            }
            Button(action: onClose) {
                Image(systemName: "phone.down.fill").foregroundStyle(.white)
                    .frame(width: 44, height: 40).background(.red, in: Capsule())
            }.accessibilityLabel("End live chat")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.vertical, 8)
    }
}

/// A quiet active-call outline grows brighter with actual speaker output.
/// The host disables hit testing so it never blocks system or chat gestures.
struct LiveSpeakingBorder: View {
    @ObservedObject var session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !session.isActive)) { context in
            let level = Double(session.outputLevel)
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let strength = session.isActive ? 0.22 + level * 0.65 : 0
            RoundedRectangle(cornerRadius: 48)
                .strokeBorder(AngularGradient(colors: [.blue, .cyan, .blue.opacity(0.45), .blue],
                    center: .center, angle: .degrees(reduceMotion ? 0 : phase * 24)), lineWidth: reduceMotion ? 3 : 2 + level * 3)
                .opacity(strength)
                .shadow(color: .blue.opacity(strength), radius: 5 + level * 9)
                .padding(2)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct LiveReasoningCard: View {
    let activity: LiveActivityRecord
    let model: String
    let expanded: Bool
    let toggle: () -> Void
    var expandedTools: Set<String> = []
    var toggleTool: (String) -> Void = { _ in }

    private var displayModel: String { model.components(separatedBy: " via ").first ?? model }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning & tools · " + displayModel).font(.caption.weight(.semibold))
                        Text(activity.state == "complete" ? (activity.tools.isEmpty ? "Reviewed your request" : "Used \(activity.tools.count) \(activity.tools.count == 1 ? "tool" : "tools")") : activity.state.capitalized)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "Hide reasoning and tool details" : "Show reasoning and tool details")
            let images = activity.tools.flatMap { $0.images ?? [] }
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(images) { image in LiveImageTile(result: image) }
                    }
                }.scrollIndicators(.hidden)
            }
            if !expanded && !activity.summary.isEmpty {
                Text(activity.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if expanded {
                ForEach(activity.tools) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: tool.state == "running" ? "ellipsis.circle" : tool.state == "completed" ? "checkmark.circle" : tool.state == "returned" ? "arrow.turn.down.right" : "exclamationmark.circle")
                                .foregroundStyle(tool.state == "completed" ? Color.green : .orange)
                            Text(tool.name.replacingOccurrences(of: "_", with: " ")).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(tool.state.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if let end = tool.finishedAt {
                            Text(String(format: "%.1fs", end.timeIntervalSince(tool.startedAt))).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack {
                            Image(systemName: expandedTools.contains(tool.id) ? "chevron.down" : "chevron.right")
                            Text("Inputs & result")
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary)
                        if expandedTools.contains(tool.id) {
                        Text("Inputs").font(.caption.weight(.semibold))
                        Text(tool.input).font(.caption.monospaced()).textSelection(.enabled)
                        if !tool.output.isEmpty {
                            Text("Result").font(.caption.weight(.semibold))
                            Text(tool.output).font(.caption).textSelection(.enabled)
                        }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { toggleTool(tool.id) }
                        .accessibilityAction(named: expandedTools.contains(tool.id) ? "Close tool details" : "Open tool details") { toggleTool(tool.id) }
                }
                if !activity.summary.isEmpty {
                    Text(activity.summary).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.orange.opacity(0.18), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .transaction { $0.animation = nil }
    }
}

struct LiveImageTile: View {
    let result: LiveImageResult
    @State private var enlarged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.state == "generating" {
                VStack(spacing: 10) { ProgressView(); Text("Creating image…").font(.caption) }
                    .frame(width: 210, height: 150).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            } else if result.state == "failed" {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text(result.failureReason ?? "Image generation failed").font(.caption).lineLimit(4)
                }.frame(width: 210, height: 150)
            } else if let url = result.thumbnailURL ?? result.url {
                Button { enlarged = true } label: {
                    LiveImageAsset(url: url).frame(width: 210, height: 150)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("Open image: " + result.title)
            }
            Text(result.title).font(.caption).lineLimit(2).frame(width: 210, alignment: .leading)
            if let source = result.sourceURL, let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") {
                Link(url.host ?? "View source", destination: url).font(.caption2)
            }
        }
        .sheet(isPresented: $enlarged) {
            VStack(spacing: 16) {
                HStack {
                    Text(result.title).font(.headline).lineLimit(3)
                    Spacer()
                    Button("Done") { enlarged = false }
                }
                if let url = result.url { LiveImageAsset(url: url).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding()
        }
    }
}

private struct LiveImageAsset: View {
    let url: String
    @State private var image: Image?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { image.resizable().scaledToFit() }
            else if failed { Label("Image unavailable", systemImage: "photo").font(.caption) }
            else { ProgressView() }
        }
        .task(id: url) {
            image = nil; failed = false
            guard let resource = URL(string: url), resource.isFileURL || ["http", "https"].contains(resource.scheme ?? "") else { failed = true; return }
            do {
                let data: Data
                if resource.isFileURL { data = try await Task.detached { try Data(contentsOf: resource) }.value }
                else {
                    let response: URLResponse
                    (data, response) = try await URLSession.shared.data(from: resource)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { failed = true; return }
                }
                guard !Task.isCancelled else { return }
                #if canImport(UIKit)
                guard let bitmap = UIImage(data: data) else { failed = true; return }
                image = Image(uiImage: bitmap)
                #else
                guard let bitmap = NSImage(data: data) else { failed = true; return }
                image = Image(nsImage: bitmap)
                #endif
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
