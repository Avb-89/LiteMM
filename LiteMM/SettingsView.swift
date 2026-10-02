//
//  SettingsView.swift
//  LiteMM
//
//  Created by SITIS on 9/29/26.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    let credentialStore: CredentialStore

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var channels: [MattermostChannel] = []
    @State private var selectedChannelIDs: Set<String> = []
    @State private var isLoadingChannels = false
    @State private var connectionStep: StepState = .idle
    @State private var authorizationStep: StepState = .idle
    @State private var channelsStep: StepState = .idle

    private enum StepState {
        case idle
        case working
        case ok
        case failed

        var text: String {
            switch self {
            case .idle: return "—"
            case .working: return "..."
            case .ok: return "OK"
            case .failed: return "FAIL"
            }
        }
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Server", text: $server)
                    .onSubmit { saveAndReconnect() }

                TextField("Login", text: $username)
                    .onSubmit { saveAndReconnect() }

                SecureField("Password", text: $password)
                    .onSubmit { saveAndReconnect() }

                Button("Save & Connect") {
                    saveAndReconnect()
                }
            }

            Section("Channels") {
                Button(isLoadingChannels ? "Loading…" : "Load available channels") {
                    loadChannels()
                }
                .disabled(isLoadingChannels)

                ForEach(channels) { channel in
                    Toggle(
                        channelTitle(channel),
                        isOn: Binding(
                            get: { selectedChannelIDs.contains(channel.id) },
                            set: { selected in
                                setChannel(channel.id, selected: selected)
                            }
                        )
                    )
                }

                Text("Direct Messages and Group DMs are always enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Sound", value: "Coming later")
                LabeledContent("Menu Bar attention", value: "Coming later")
            }

            Section("Diagnostics") {
                diagnosticRow("Connection", state: connectionStep)
                diagnosticRow("Authorization", state: authorizationStep)
                diagnosticRow("Load channels", state: channelsStep)
            }


            Section("About") {
                LabeledContent("Application", value: "LiteMM")
                LabeledContent("Author", value: "SITIS")
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .task {
            loadStoredSettings()
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ title: String, state: StepState) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("[\(state.text)]")
                .monospaced()
        }
    }

    private func loadStoredSettings() {
        do {
            if let credentials = try credentialStore.load() {
                server = credentials.serverURL.absoluteString
                username = credentials.username
                password = credentials.password
            }

            selectedChannelIDs = try credentialStore.loadSelectedChannelIDs()
            appState.setSelectedChannelIDs(selectedChannelIDs)
        } catch {
            connectionStep = .failed
        }
    }

    private func saveAndReconnect() {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let serverURL = URL(string: trimmedServer),
              !trimmedServer.isEmpty,
              !trimmedUsername.isEmpty,
              !password.isEmpty else {
            connectionStep = .failed
            authorizationStep = .idle
            return
        }

        connectionStep = .working
        authorizationStep = .working

        do {
            try credentialStore.save(
                serverURL: serverURL,
                username: trimmedUsername,
                password: password
            )
            connectionStep = .ok
        } catch {
            connectionStep = .failed
            authorizationStep = .idle
            return
        }

        Task {
            appState.disconnect()
            appState.configure(serverURL: serverURL)
            await appState.connect(username: trimmedUsername, password: password)

            switch appState.connectionState {
            case .connected:
                authorizationStep = .ok
            case .disconnected, .connecting, .failed:
                authorizationStep = .failed
            }
        }
    }

    private func loadChannels() {
        isLoadingChannels = true
        channelsStep = .working

        Task {
            defer { isLoadingChannels = false }

            do {
                channels = try await appState.loadAvailableChannels()
                channelsStep = .ok
            } catch {
                channelsStep = .failed
            }
        }
    }

    private func setChannel(_ channelID: String, selected: Bool) {
        if selected {
            selectedChannelIDs.insert(channelID)
        } else {
            selectedChannelIDs.remove(channelID)
        }

        do {
            try credentialStore.saveSelectedChannelIDs(selectedChannelIDs)
            appState.setSelectedChannelIDs(selectedChannelIDs)
        } catch {
            channelsStep = .failed
        }
    }

    private func channelTitle(_ channel: MattermostChannel) -> String {
        channel.displayName.isEmpty ? channel.name : channel.displayName
    }

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }
}
