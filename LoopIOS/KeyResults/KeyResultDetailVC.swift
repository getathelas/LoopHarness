//
//  KeyResultDetailVC.swift
//  Loop
//
//  Full-screen detail/edit view for a single Key Result. Doubles as the
//  "New KR" form when `isNew` is true. Layout:
//
//  - Title (editable)
//  - Header: "Week N — value"
//  - Bar chart (one bar per week, current week highlighted)
//  - Metric name field
//  - Data source config (API URL, bearer token, Fetch button)
//  - Manual weekly entry section
//

import UIKit

final class KeyResultDetailVC: UIViewController {

    // MARK: - State

    private var kr: KeyResult
    private let isNew: Bool
    var onSave: (() -> Void)?

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let titleField = UITextField()
    private let headerLabel = UILabel()
    private let chartContainer = UIView()
    private let metricNameField = UITextField()

    // Data source section
    private let dataSourceHeader = UILabel()
    private let apiURLField = UITextField()
    private let bearerTokenField = UITextField()
    private let specLabel = UILabel()
    private let fetchButton = UIButton(type: .system)
    private let fetchStatusLabel = UILabel()

    // Manual entry section
    private let manualHeader = UILabel()
    private let weekField = UITextField()
    private let valueField = UITextField()
    private let addValueButton = UIButton(type: .system)

    // Bar chart
    private var barChartView: BarChartView!

    // MARK: - Init

    init(keyResult: KeyResult, isNew: Bool = false) {
        self.kr = keyResult
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = isNew ? "New Key Result" : "Key Result"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        setupLayout()
        populateFields()
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        // Title
        configureSectionField(titleField, placeholder: "KR Title (e.g. EOB Backlog to Zero)")
        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        contentStack.addArrangedSubview(titleField)

        // Header label
        headerLabel.font = .systemFont(ofSize: 15, weight: .medium)
        headerLabel.textColor = .secondaryLabel
        contentStack.addArrangedSubview(headerLabel)

        // Bar chart
        barChartView = BarChartView()
        barChartView.translatesAutoresizingMaskIntoConstraints = false
        barChartView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        contentStack.addArrangedSubview(barChartView)

        // Metric name
        configureSectionField(metricNameField, placeholder: "Metric name (e.g. Outstanding EOBs)")
        contentStack.addArrangedSubview(metricNameField)

        // Separator
        contentStack.addArrangedSubview(makeSeparator())

        // Data source config
        dataSourceHeader.text = "Data Source"
        dataSourceHeader.font = .systemFont(ofSize: 17, weight: .semibold)
        contentStack.addArrangedSubview(dataSourceHeader)

        configureSectionField(apiURLField, placeholder: "API Endpoint URL")
        apiURLField.keyboardType = .URL
        apiURLField.autocapitalizationType = .none
        apiURLField.autocorrectionType = .no
        contentStack.addArrangedSubview(apiURLField)

        bearerTokenField.isSecureTextEntry = true
        configureSectionField(bearerTokenField, placeholder: "Bearer Token")
        bearerTokenField.autocapitalizationType = .none
        bearerTokenField.autocorrectionType = .no
        contentStack.addArrangedSubview(bearerTokenField)

        specLabel.text = "Expected response: [{\"week\": <int>, \"value\": <number>}, ...] covering the quarter to date."
        specLabel.font = .systemFont(ofSize: 12)
        specLabel.textColor = .tertiaryLabel
        specLabel.numberOfLines = 0
        contentStack.addArrangedSubview(specLabel)

        fetchButton.setTitle("Fetch Now", for: .normal)
        fetchButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        fetchButton.addTarget(self, action: #selector(fetchTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(fetchButton)

        fetchStatusLabel.font = .systemFont(ofSize: 12)
        fetchStatusLabel.textColor = .secondaryLabel
        fetchStatusLabel.numberOfLines = 0
        fetchStatusLabel.isHidden = true
        contentStack.addArrangedSubview(fetchStatusLabel)

        // Separator
        contentStack.addArrangedSubview(makeSeparator())

        // Manual entry
        manualHeader.text = "Manual Entry"
        manualHeader.font = .systemFont(ofSize: 17, weight: .semibold)
        contentStack.addArrangedSubview(manualHeader)

        let entryRow = UIStackView()
        entryRow.axis = .horizontal
        entryRow.spacing = 8
        entryRow.distribution = .fillEqually

        configureSectionField(weekField, placeholder: "Week #")
        weekField.keyboardType = .numberPad
        configureSectionField(valueField, placeholder: "Value")
        valueField.keyboardType = .decimalPad

        entryRow.addArrangedSubview(weekField)
        entryRow.addArrangedSubview(valueField)
        contentStack.addArrangedSubview(entryRow)

        addValueButton.setTitle("Add / Update Week Value", for: .normal)
        addValueButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        addValueButton.addTarget(self, action: #selector(addValueTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(addValueButton)
    }

    private func configureSectionField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 15)
        field.backgroundColor = .secondarySystemBackground
    }

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.backgroundColor = .separator
        return v
    }

    // MARK: - Populate

    private func populateFields() {
        titleField.text = kr.title
        metricNameField.text = kr.metricName
        apiURLField.text = kr.apiURL ?? ""
        // Show masked indicator if token exists in Keychain
        if KeyResultKeychainHelper.token(for: kr.id) != nil {
            bearerTokenField.placeholder = "••••••••  (tap to replace)"
        }
        refreshChart()
    }

    private func refreshChart() {
        let sorted = kr.weeklyValues.sorted { $0.week < $1.week }
        if let latest = sorted.last {
            let formatted = formatValue(latest.value)
            headerLabel.text = "Week \(latest.week) — \(formatted)"
        } else {
            headerLabel.text = "No data yet"
        }
        barChartView.configure(values: sorted, currentWeek: KeyResult.currentQuarterWeek)
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%,.0f", v) }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        kr.title = titleField.text ?? ""
        kr.metricName = metricNameField.text ?? ""
        kr.apiURL = apiURLField.text?.isEmpty == true ? nil : apiURLField.text
        if let token = bearerTokenField.text, !token.isEmpty {
            kr.bearerToken = token
        }
        KeyResultStore.shared.save(kr)
        onSave?()
        dismiss(animated: true)
    }

    @objc private func fetchTapped() {
        // Save current field values first
        kr.apiURL = apiURLField.text
        if let token = bearerTokenField.text, !token.isEmpty {
            KeyResultKeychainHelper.save(token: token, for: kr.id)
        }
        fetchButton.isEnabled = false
        fetchStatusLabel.text = "Fetching…"
        fetchStatusLabel.textColor = .secondaryLabel
        fetchStatusLabel.isHidden = false

        Task { @MainActor in
            do {
                let values = try await KeyResultFetcher.fetch(for: kr)
                kr.weeklyValues = values
                refreshChart()
                fetchStatusLabel.text = "Success — \(values.count) week(s) loaded."
                fetchStatusLabel.textColor = .systemGreen
            } catch {
                fetchStatusLabel.text = "Error: \(error.localizedDescription)"
                fetchStatusLabel.textColor = .systemRed
            }
            fetchButton.isEnabled = true
        }
    }

    @objc private func addValueTapped() {
        guard let weekText = weekField.text, let week = Int(weekText),
              let valueText = valueField.text, let value = Double(valueText) else { return }
        if let idx = kr.weeklyValues.firstIndex(where: { $0.week == week }) {
            kr.weeklyValues[idx] = KeyResultWeekValue(week: week, value: value)
        } else {
            kr.weeklyValues.append(KeyResultWeekValue(week: week, value: value))
        }
        weekField.text = ""
        valueField.text = ""
        refreshChart()
    }
}

