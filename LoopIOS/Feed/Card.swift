//
//  Card.swift
//  Loop
//
//  Data model for Feed cards. Persisted as JSON in workspace://cards/<id>.json.
//  Image assets live at workspace://cards/assets/<id>.png.
//

import Foundation

/// The visual kind of a card — determines which renderer produces the poster.
enum CardKind: String, Codable {
    case image
    case markdown
}

/// Lifecycle state of a card in the user's feed.
enum CardState: String, Codable {
    case new
    case kept
    case archived
}

/// A single feed card produced by the `generate_card` tool.
struct Card: Codable, Identifiable {
    let id: String
    let kind: CardKind
    var title: String
    var body: String
    /// Relative path to the rendered poster image inside workspace (e.g.
    /// "cards/assets/<id>.png"). Nil while the renderer is still working.
    var imageURL: String?
    /// Attribution / provenance string (e.g. "calendar", "user request").
    var source: String?
    /// Freeform tags for filtering/search.
    var tags: [String]
    let createdAt: Date
    var state: CardState

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body
        case imageURL = "image_url"
        case source, tags
        case createdAt = "created_at"
        case state
    }

    init(id: String = UUID().uuidString,
         kind: CardKind,
         title: String,
         body: String,
         imageURL: String? = nil,
         source: String? = nil,
         tags: [String] = [],
         createdAt: Date = Date(),
         state: CardState = .new) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.imageURL = imageURL
        self.source = source
        self.tags = tags
        self.createdAt = createdAt
        self.state = state
    }
}

// MARK: - Platform-agnostic display derivations
//
// The one-line summary and kind badge are pure string transforms, so they live
// on the model and are shared by every platform's card UI (iOS list/detail,
// Mac card list/detail). The icon tile's symbol + tint return a platform color
// type, so those stay in the per-platform Card+Display files.

extension Card {

    /// First meaningful line of the body, stripped of markdown markers, used as
    /// the one-line summary under the title.
    var displaySubtitle: String? {
        for raw in body.split(whereSeparator: \.isNewline) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            // Drop leading heading / list / quote markers.
            while let first = s.first, "#-*•>".contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Drop a leading checkbox.
            if s.hasPrefix("[ ]") || s.hasPrefix("[x]") || s.hasPrefix("[X]") {
                s = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Drop a leading "1." style ordinal.
            if let dot = s.firstIndex(of: "."), dot != s.startIndex,
               s[s.startIndex..<dot].allSatisfy(\.isNumber) {
                s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Short uppercase badge describing the card's shape.
    var displayBadge: String {
        switch kind {
        case .image:
            return "IMAGE"
        case .markdown:
            let lower = body.lowercased()
            if lower.contains("- [ ]") || lower.contains("- [x]") || lower.contains("* [ ]") {
                return "CHECKLIST"
            }
            let bulletLines = body.split(whereSeparator: \.isNewline).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let first = t.first else { return false }
                return first == "-" || first == "*" || first == "•"
            }
            return bulletLines.count >= 2 ? "LIST" : "NOTE"
        }
    }
}
