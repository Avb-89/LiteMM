//
//  ActiveChat.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let userID: String
    let text: String
    let createdAt: Date
    let isOwn: Bool

    init(post: MattermostPost, currentUserID: String) {
        id = post.id
        userID = post.userID
        text = post.message
        createdAt = Date(timeIntervalSince1970: TimeInterval(post.createAt) / 1000)
        isOwn = post.userID == currentUserID
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

        if !message.isOwn {
            isSeen = false
        }
    }

    mutating func markSeen() {
        isSeen = true
    }
}
