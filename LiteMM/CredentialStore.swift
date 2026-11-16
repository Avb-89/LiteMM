//
//  CredentialStore.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation
import Security
import Observation

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

@MainActor
@Observable
final class HistorySettings {
    var isEnabled: Bool {
        didSet { saveAndApply() }
    }
    var keepAfterClosing: Bool {
        didSet { saveAndApply() }
    }
    private(set) var folderPath: String
    var lastError: String?

    private let recorder: ChatHistoryRecorder
    private let defaults: UserDefaults

    init(recorder: ChatHistoryRecorder, defaults: UserDefaults = .standard) {
        self.recorder = recorder
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "history.isEnabled")
        keepAfterClosing = defaults.bool(forKey: "history.keepAfterClosing")
        folderPath = defaults.string(forKey: "history.folderPath") ?? ""
        recorder.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.lastError = error
            }
        }
        apply()
    }

    func selectFolder(_ url: URL) {
        folderPath = url.standardizedFileURL.path
        saveAndApply()
    }

    private func saveAndApply() {
        defaults.set(isEnabled, forKey: "history.isEnabled")
        defaults.set(keepAfterClosing, forKey: "history.keepAfterClosing")
        defaults.set(folderPath, forKey: "history.folderPath")
        lastError = nil
        apply()
    }

    private func apply() {
        recorder.updateSettings(
            isEnabled: isEnabled, folderPath: folderPath, keepAfterClosing: keepAfterClosing
        )
    }
}

nonisolated final class HistoryFileStore {
    private let defaults = UserDefaults.standard
    private var owners = UserDefaults.standard.dictionary(forKey: "history.fileOwners") as? [String: String] ?? [:]

    func fileURL(in folder: URL, chatKey: String, title: String?) throws -> URL {
        if let path = owners.first(where: {
            $0.value == chatKey && URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == folder.path
        })?.key {
            let current = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                try validateFile(current)
                guard let title else { return current }
                return try rename(current, chatKey: chatKey, title: title)
            }
            owners.removeValue(forKey: path)
            save()
        }
        return availableURL(in: folder, title: title ?? "Chat", current: nil)
    }

    func recordFile(_ file: URL, chatKey: String) {
        guard owners[file.path] != chatKey else { return }
        owners[file.path] = chatKey
        save()
    }

    func owns(_ file: URL, chatKey: String) -> Bool {
        owners[file.path] == chatKey
    }

    func validateFile(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func renameFiles(chatKey: String, title: String) throws {
        let paths = owners.filter { $0.value == chatKey }.map(\.key)
        for path in paths where FileManager.default.fileExists(atPath: path) {
            _ = try rename(URL(fileURLWithPath: path), chatKey: chatKey, title: title)
        }
    }

    func removeFiles(chatKey: String? = nil) -> [String] {
        let paths = owners.filter { chatKey == nil || $0.value == chatKey }.map(\.key)
        var errors: [String] = []
        for path in paths {
            do {
                do {
                    let file = URL(fileURLWithPath: path)
                    try validateFile(file)
                    try FileManager.default.removeItem(at: file)
                } catch CocoaError.fileNoSuchFile {
                } catch CocoaError.fileReadNoSuchFile {
                }
                owners.removeValue(forKey: path)
            } catch {
                errors.append("\(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
            }
        }
        save()
        return errors
    }

    func adoptLegacyFiles(in folder: URL, namespace: String) throws -> [String] {
        let suffix = "-\(namespace).txt"
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        var channelIDs: [String] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("chat-"), name.hasSuffix(suffix) else { continue }
            let channelID = String(name.dropFirst(5).dropLast(suffix.count))
            guard channelID.utf8.count == 26,
                  channelID.unicodeScalars.allSatisfy({
                      $0.isASCII && CharacterSet.alphanumerics.contains($0)
                  }) else { continue }
            let chatKey = "\(namespace)/\(channelID)"
            guard owners[file.path] == nil || owners[file.path] == chatKey else { continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
                $0.isRegularFile == true && $0.isSymbolicLink != true
            }) == true else { continue }
            owners[file.path] = chatKey
            channelIDs.append(channelID)
        }
        save()
        return channelIDs
    }

    private func rename(_ file: URL, chatKey: String, title: String) throws -> URL {
        try validateFile(file)
        let destination = availableURL(in: file.deletingLastPathComponent(), title: title, current: file)
        guard destination != file else { return file }
        try FileManager.default.moveItem(at: file, to: destination)
        owners.removeValue(forKey: file.path)
        owners[destination.path] = chatKey
        save()
        return destination
    }

    private func availableURL(in folder: URL, title: String, current: URL?) -> URL {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters)
        var base = title.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while base.utf8.count > 180 { base.removeLast() }
        if base.isEmpty { base = "Chat" }
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) (\(index))"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension("txt")
            if let current, candidate.path.compare(current.path, options: .caseInsensitive) == .orderedSame {
                return current
            }
            let reserved = owners.keys.contains {
                $0.compare(candidate.path, options: .caseInsensitive) == .orderedSame
            }
            if !reserved && !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func save() {
        defaults.set(owners, forKey: "history.fileOwners")
    }
}
