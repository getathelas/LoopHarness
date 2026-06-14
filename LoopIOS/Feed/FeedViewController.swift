//
//  FeedViewController.swift
//  Loop
//
//  The Feed tab: vertically-scrollable stack of cards below a pinned orb.
//  New cards appear at the top. Swipe right to Keep, swipe left to Archive.
//  Long-press opens source. Tapping a card expands it to a detail view.
//

#if os(iOS)
import UIKit

final class FeedViewController: UIViewController {

    // MARK: - UI

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 20, bottom: 100, right: 20)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        return cv
    }()

    private let emptyLabel: UILabel = {
        let l = UILabel()
        l.text = "Tap the orb or type to start a conversation"
        l.textColor = .secondaryLabel
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()

    // MARK: - Data

    private var cards: [Card] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        setupCollectionView()
        setupEmptyLabel()
        loadCards()

        NotificationCenter.default.addObserver(self, selector: #selector(cardAdded(_:)),
                                               name: CardStore.cardAddedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cardUpdated(_:)),
                                               name: CardStore.cardUpdatedNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadCards()
    }

    // MARK: - Setup

    private func setupCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        collectionView.register(FeedCardCell.self, forCellWithReuseIdentifier: FeedCardCell.reuseId)
        collectionView.dataSource = self
        collectionView.delegate = self
    }

    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 40),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
    }

    // MARK: - Data

    private func loadCards() {
        cards = CardStore.shared.feedCards
        collectionView.reloadData()
        emptyLabel.isHidden = !cards.isEmpty
    }

    /// Scroll to a specific card by id (used by pill-tap navigation).
    func scrollToCard(id: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let indexPath = IndexPath(item: idx, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
    }

    // MARK: - Notifications

    @objc private func cardAdded(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.loadCards()
            // Scroll to top to show new card
            if let self = self, !self.cards.isEmpty {
                self.collectionView.scrollToItem(at: IndexPath(item: 0, section: 0),
                                                 at: .top, animated: true)
            }
        }
    }

    @objc private func cardUpdated(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.loadCards()
        }
    }
}

// MARK: - UICollectionView DataSource & Delegate

extension FeedViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return cards.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedCardCell.reuseId, for: indexPath) as! FeedCardCell
        let card = cards[indexPath.item]
        cell.configure(with: card)
        cell.onSwipeAction = { [weak self] action in
            self?.handleSwipeAction(action, for: card, at: indexPath)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width - 40 // account for section insets
        // 4:3 aspect ratio
        let height = width * 3 / 4
        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let card = cards[indexPath.item]
        let detail = CardDetailViewController(card: card)
        navigationController?.pushViewController(detail, animated: true)
    }

    // MARK: - Swipe Actions

    private func handleSwipeAction(_ action: FeedCardCell.SwipeAction, for card: Card, at indexPath: IndexPath) {
        switch action {
        case .keep:
            CardStore.shared.updateState(id: card.id, state: .kept)
            loadCards()
        case .archive:
            CardStore.shared.updateState(id: card.id, state: .archived)
            // Animate removal
            cards.remove(at: indexPath.item)
            collectionView.deleteItems(at: [indexPath])
            emptyLabel.isHidden = !cards.isEmpty
        }
    }
}

#endif
