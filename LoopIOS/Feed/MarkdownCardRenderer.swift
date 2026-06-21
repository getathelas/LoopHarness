//
//  MarkdownCardRenderer.swift
//  Loop
//
//  v1 markdown renderer: renders title + body markdown to a 4:3 poster-style
//  PNG via UIKit offscreen render. Clean typography, Loop-branded dark
//  background with white text.
//

#if os(iOS)
import UIKit

final class MarkdownCardRenderer: CardRendering {
    let kind: CardKind = .markdown

    /// Poster dimensions — 4:3 landscape at 2x for retina.
    private let posterWidth: CGFloat = 1200
    private let posterHeight: CGFloat = 900

    func render(card: Card, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            let image = renderPoster(title: card.title, body: card.body)
            guard let pngData = image.pngData() else {
                completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("Failed to encode PNG")))
                return
            }

            let relativePath = CardStore.shared.posterRelativePath(for: card.id)
            let url = Workspace.shared.rootURL.appendingPathComponent(relativePath)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try pngData.write(to: url, options: .atomic)
                    CardStore.shared.updateImageURL(id: card.id, imageURL: relativePath)
                    completion(.success(url))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Render a poster-style card with title + body using UIKit drawing.
    /// Tables in the body are rendered as styled grids instead of raw pipes.
    private func renderPoster(title: String, body: String) -> UIImage {
        let size = CGSize(width: posterWidth, height: posterHeight)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            // Dark gradient background (Loop-branded)
            let bgColors = [
                UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 0.12, green: 0.10, blue: 0.18, alpha: 1.0).cgColor,
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: bgColors as CFArray,
                                      locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient,
                                            start: .zero,
                                            end: CGPoint(x: 0, y: size.height),
                                            options: [])

            // Subtle accent bar at top
            let accentColor = UIColor(red: 0.55, green: 0.36, blue: 1.0, alpha: 0.8)
            accentColor.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: 4)).fill()

            let margin: CGFloat = 60
            let textWidth = size.width - margin * 2

            // Title
            let titleFont = UIFont.systemFont(ofSize: 48, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.white,
            ]
            let titleRect = CGRect(x: margin, y: margin + 20, width: textWidth, height: 120)
            let titleStr = NSString(string: title)
            titleStr.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs, context: nil)

            // Body — segment-aware: tables get a grid, prose gets text.
            let bodyFont = UIFont.systemFont(ofSize: 28, weight: .regular)
            let bodyTextColor = UIColor(white: 0.85, alpha: 1.0)
            var cursor: CGFloat = margin + 160
            let bodyBottom = size.height - margin

            let segments = MarkdownSegmenter.segments(from: body)
            for segment in segments {
                guard cursor < bodyBottom else { break }
                switch segment {
                case .text(let prose):
                    let availHeight = bodyBottom - cursor
                    let rect = CGRect(x: margin, y: cursor, width: textWidth, height: availHeight)
                    let str = CardMarkdown.attributed(prose,
                                                      bodyFont: bodyFont,
                                                      textColor: bodyTextColor,
                                                      headingColor: .white)
                    str.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                    let used = str.boundingRect(with: CGSize(width: textWidth, height: availHeight),
                                               options: [.usesLineFragmentOrigin],
                                               context: nil)
                    cursor += min(ceil(used.height) + bodyFont.pointSize * 0.6, availHeight)

                case .table(let table):
                    let drawn = drawPosterTable(table, at: CGPoint(x: margin, y: cursor),
                                                maxWidth: textWidth, maxY: bodyBottom,
                                                ctx: ctx.cgContext)
                    cursor += drawn + 16

                case .codeBlock(let block):
                    let codeFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .regular)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: UIColor(white: 0.82, alpha: 1),
                    ]
                    let availHeight = bodyBottom - cursor
                    // Tinted background behind the code
                    let codeStr = NSAttributedString(string: block.code, attributes: attrs)
                    let codeRect = codeStr.boundingRect(
                        with: CGSize(width: textWidth - 24, height: availHeight),
                        options: [.usesLineFragmentOrigin], context: nil)
                    let bgRect = CGRect(x: margin, y: cursor,
                                        width: textWidth,
                                        height: min(ceil(codeRect.height) + 20, availHeight))
                    UIColor(white: 1, alpha: 0.06).setFill()
                    UIBezierPath(roundedRect: bgRect, cornerRadius: 10).fill()
                    codeStr.draw(with: CGRect(x: margin + 12, y: cursor + 10,
                                             width: textWidth - 24,
                                             height: bgRect.height - 20),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                context: nil)
                    cursor += bgRect.height + 12
                }
            }

            // Loop watermark bottom-right
            let wmFont = UIFont.systemFont(ofSize: 18, weight: .medium)
            let wmAttrs: [NSAttributedString.Key: Any] = [
                .font: wmFont,
                .foregroundColor: UIColor(white: 0.4, alpha: 1.0),
            ]
            let wm = NSString(string: "Loop")
            let wmSize = wm.size(withAttributes: wmAttrs)
            wm.draw(at: CGPoint(x: size.width - margin - wmSize.width,
                                y: size.height - margin + 10),
                    withAttributes: wmAttrs)
        }
    }

    // MARK: - Poster table drawing

    /// Draw a styled table grid at `origin` and return the total height used.
    private func drawPosterTable(_ table: MarkdownTable,
                                 at origin: CGPoint,
                                 maxWidth: CGFloat,
                                 maxY: CGFloat,
                                 ctx: CGContext) -> CGFloat {
        let cellPadH: CGFloat = 14
        let cellPadV: CGFloat = 10
        let cellFont = UIFont.systemFont(ofSize: 22, weight: .regular)
        let headerFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let textColor = UIColor(white: 0.85, alpha: 1)
        let headerTextColor = UIColor.white
        let gridColor = UIColor(white: 1, alpha: 0.12)
        let headerBg = UIColor(white: 1, alpha: 0.10)
        let altRowBg = UIColor(white: 1, alpha: 0.04)
        let cornerRadius: CGFloat = 10

        // Measure column widths (proportional to content, capped to maxWidth)
        let minCol: CGFloat = 60
        var columnWidths = Array(repeating: minCol, count: table.columnCount)
        let allRows = [table.headers] + table.rows
        for (rowIdx, row) in allRows.enumerated() {
            for (col, cell) in row.enumerated() where col < table.columnCount {
                let font = (rowIdx == 0) ? headerFont : cellFont
                let w = (cell as NSString).size(withAttributes: [.font: font]).width
                columnWidths[col] = max(columnWidths[col], ceil(w) + cellPadH * 2)
            }
        }
        // Scale columns proportionally if they exceed maxWidth
        let rawTotal = columnWidths.reduce(0, +)
        if rawTotal > maxWidth {
            let scale = maxWidth / rawTotal
            columnWidths = columnWidths.map { $0 * scale }
        }
        let tableWidth = columnWidths.reduce(0, +)

        // Measure row heights
        var rowHeights: [CGFloat] = []
        for (rowIdx, row) in allRows.enumerated() {
            var maxH: CGFloat = 0
            for (col, cell) in row.enumerated() where col < table.columnCount {
                let font = (rowIdx == 0) ? headerFont : cellFont
                let w = columnWidths[col] - cellPadH * 2
                let rect = (cell as NSString).boundingRect(
                    with: CGSize(width: w, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil)
                maxH = max(maxH, ceil(rect.height) + cellPadV * 2)
            }
            rowHeights.append(maxH)
        }
        let totalHeight = rowHeights.reduce(0, +)

        // Clip to available space
        let clampedHeight = min(totalHeight, maxY - origin.y)
        guard clampedHeight > 0 else { return 0 }

        // Background with rounded corners
        let tableRect = CGRect(x: origin.x, y: origin.y, width: tableWidth, height: clampedHeight)
        let bgPath = UIBezierPath(roundedRect: tableRect, cornerRadius: cornerRadius)
        UIColor(white: 1, alpha: 0.06).setFill()
        bgPath.fill()

        // Draw rows
        var y = origin.y
        for (rowIdx, row) in allRows.enumerated() {
            guard y < origin.y + clampedHeight else { break }
            let rowH = rowHeights[rowIdx]

            // Row background
            if rowIdx == 0 {
                ctx.saveGState()
                bgPath.addClip()
                headerBg.setFill()
                UIBezierPath(rect: CGRect(x: origin.x, y: y, width: tableWidth, height: rowH)).fill()
                ctx.restoreGState()
            } else if !rowIdx.isMultiple(of: 2) {
                ctx.saveGState()
                bgPath.addClip()
                altRowBg.setFill()
                UIBezierPath(rect: CGRect(x: origin.x, y: y, width: tableWidth, height: rowH)).fill()
                ctx.restoreGState()
            }

            // Horizontal divider (skip first row)
            if rowIdx > 0 {
                gridColor.setStroke()
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: origin.x + cornerRadius, y: y))
                ctx.addLine(to: CGPoint(x: origin.x + tableWidth - cornerRadius, y: y))
                ctx.strokePath()
            }

            // Draw cells
            var x = origin.x
            for (col, cellText) in row.enumerated() where col < table.columnCount {
                let colW = columnWidths[col]
                let font = (rowIdx == 0) ? headerFont : cellFont
                let color = (rowIdx == 0) ? headerTextColor : textColor

                // Column divider
                if col > 0 {
                    gridColor.setStroke()
                    ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: x, y: y + 4))
                    ctx.addLine(to: CGPoint(x: x, y: y + rowH - 4))
                    ctx.strokePath()
                }

                let alignment = col < table.alignments.count ? table.alignments[col] : .left
                let paragraph = NSMutableParagraphStyle()
                switch alignment {
                case .left:   paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right:  paragraph.alignment = .right
                }
                paragraph.lineBreakMode = .byTruncatingTail

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                ]
                let cellRect = CGRect(x: x + cellPadH, y: y + cellPadV,
                                      width: colW - cellPadH * 2,
                                      height: rowH - cellPadV * 2)
                (cellText as NSString).draw(with: cellRect,
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: attrs, context: nil)
                x += colW
            }
            y += rowH
        }

        // Border around the whole table
        gridColor.setStroke()
        ctx.setLineWidth(1)
        bgPath.stroke()

        return min(totalHeight, clampedHeight)
    }
}

#endif
