//
//  NotificationService.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import AppKit
import Foundation

@MainActor
final class NotificationService {
    private var notifiedChatIDs: Set<String> = []

    func notifyIncomingMessage(
        channelID: String,
        isCurrentChatVisible: Bool
    ) {
        guard !isCurrentChatVisible else {
            return
        }

        guard !notifiedChatIDs.contains(channelID) else {
            return
        }

        notifiedChatIDs.insert(channelID)
        playAttentionSound()
    }

    func markChatSeen(_ channelID: String) {
        notifiedChatIDs.remove(channelID)
    }

    func closeChat(_ channelID: String) {
        notifiedChatIDs.remove(channelID)
    }

    func reset() {
        notifiedChatIDs.removeAll()
    }

    private func playAttentionSound() {
        NSSound(named: "Glass")?.play()
    }
}
