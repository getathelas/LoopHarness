//
//  VoiceSessionViewController.swift
//  Loop
//
//  The full-screen surface for a live realtime voice session. Presented from
//  the nav-bar microphone button. It owns a `RealtimeVoiceSession`, reflects
//  its state through the shared `AvatarView`, and gives the user mute + end
//  controls.
//

import UIKit
import AVFoundation

final class VoiceSessionViewController: UIViewController {

    private let session: RealtimeVoiceSession
    private let scopeTitle: String?

    private let avatar = AvatarView(gridW: 21, gridH: 21, pixelSize: 12, baseRadius: 6.0)
    private let statusLabel = UILabel()
    private let transcriptLabel = UILabel()
    private let muteButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)

    private var isMuted = false
    private var transcriptBuffer = ""

    init(scope: RealtimeVoiceSession.Scope) {
        self.session = RealtimeVoiceSession(scope: scope)
        if case let .thread(_, title) = scope {
            self.scopeTitle = title
        } else {
            self.scopeTitle = nil
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        session.delegate = self
        requestMicThenStart()
    }

    /// Ask for microphone access up front so the session doesn't start into a
    /// silent, permission-blocked audio route.
    private func requestMicThenStart() {
        let onResult: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.session.start()
                } else {
                    self.session(self.session, didFailWith:
                        "Microphone access is off. Enable it in Settings → Loop → Microphone.")
                }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: onResult)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(onResult)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stop()
    }

    // MARK: - UI

    private func buildUI() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.mode = .idle
        view.addSubview(avatar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = scopeTitle.map { "Connecting · \($0)" } ?? "Connecting…"
        view.addSubview(statusLabel)

        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptLabel.font = .systemFont(ofSize: 15)
        transcriptLabel.textColor = .label
        transcriptLabel.textAlignment = .center
        transcriptLabel.numberOfLines = 4
        view.addSubview(transcriptLabel)

        configureCircleButton(muteButton, systemName: "mic.fill", tint: .label)
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        view.addSubview(muteButton)

        configureCircleButton(endButton, systemName: "xmark", tint: .white)
        endButton.backgroundColor = .systemRed
        endButton.addTarget(self, action: #selector(endTapped), for: .touchUpInside)
        view.addSubview(endButton)

        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -60),
            avatar.widthAnchor.constraint(equalToConstant: 252),
            avatar.heightAnchor.constraint(equalToConstant: 252),

            statusLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            transcriptLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            transcriptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            transcriptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            muteButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -50),
            muteButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            muteButton.widthAnchor.constraint(equalToConstant: 64),
            muteButton.heightAnchor.constraint(equalToConstant: 64),

            endButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 50),
            endButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            endButton.widthAnchor.constraint(equalToConstant: 64),
            endButton.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func configureCircleButton(_ button: UIButton, systemName: String, tint: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        button.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        button.tintColor = tint
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 32
    }

    // MARK: - Actions

    @objc private func toggleMute() {
        isMuted.toggle()
        session.setMuted(isMuted)
        let name = isMuted ? "mic.slash.fill" : "mic.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        muteButton.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        muteButton.tintColor = isMuted ? .systemRed : .label
    }

    @objc private func endTapped() {
        session.stop()
        dismiss(animated: true)
    }

    private func setStatus(_ text: String) {
        statusLabel.text = scopeTitle.map { "\(text) · \($0)" } ?? text
    }
}

// MARK: - RealtimeVoiceSessionDelegate

extension VoiceSessionViewController: RealtimeVoiceSessionDelegate {

    func voiceSession(_ session: RealtimeVoiceSession, didChangeState state: RealtimeVoiceSession.State) {
        switch state {
        case .idle, .connecting:
            avatar.mode = .idle
            setStatus("Connecting…")
        case .listening:
            avatar.mode = .listening
            setStatus("Listening")
        case .thinking:
            avatar.mode = .thinking
            setStatus("Thinking")
        case .speaking:
            avatar.mode = .speaking
            setStatus("Speaking")
        case .ended:
            avatar.mode = .idle
        case .failed(let message):
            avatar.mode = .idle
            setStatus(message)
        }
    }

    func voiceSession(_ session: RealtimeVoiceSession, didFailWith message: String) {
        let alert = UIAlertController(title: "Voice unavailable", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    func voiceSession(_ session: RealtimeVoiceSession, didUpdateInputAmplitude amp: Float) {
        if avatar.mode == .listening { avatar.amplitude = amp }
    }

    func voiceSession(_ session: RealtimeVoiceSession, didUpdateOutputAmplitude amp: Float) {
        if avatar.mode == .speaking { avatar.amplitude = amp }
    }

    func voiceSession(_ session: RealtimeVoiceSession, didReceiveTranscript text: String) {
        transcriptBuffer += text
        // Keep the tail so the label doesn't overflow.
        if transcriptBuffer.count > 240 {
            transcriptBuffer = String(transcriptBuffer.suffix(240))
        }
        transcriptLabel.text = transcriptBuffer
    }
}
