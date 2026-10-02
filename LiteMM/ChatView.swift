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
    @State private var controlsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if controlsExpanded {
                controlDrawer
                Divider()
            }

            if appState.activeChats.isEmpty {
                emptyState
            } else if let selectedChatID = appState.selectedChatID,
                      appState.activeChats.contains(where: { $0.channelID == selectedChatID }) {
                chatContent(channelID: selectedChatID)
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
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                controlsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                connectionIndicator

                Text("LiteMM")
                    .font(.headline)

                Spacer()

                Image(systemName: controlsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var controlDrawer: some View {
        HStack(spacing: 12) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                if let serverURL = appState.serverURL {
                    NSWorkspace.shared.open(serverURL)
                }
            } label: {
                Label("Mattermost", systemImage: "globe")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Exit", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    private func chatContent(channelID: String) -> some View {
        VStack(spacing: 0) {
            chatTabs
            Divider()
            messages(channelID: channelID)
            Divider()

            MessageComposer { text in
                try await appState.sendMessage(text, to: channelID)
            } onClose: {
                appState.closeChat(channelID)
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

    @ViewBuilder
    private func messages(channelID: String) -> some View {
        if let index = appState.activeChats.firstIndex(where: { $0.channelID == channelID }) {
            let chat = appState.activeChats[index]

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
                    guard let currentChat = appState.activeChats.first(where: { $0.channelID == channelID }) else {
                        return
                    }
                    scrollToLastMessage(in: currentChat, proxy: proxy)
                }
            }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(message.isOwn ? "me:" : "\(message.authorName ?? "unknown"):")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if !message.text.isEmpty {
                Text(linkifiedText(message.text))
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
            }

            if message.hasAttachments {
                Button {
                    openMessageInMattermost(message)
                } label: {
                    Label("Attachment", systemImage: "paperclip")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open in Mattermost")
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.isOwn ? .trailing : .leading
        )
    }

    private func openMessageInMattermost(_ message: ChatMessage) {
        guard let serverURL = appState.serverURL else { return }
        let url = serverURL.appending(path: "_redirect/pl/\(message.id)")
        NSWorkspace.shared.open(url)
    }

    private func linkifiedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return attributed
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: attributed) else {
                continue
            }

            attributed[attributedRange].link = url
        }

        return attributed
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
