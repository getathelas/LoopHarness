//
//  KeyResultFetcher.swift
//  Loop
//
//  Fetches weekly KR values from a user-configured HTTP endpoint.
//  Expected response shape: `[{ "week": <int>, "value": <number> }, ...]`
//

import Foundation

enum KeyResultFetcher {

    enum FetchError: LocalizedError {
        case invalidURL
        case missingToken
        case httpError(Int)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:           return "Invalid API URL."
            case .missingToken:         return "Bearer token is not configured."
            case .httpError(let code):  return "HTTP \(code)"
            case .decodingFailed(let m): return "Decoding failed: \(m)"
            }
        }
    }

    /// Calls the KR's configured endpoint and returns parsed weekly values.
    static func fetch(for kr: KeyResult) async throws -> [KeyResultWeekValue] {
        guard let urlString = kr.apiURL, let url = URL(string: urlString) else {
            throw FetchError.invalidURL
        }
        guard let token = KeyResultKeychainHelper.token(for: kr.id) else {
            throw FetchError.missingToken
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.httpError(http.statusCode)
        }

        struct RawEntry: Decodable {
            let week: Int
            let value: Double
        }

        do {
            let entries = try JSONDecoder().decode([RawEntry].self, from: data)
            return entries.map { KeyResultWeekValue(week: $0.week, value: $0.value) }
        } catch {
            throw FetchError.decodingFailed(error.localizedDescription)
        }
    }
}
