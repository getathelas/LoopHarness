//
//  CardPillAlert.swift
//  Loop
//
//  Lightweight toast/pill that surfaces when generate_card completes.
//  Shown in the current conversation: "✨ new card" — tapping it navigates
//  to the Feed and scrolls to the new card.
//

#if os(iOS)
import UIKit

final class CardPillAlert {

    /// Show a pill alert for a newly created card. Call from main thread.
    /// The pill auto-dismisses after 4 seconds or on tap.
    static func show(in viewController: UIViewController, cardId: String, onTap: @escaping (String) -> Void) {
        let pill = PillView(cardId: cardId, onTap: onTap)
        pill.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
            pill.topAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            pill.heightAnchor.constraint(equalToConstant: 36),
        ])

        pill.alpha = 0
        pill.transform = CGAffineTransform(translationX: 0, y: -20)

        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            pill.alpha = 1
            pill.transform = .identity
        }

        // Auto-dismiss after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak pill] in
            pill?.dismiss()
        }
    }
}

private final class PillView: UIView {

    private let cardId: String
    private let onTap: (String) -> Void

    init(cardId: String, onTap: @escaping (String) -> Void) {
        self.cardId = cardId
        self.onTap = onTap
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = UIColor(red: 0.15, green: 0.13, blue: 0.22, alpha: 0.95)
        layer.cornerRadius = 18

        let label = UILabel()
        label.text = "\u{2728} new card"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true

        // Shadow
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 8
    }

    @objc private func tapped() {
        onTap(cardId)
        dismiss()
    }

    func dismiss() {
        UIView.animate(withDuration: 0.3, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -20)
        }) { _ in
            self.removeFromSuperview()
        }
    }
}

#endif
