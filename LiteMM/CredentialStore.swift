//
//  CredentialStore.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation
import Security

struct StoredCredentials: Equatable {
    let serverURL: URL
    let username: String
    let password: String
}

final class CredentialStore {
    private let service = "com.sitis.LiteMM"
    private let credentialsAccount = "mattermost.credentials"

    func save(serverURL: URL, username: String, password: String) throws {
        let credentials = KeychainCredentials(
            serverURL: serverURL.absoluteString,
            username: username,
            password: password
        )
        let data = try JSONEncoder().encode(credentials)

        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    func load() throws -> StoredCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }

        guard let data = result as? Data else {
            throw CredentialStoreError.invalidData
        }

        let credentials = try JSONDecoder().decode(KeychainCredentials.self, from: data)

        guard let serverURL = URL(string: credentials.serverURL),
              let scheme = serverURL.scheme,
              scheme == "https" || scheme == "http",
              serverURL.host != nil else {
            throw CredentialStoreError.invalidServerURL
        }

        return StoredCredentials(
            serverURL: serverURL,
            username: credentials.username,
            password: credentials.password
        )
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsAccount
        ]
    }
}

private struct KeychainCredentials: Codable {
    let serverURL: String
    let username: String
    let password: String
}

enum CredentialStoreError: LocalizedError {
    case invalidData
    case invalidServerURL
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Keychain returned invalid credential data."
        case .invalidServerURL:
            return "Keychain contains an invalid Mattermost server URL."
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error: \(status)"
        }
    }
}
