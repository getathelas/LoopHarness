//
//  Card+DisplayMac.swift
//  LoopMac
//
//  AppKit mirror of LoopIOS/Feed/Card+Display.swift. The one-line summary and
//  kind badge are shared on the model (Card.swift); this file supplies only the
//  icon tile's symbol + tint as an NSColor, matching the iOS palette exactly so
//  the same card looks identical on both platforms.
//

#if os(macOS)
import AppKit

extension Card {

    /// SF Symbol + tint for the icon tile, inferred from the title and tags.
    var displayIcon: (symbol: String, tint: NSColor) {
        let haystack = (title + " " + tags.joined(separator: " ")).lowercased()
        let rules: [(keys: [String], symbol: String, tint: NSColor)] = [
            (["dinner", "food", "meal", "recipe", "cook", "prep", "kitchen"], "fork.knife", NSColor(srgbRed: 0.70, green: 0.45, blue: 0.28, alpha: 1)),
            (["music", "playlist", "song", "track"], "music.note", NSColor(srgbRed: 0.78, green: 0.60, blue: 0.30, alpha: 1)),
            (["wine", "drink", "cocktail", "bar"], "wineglass", NSColor(srgbRed: 0.66, green: 0.30, blue: 0.34, alpha: 1)),
            (["guest", "people", "friend", "person", "contact"], "person.2.fill", NSColor(srgbRed: 0.40, green: 0.52, blue: 0.74, alpha: 1)),
            (["task", "todo", "checklist", "done"], "checklist", NSColor(srgbRed: 0.38, green: 0.60, blue: 0.45, alpha: 1)),
            (["travel", "trip", "flight", "map", "world", "news"], "airplane", NSColor(srgbRed: 0.36, green: 0.54, blue: 0.70, alpha: 1)),
            (["note", "idea", "thought"], "note.text", NSColor(srgbRed: 0.55, green: 0.45, blue: 0.72, alpha: 1)),
        ]
        for rule in rules where rule.keys.contains(where: haystack.contains) {
            return (rule.symbol, rule.tint)
        }
        // Stable fallback tint from the id so cards keep distinct colors.
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.55, green: 0.45, blue: 0.72, alpha: 1),
            NSColor(srgbRed: 0.40, green: 0.52, blue: 0.74, alpha: 1),
            NSColor(srgbRed: 0.38, green: 0.60, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.70, green: 0.45, blue: 0.28, alpha: 1),
        ]
        let idx = abs(id.hashValue) % palette.count
        return (kind == .image ? "photo" : "doc.text", palette[idx])
    }
}

#endif
