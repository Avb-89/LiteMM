//
//  ActiveChat.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation
import CryptoKit
import Dispatch

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let userID: String
    let text: String
    let createdAt: Date
    let isOwn: Bool
    let authorName: String?
    let hasAttachments: Bool

    init(
        post: MattermostPost,
        currentUserID: String,
        authorName: String? = nil
    ) {
        id = post.id
        userID = post.userID
        text = post.message
        createdAt = Date(timeIntervalSince1970: TimeInterval(post.createAt) / 1000)
        isOwn = post.userID == currentUserID
        self.authorName = authorName
        hasAttachments = !(post.fileIDs ?? []).isEmpty
    }
}

struct ActiveChat: Identifiable, Equatable {
    var id: String { channelID }

    let channelID: String
    var title: String
    var messages: [ChatMessage]
    var isSeen: Bool
    var latestActivityAt: Date

    init(
        channelID: String,
        title: String,
        messages: [ChatMessage] = [],
        isSeen: Bool = false,
        latestActivityAt: Date = .now
    ) {
        self.channelID = channelID
        self.title = title
        self.messages = messages
        self.isSeen = isSeen
        self.latestActivityAt = latestActivityAt
    }

    mutating func append(_ message: ChatMessage) {
        guard !messages.contains(where: { $0.id == message.id }) else {
            return
        }

        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        latestActivityAt = max(latestActivityAt, message.createdAt)

        isSeen = false
    }

    mutating func markSeen() {
        isSeen = true
    }
}

