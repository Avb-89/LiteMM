//
//  ChatView.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import SwiftUI
import AppKit

struct ChatView: View {
    @Bindable var appState: AppState
    var onVisibilityChange: ((Bool) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.activeChats.isEmpty {
                emptyState
            } else if let chat = appState.selectedChat {
                chatContent(chat)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 360, idealHeight: 480)
        .onAppear {
            onVisibilityChange?(true)
        }
        .onDisappear {
            onVisibilityChange?(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            connectionIndicator

            Text("LiteMM")
                .font(.headline)

            Spacer()

            if !appState.activeChats.isEmpty {
                Text("\(appState.activeChats.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Quit LiteMM")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var connectionIndicator: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 8, height: 8)
            .help(connectionText)
    }

    private var connectionColor: Color {
        switch appState.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected, .failed:
            return .red
        }
    }

    private var connectionText: String {
        switch appState.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "message")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text("No active chats")
                .font(.headline)

            Text("New Mattermost messages will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func chatContent(_ chat: ActiveChat) -> some View {
        VStack(spacing: 0) {
            chatTabs
            Divider()
            messages(chat)
            Divider()

            MessageComposer { text in
                try await appState.sendMessage(text, to: chat.channelID)
            } onClose: {
                appState.closeChat(chat.channelID)
            }
        }
    }

    private var chatTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(appState.activeChats) { chat in
                    chatTab(chat)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func chatTab(_ chat: ActiveChat) -> some View {
        HStack(spacing: 5) {
            if !chat.isSeen {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }

            Button {
                appState.selectChat(chat.channelID)
            } label: {
                Text(chat.title)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button {
                appState.closeChat(chat.channelID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close chat")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            chat.channelID == appState.selectedChatID
                ? Color.primary.opacity(0.10)
                : Color.clear,
            in: Capsule()
        )
    }

    private func messages(_ chat: ActiveChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onAppear {
                scrollToLastMessage(in: chat, proxy: proxy)
            }
            .onChange(of: chat.messages.count) {
                scrollToLastMessage(in: chat, proxy: proxy)
            }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 3) {
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: message.isOwn ? .trailing : .leading)

            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func scrollToLastMessage(
        in chat: ActiveChat,
        proxy: ScrollViewProxy
    ) {
        guard let lastID = chat.messages.last?.id else { return }

        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}
