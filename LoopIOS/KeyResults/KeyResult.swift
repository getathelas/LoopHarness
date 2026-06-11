//
//  KeyResult.swift
//  Loop
//
//  Data model for a single Key Result (KR). Persisted as JSON by
//  `KeyResultStore`; the bearer token is stored separately in the
//  iOS Keychain via `KeyResultKeychainHelper`.
//

import Foundation

struct KeyResultWeekValue: Codable, Equatable {
    let week: Int
    var value: Double
}

struct KeyResult: Codable, Identifiable {
    let id: String
    var title: String
    var metricName: String
    var weeklyValues: [KeyResultWeekValue]
    var apiURL: String?
    /// Placeholder — the actual token lives in the Keychain keyed by `id`.
    /// This field is always persisted as `nil`; it exists only so call-sites
    /// can pass a transient value through the struct during edits.
    var bearerToken: String?
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         title: String = "",
         metricName: String = "",
         weeklyValues: [KeyResultWeekValue] = [],
         apiURL: String? = nil,
         bearerToken: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.metricName = metricName
        self.weeklyValues = weeklyValues
        self.apiURL = apiURL
        self.bearerToken = bearerToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Current calendar quarter's week number (1-based, weeks since quarter start).
    static var currentQuarterWeek: Int {
        let cal = Calendar.current
        let now = Date()
        let quarter = (cal.component(.month, from: now) - 1) / 3
        let quarterStart = cal.date(from: DateComponents(year: cal.component(.year, from: now),
                                                         month: quarter * 3 + 1, day: 1))!
        let weeks = cal.dateComponents([.weekOfYear], from: quarterStart, to: now).weekOfYear ?? 0
        return max(weeks + 1, 1)
    }

    /// Latest recorded value (most recent week), or nil if empty.
    var latestValue: KeyResultWeekValue? {
        weeklyValues.max(by: { $0.week < $1.week })
    }
}
