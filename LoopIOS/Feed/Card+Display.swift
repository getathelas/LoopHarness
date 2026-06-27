//
//  Card+Display.swift
//  Loop
//
//  UIKit-facing derivation for a Card: the icon tile's symbol + tint. The
//  one-line summary and kind badge are platform-agnostic and live on the model
//  in Card.swift; only the color-typed icon stays here. AppKit has its own
//  mirror in LoopMac/Card+DisplayMac.swift.
//

#if os(iOS)
import UIKit

extension Card {

    /// SF Symbol + tint for the icon tile, inferred from the title and tags.
    var displayIcon: (symbol: String, tint: UIColor) {
        let haystack = (title + " " + tags.joined(separator: " ")).lowercased()
        let rules: [(keys: [String], symbol: String, tint: UIColor)] = [
            (["dinner", "food", "meal", "recipe", "cook", "prep", "kitchen"], "fork.knife", UIColor(red: 0.70, green: 0.45, blue: 0.28, alpha: 1)),
            (["music", "playlist", "song", "track"], "music.note", UIColor(red: 0.78, green: 0.60, blue: 0.30, alpha: 1)),
            (["wine", "drink", "cocktail", "bar"], "wineglass", UIColor(red: 0.66, green: 0.30, blue: 0.34, alpha: 1)),
            (["guest", "people", "friend", "person", "contact"], "person.2.fill", UIColor(red: 0.40, green: 0.52, blue: 0.74, alpha: 1)),
            (["task", "todo", "checklist", "done"], "checklist", UIColor(red: 0.38, green: 0.60, blue: 0.45, alpha: 1)),
            (["travel", "trip", "flight", "map", "world", "news"], "airplane", UIColor(red: 0.36, green: 0.54, blue: 0.70, alpha: 1)),
            (["note", "idea", "thought"], "note.text", UIColor(red: 0.55, green: 0.45, blue: 0.72, alpha: 1)),
        ]
        for rule in rules where rule.keys.contains(where: haystack.contains) {
            return (rule.symbol, rule.tint)
        }
        // Stable fallback tint from the id so cards keep distinct colors.
        let palette: [UIColor] = [
            UIColor(red: 0.55, green: 0.45, blue: 0.72, alpha: 1),
            UIColor(red: 0.40, green: 0.52, blue: 0.74, alpha: 1),
            UIColor(red: 0.38, green: 0.60, blue: 0.45, alpha: 1),
            UIColor(red: 0.70, green: 0.45, blue: 0.28, alpha: 1),
        ]
        let idx = abs(id.hashValue) % palette.count
        return (kind == .image ? "photo" : "doc.text", palette[idx])
    }
}

#endif
