//
//  AppState.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private var client: MattermostClient?
    private var webSocket: MattermostWebSocket?

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var currentUser: MattermostUser?
    private(set) var activeChats: [ActiveChat] = []
    var selectedChatID: String?

    private(set) var lastRawWebSocketEvent: String?
    var onIncomingAttention: (() -> Void)?

    init() {}

    func configure(serverURL: URL) {
        webSocket?.disconnect()

        let client = MattermostClient(baseURL: serverURL)
        let webSocket = MattermostWebSocket(baseURL: serverURL)

        webSocket.onText = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleWebSocketText(text)
            }
        }

        webSocket.onDisconnect = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.connectionState = .failed(error.localizedDescription)
                } else {
                    self.connectionState = .disconnected
                }
            }
        }

        self.client = client
        self.webSocket = webSocket
        currentUser = nil
        connectionState = .disconnected
    }

    func connect(username: String, password: String) async {
        guard connectionState != .connecting else { return }
        guard let client, let webSocket else {
            connectionState = .failed("Mattermost server is not configured.")
            return
        }

        connectionState = .connecting

        do {
            try await client.login(username: username, password: password)
            let user = try await client.currentUser()

            guard let token = client.token else {
                throw MattermostClientError.missingToken
            }

            currentUser = user
            try await webSocket.connect(token: token)
            connectionState = .connected
        } catch {
            webSocket.disconnect()
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        webSocket?.disconnect()
        connectionState = .disconnected
    }

    func selectChat(_ channelID: String) {
        selectedChatID = channelID
        markChatSeen(channelID)
    }

    func selectOldestUnseenChat() {
        let chat = activeChats
            .filter { !$0.isSeen }
            .min { $0.latestActivityAt < $1.latestActivityAt }
            ?? activeChats.first

        guard let chat else {
            selectedChatID = nil
            return
        }

        selectChat(chat.channelID)
    }

    func closeChat(_ channelID: String) {
        activeChats.removeAll { $0.channelID == channelID }

        guard selectedChatID == channelID else { return }

        selectedChatID = activeChats.first?.channelID
    }

    func markChatSeen(_ channelID: String) {
        guard let index = activeChats.firstIndex(where: { $0.channelID == channelID }) else {
            return
        }

        activeChats[index].markSeen()
    }

    func sendMessage(_ text: String, to channelID: String) async throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let currentUser else { return }
        guard let client else {
            throw AppStateError.notConfigured
        }

        let post = try await client.sendPost(channelID: channelID, message: message)
        let chatMessage = ChatMessage(post: post, currentUserID: currentUser.id)
        append(chatMessage, to: channelID, fallbackTitle: "Mattermost")
    }

    var hasUnseenChats: Bool {
        activeChats.contains { !$0.isSeen }
    }

    var selectedChat: ActiveChat? {
        guard let selectedChatID else { return nil }
        return activeChats.first { $0.channelID == selectedChatID }
    }

    private func handleWebSocketText(_ text: String) {
        lastRawWebSocketEvent = text

        guard let data = text.data(using: .utf8) else { return }

        do {
            let event = try JSONDecoder().decode(MattermostWebSocketEvent.self, from: data)
            guard event.event == "posted",
                  let postedData = event.data,
                  let postJSON = postedData.post,
                  let postData = postJSON.data(using: .utf8),
                  let currentUser else {
                return
            }

            let post = try JSONDecoder().decode(MattermostPost.self, from: postData)

            guard isRelevantPostedEvent(postedData) else { return }

            let message = ChatMessage(post: post, currentUserID: currentUser.id)

            let title: String
            if postedData.channelType == "D" || postedData.channelType == "G" {
                title = postedData.senderName ?? postedData.channelDisplayName ?? "Mattermost"
            } else {
                title = postedData.channelDisplayName ?? "Mattermost"
            }

            append(message, to: post.channelID, fallbackTitle: title)

            if !message.isOwn {
                onIncomingAttention?()
            }

            if selectedChatID == nil {
                selectedChatID = post.channelID
            }
        } catch {
            print("[LiteMM WS decode] \(error.localizedDescription)")
        }
    }

    private func isRelevantPostedEvent(_ data: MattermostWebSocketEvent.EventData) -> Bool {
        if data.channelType == "D" || data.channelType == "G" {
            return true
        }

        guard let channelName = data.channelDisplayName else { return false }

        let monitoredChannels = [
            "Техподдержка",
            "IT отдел",
            "Бухгалтерия+Техподдержка"
        ]

        return monitoredChannels.contains {
            channelName.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    private func append(
        _ message: ChatMessage,
        to channelID: String,
        fallbackTitle: String
    ) {
        if let index = activeChats.firstIndex(where: { $0.channelID == channelID }) {
            activeChats[index].append(message)
            return
        }

        var chat = ActiveChat(
            channelID: channelID,
            title: fallbackTitle,
            latestActivityAt: message.createdAt
        )
        chat.append(message)
        activeChats.append(chat)
    }
}

private struct MattermostWebSocketEvent: Decodable {
    let event: String?
    let data: EventData?

    struct EventData: Decodable {
        let post: String?
        let senderName: String?
        let channelDisplayName: String?
        let channelType: String?

        enum CodingKeys: String, CodingKey {
            case post
            case senderName = "sender_name"
            case channelDisplayName = "channel_display_name"
            case channelType = "channel_type"
        }
    }
}

enum AppStateError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Mattermost server is not configured."
        }
    }
}
