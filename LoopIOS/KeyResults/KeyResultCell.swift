//
//  KeyResultCell.swift
//  Loop
//
//  Table cell for the Key Results tab in the side drawer. Shows:
//  - KR title
//  - Current week value (e.g. "Week 6 — 11,000")
//  - A compact sparkline-style mini bar chart of weekly values
//

import UIKit

final class KeyResultCell: UITableViewCell {

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let sparklineView = MiniBarChartView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .default

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        valueLabel.font = .systemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.numberOfLines = 1

        sparklineView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(textStack)
        contentView.addSubview(sparklineView)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: sparklineView.leadingAnchor, constant: -12),

            sparklineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            sparklineView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sparklineView.widthAnchor.constraint(equalToConstant: 60),
            sparklineView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func configure(with kr: KeyResult) {
        titleLabel.text = kr.title.isEmpty ? "Untitled KR" : kr.title
        if let latest = kr.latestValue {
            let formatted = Self.formatValue(latest.value)
            valueLabel.text = "Week \(latest.week) — \(formatted)"
        } else {
            valueLabel.text = "No data"
        }
        sparklineView.values = kr.weeklyValues
            .sorted { $0.week < $1.week }
            .map { $0.value }
    }

    private static func formatValue(_ v: Double) -> String {
        if v >= 1_000_000 {
            return String(format: "%.1fM", v / 1_000_000)
        } else if v >= 1_000 {
            return String(format: "%.0fK", v / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        if v == v.rounded() {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }
}

// MARK: - Mini bar chart view

/// A tiny bar chart rendered inline in the cell. Draws one bar per data point
/// with proportional heights. Lightweight — no external chart library needed.
final class MiniBarChartView: UIView {

    var values: [Double] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard !values.isEmpty else { return }
        let maxVal = values.max() ?? 1
        guard maxVal > 0 else { return }

        let barSpacing: CGFloat = 1
        let totalSpacing = barSpacing * CGFloat(values.count - 1)
        let barWidth = max(2, (rect.width - totalSpacing) / CGFloat(values.count))
        let color = UIColor.systemBlue

        for (i, value) in values.enumerated() {
            let barHeight = CGFloat(value / maxVal) * rect.height
            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = rect.height - barHeight
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: 1)
            color.setFill()
            path.fill()
        }
    }
}
