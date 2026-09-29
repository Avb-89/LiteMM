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
    private let selectedChannelsAccount = "mattermost.selectedChannels"

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

    func saveSelectedChannelIDs(_ channelIDs: Set<String>) throws {
        let data = try JSONEncoder().encode(Array(channelIDs).sorted())
        let query = query(account: selectedChannelsAccount)
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

    func loadSelectedChannelIDs() throws -> Set<String> {
        var query = query(account: selectedChannelsAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }

        guard let data = result as? Data else {
            throw CredentialStoreError.invalidData
        }

        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        query(account: credentialsAccount)
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