nonisolated final class ChatHistoryRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sitis.LiteMM.history", qos: .utility)
    private var isEnabled = false
    private var folderPath = ""
    private var keepAfterClosing = false
    private var selectedChannelIDs: Set<String> = []
    private var currentUserID = ""
    private var namespace = ""
    private let fileStore = HistoryFileStore()
    private var titles: [String: String] = [:]
    private var pendingTitleLookups: Set<String> = []
    private var serverURL: URL?
    private var token = ""
    private var isFinishing = false
    private var recentPostKeys: Set<String> = []
    private var recentPostOrder: [String] = []
    private var errorHandler: (@Sendable (String?) -> Void)?
    private var lastError: String?

    func setErrorHandler(_ handler: @escaping @Sendable (String?) -> Void) {
        queue.async { self.errorHandler = handler }
    }

    func updateSettings(isEnabled: Bool, folderPath: String, keepAfterClosing: Bool) {
        queue.async {
            self.isEnabled = isEnabled
            self.folderPath = folderPath
            self.keepAfterClosing = keepAfterClosing
            self.reportError(nil)
            self.adoptLegacyFiles()
        }
    }

    func setSelectedChannelIDs(_ channelIDs: Set<String>) {
        queue.async { self.selectedChannelIDs = channelIDs }
    }

    func configureSession(serverURL: URL, userID: String, token: String) {
        queue.async {
            self.currentUserID = userID
            self.serverURL = serverURL
            self.token = token
            let identity = "\(serverURL.absoluteString)\n\(userID)"
            self.namespace = SHA256.hash(data: Data(identity.utf8))
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            self.adoptLegacyFiles()
        }
    }

    func recordWebSocketText(_ text: String) {
        queue.async {
            guard self.isEnabled, !self.isFinishing else { return }
            do {
                guard let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      event["event"] as? String == "posted" else { return }
                guard let data = event["data"] as? [String: Any],
                      let postJSON = data["post"] as? String,
                      let post = try JSONSerialization.jsonObject(with: Data(postJSON.utf8)) as? [String: Any],
                      let channelID = post["channel_id"] as? String else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let channelType = data["channel_type"] as? String
                guard channelType == "D" || channelType == "G"
                        || self.selectedChannelIDs.contains(channelID) else { return }
                guard let postID = post["id"] as? String,
                      let userID = post["user_id"] as? String,
                      let message = post["message"] as? String,
                      let createdAt = post["create_at"] as? NSNumber else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let author = userID == self.currentUserID
                    ? "me" : (data["sender_name"] as? String ?? "unknown")
                let title = channelType == "D"
                    ? (userID == self.currentUserID ? nil : data["sender_name"] as? String)
                    : data["channel_display_name"] as? String
                if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.titles["\(self.namespace)/\(channelID)"] = title
                }
                try self.append(
                    postID: postID, channelID: channelID, author: author,
                    message: message, createdAt: createdAt.int64Value
                )
            } catch {
                self.reportError("History: \(error.localizedDescription)")
            }
        }
    }

    func recordSentPost(id: String, channelID: String, message: String, createdAt: Int64) {
        queue.async {
            guard self.isEnabled, !self.isFinishing else { return }
            do {
                try self.append(
                    postID: id, channelID: channelID, author: "me",
                    message: message, createdAt: createdAt
                )
            } catch {
                self.reportError("History: \(error.localizedDescription)")
            }
        }
    }

    func closeChat(_ channelID: String) {
        queue.async {
            let chatKey = "\(self.namespace)/\(channelID)"
            guard !self.keepAfterClosing else { return }
            let errors = self.fileStore.removeFiles(chatKey: chatKey)
            if errors.isEmpty {
                let prefix = chatKey + "\u{0}"
                self.recentPostKeys = self.recentPostKeys.filter { !$0.hasPrefix(prefix) }
                self.recentPostOrder.removeAll { $0.hasPrefix(prefix) }
            } else {
                self.reportError("Could not delete History:\n" + errors.joined(separator: "\n"))
            }
        }
    }

    func finishSession() -> String? {
        queue.sync {
            isFinishing = true
            guard !keepAfterClosing else { return nil }
            let adoptionError = adoptLegacyFiles()
            var errors = fileStore.removeFiles()
            if let adoptionError { errors.append(adoptionError) }
            return errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }

    func cancelExit() {
        queue.async { self.isFinishing = false }
    }

    func flush() {
        queue.sync {}
    }

    private func append(
        postID: String, channelID: String, author: String, message: String, createdAt: Int64
    ) throws {
        guard !folderPath.isEmpty else {
            reportError("Choose a History folder in Settings.")
            return
        }
        guard !namespace.isEmpty, !currentUserID.isEmpty else {
            reportError("History is waiting for a connected account.")
            return
        }
        let chatKey = "\(namespace)/\(channelID)"
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let postKey = chatKey + "\u{0}" + folder.path + "\u{0}" + postID
        let file = try fileStore.fileURL(in: folder, chatKey: chatKey, title: titles[chatKey])
        guard !recentPostKeys.contains(postKey)
                || !FileManager.default.fileExists(atPath: file.path) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
        let cleanAuthor = author.components(separatedBy: .newlines).joined(separator: " ")
        let line = "\(formatter.string(from: date)) \(cleanAuthor): \(message)\n"
        let bytes = Data(line.utf8)
        if !fileStore.owns(file, chatKey: chatKey) || !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .withoutOverwriting)
            fileStore.recordFile(file, chatKey: chatKey)
        }
        try fileStore.validateFile(file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        recentPostKeys.insert(postKey)
        recentPostOrder.append(postKey)
        if recentPostOrder.count > 4096 {
            recentPostKeys.remove(recentPostOrder.removeFirst())
        }
        reportError(nil)
        if titles[chatKey] == nil { resolveTitle(channelID: channelID, chatKey: chatKey) }
    }

    @discardableResult
    private func adoptLegacyFiles() -> String? {
        guard !folderPath.isEmpty, !namespace.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        do {
            let channelIDs = try fileStore.adoptLegacyFiles(in: folder, namespace: namespace)
            if !isFinishing {
                for channelID in channelIDs {
                    let chatKey = "\(namespace)/\(channelID)"
                    if let title = titles[chatKey] {
                        try fileStore.renameFiles(chatKey: chatKey, title: title)
                    } else {
                        resolveTitle(channelID: channelID, chatKey: chatKey)
                    }
                }
            }
            return nil
        } catch {
            let message = "History: \(error.localizedDescription)"
            reportError(message)
            return message
        }
    }

    private func resolveTitle(channelID: String, chatKey: String) {
        guard !isFinishing, let serverURL, !token.isEmpty,
              !pendingTitleLookups.contains(chatKey) else { return }
        pendingTitleLookups.insert(chatKey)
        let userID = currentUserID
        let sessionToken = token
        loadJSON("api/v4/channels/\(channelID)", serverURL: serverURL, token: sessionToken) { [weak self] channel in
            guard let self else { return }
            guard let channel else {
                self.finishTitleLookup(chatKey: chatKey, title: nil)
                return
            }
            guard channel["type"] as? String == "D" else {
                let displayName = channel["display_name"] as? String ?? ""
                self.finishTitleLookup(
                    chatKey: chatKey, title: displayName.isEmpty ? channel["name"] as? String : displayName
                )
                return
            }
            let members = (channel["name"] as? String ?? "").components(separatedBy: "__")
            let otherUserID = members.first { !$0.isEmpty && $0 != userID } ?? userID
            self.loadJSON("api/v4/users/\(otherUserID)", serverURL: serverURL, token: sessionToken) { user in
                let username = user?["username"] as? String
                self.finishTitleLookup(chatKey: chatKey, title: username.map { "@" + $0 })
            }
        }
    }

    private func finishTitleLookup(chatKey: String, title: String?) {
        queue.async {
            self.pendingTitleLookups.remove(chatKey)
            guard !self.isFinishing else { return }
            guard self.titles[chatKey] == nil else { return }
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.reportError("History: could not retrieve the chat name. The messages are still recorded.")
                return
            }
            do {
                try self.fileStore.renameFiles(chatKey: chatKey, title: title)
                self.titles[chatKey] = title
            } catch {
                self.reportError("Could not rename History: \(error.localizedDescription)")
            }
        }
    }

    private func loadJSON(
        _ path: String, serverURL: URL, token: String,
        completion: @escaping @Sendable ([String: Any]?) -> Void
    ) {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let data, let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    private func reportError(_ message: String?) {
        guard lastError != message else { return }
        lastError = message
        errorHandler?(message)
    }
}