// MARK: - Bar chart view (full-width, one bar per week)

/// A UIKit bar chart for the KR detail view. Draws labeled bars with the
/// current week visually distinguished.
private final class BarChartView: UIView {

    private var values: [KeyResultWeekValue] = []
    private var currentWeek: Int = 0

    func configure(values: [KeyResultWeekValue], currentWeek: Int) {
        self.values = values
        self.currentWeek = currentWeek
        setNeedsDisplay()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard !values.isEmpty else {
            drawEmptyState(in: rect)
            return
        }
        let maxVal = values.map(\.value).max() ?? 1
        guard maxVal > 0 else { return }

        let labelHeight: CGFloat = 18
        let chartHeight = rect.height - labelHeight - 4
        let barSpacing: CGFloat = 4
        let totalSpacing = barSpacing * CGFloat(values.count - 1)
        let barWidth = max(8, (rect.width - totalSpacing) / CGFloat(values.count))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        for (i, entry) in values.enumerated() {
            let isCurrent = entry.week == currentWeek
            let barHeight = CGFloat(entry.value / maxVal) * chartHeight
            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = chartHeight - barHeight
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            let color: UIColor = isCurrent ? .systemOrange : .systemBlue
            color.setFill()
            let path = UIBezierPath(roundedRect: barRect,
                                    byRoundingCorners: [.topLeft, .topRight],
                                    cornerRadii: CGSize(width: 3, height: 3))
            path.fill()

            if isCurrent {
                UIColor.systemOrange.withAlphaComponent(0.3).setStroke()
                let outline = UIBezierPath(roundedRect: barRect.insetBy(dx: -1, dy: -1),
                                           byRoundingCorners: [.topLeft, .topRight],
                                           cornerRadii: CGSize(width: 4, height: 4))
                outline.lineWidth = 2
                outline.stroke()
            }

            // Value label above bar
            let valStr = shortFormat(entry.value)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle,
            ]
            let labelRect = CGRect(x: x, y: chartHeight + 2, width: barWidth, height: labelHeight)
            (valStr as NSString).draw(in: labelRect, withAttributes: attrs)
        }
    }

    private func drawEmptyState(in rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        let str = "No weekly data — add values below or fetch from API"
        let size = (str as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
        (str as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func shortFormat(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}
