//
//  FeedCardCell.swift
//  Loop
//
//  Collection view cell for a single feed card. Displays the poster image
//  (or a placeholder) with title overlay. Supports swipe gestures for
//  Keep (right) and Archive (left).
//

#if os(iOS)
import UIKit

final class FeedCardCell: UICollectionViewCell {
    static let reuseId = "FeedCardCell"

    enum SwipeAction {
        case keep
        case archive
    }

    var onSwipeAction: ((SwipeAction) -> Void)?

    // MARK: - UI

    private let posterImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        iv.layer.cornerRadius = 16
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 20, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 2
        return l
    }()

    private let stateIndicator: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 4
        v.isHidden = true
        return v
    }()

    private let gradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        g.locations = [0.5, 1.0]
        return g
    }()

    /// Swipe feedback labels
    private let keepLabel: UILabel = {
        let l = UILabel()
        l.text = "KEEP"
        l.font = .systemFont(ofSize: 24, weight: .heavy)
        l.textColor = UIColor.systemGreen
        l.alpha = 0
        return l
    }()

    private let archiveLabel: UILabel = {
        let l = UILabel()
        l.text = "ARCHIVE"
        l.font = .systemFont(ofSize: 24, weight: .heavy)
        l.textColor = UIColor.systemOrange
        l.alpha = 0
        return l
    }()

    /// Swipe threshold
    private let swipeThreshold: CGFloat = 80

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = posterImageView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        posterImageView.image = nil
        titleLabel.text = nil
        stateIndicator.isHidden = true
        keepLabel.alpha = 0
        archiveLabel.alpha = 0
        contentView.transform = .identity
    }

    // MARK: - Setup

    private func setupUI() {
        contentView.layer.cornerRadius = 16
        contentView.clipsToBounds = true

        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterImageView)
        posterImageView.layer.addSublayer(gradientLayer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        stateIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stateIndicator)

        keepLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(keepLabel)

        archiveLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(archiveLabel)

        NSLayoutConstraint.activate([
            posterImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            stateIndicator.widthAnchor.constraint(equalToConstant: 8),
            stateIndicator.heightAnchor.constraint(equalToConstant: 8),
            stateIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stateIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            keepLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            keepLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            archiveLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            archiveLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        contentView.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        contentView.addGestureRecognizer(longPress)
    }

    // MARK: - Configure

    func configure(with card: Card) {
        titleLabel.text = card.title

        // State indicator
        switch card.state {
        case .new:
            stateIndicator.backgroundColor = UIColor.systemBlue
            stateIndicator.isHidden = false
        case .kept:
            stateIndicator.backgroundColor = UIColor.systemGreen
            stateIndicator.isHidden = false
        case .archived:
            stateIndicator.isHidden = true
        }

        // Load poster
        if let posterURL = CardStore.shared.posterURL(for: card) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = try? Data(contentsOf: posterURL),
                      let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    self?.posterImageView.image = image
                }
            }
        } else {
            // Placeholder: dark background with centered title
            posterImageView.image = nil
        }
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .changed:
            contentView.transform = CGAffineTransform(translationX: translation.x, y: 0)
            let progress = min(abs(translation.x) / swipeThreshold, 1.0)
            if translation.x > 0 {
                keepLabel.alpha = progress
                archiveLabel.alpha = 0
            } else {
                archiveLabel.alpha = progress
                keepLabel.alpha = 0
            }
        case .ended, .cancelled:
            if translation.x > swipeThreshold {
                animateOut(direction: .right) { [weak self] in
                    self?.onSwipeAction?(.keep)
                }
            } else if translation.x < -swipeThreshold {
                animateOut(direction: .left) { [weak self] in
                    self?.onSwipeAction?(.archive)
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                    self.contentView.transform = .identity
                    self.keepLabel.alpha = 0
                    self.archiveLabel.alpha = 0
                }
            }
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        // Long-press could open source — handled via delegate in future.
        // For now, provide haptic feedback.
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
    }

    private enum Direction { case left, right }

    private func animateOut(direction: Direction, completion: @escaping () -> Void) {
        let targetX: CGFloat = direction == .right ? bounds.width * 1.5 : -bounds.width * 1.5
        UIView.animate(withDuration: 0.3, animations: {
            self.contentView.transform = CGAffineTransform(translationX: targetX, y: 0)
            self.contentView.alpha = 0
        }) { _ in
            self.contentView.transform = .identity
            self.contentView.alpha = 1
            self.keepLabel.alpha = 0
            self.archiveLabel.alpha = 0
            completion()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FeedCardCell: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        // Only intercept horizontal swipes
        return abs(velocity.x) > abs(velocity.y)
    }
}

#endif
