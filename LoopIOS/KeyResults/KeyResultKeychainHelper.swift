//
//  KeyResultKeychainHelper.swift
//  Loop
//
//  Stores and retrieves per-KR bearer tokens in the iOS Keychain.
//  Each token is keyed by the KR's UUID so tokens are isolated per KR.
//

import Foundation
import Security

enum KeyResultKeychainHelper {

    private static let service = "com.bhat.intel.keyresults"

    // MARK: - Public

    static func save(token: String, for krID: String) {
        let data = Data(token.utf8)
        // Delete any existing item first to avoid errSecDuplicateItem.
        delete(for: krID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: krID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func token(for krID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: krID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for krID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: krID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
