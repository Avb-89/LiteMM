//
//  LiteMMApp.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import SwiftUI
import AppKit

@main
struct LiteMMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        Settings {
            SettingsView(
                appState: appDelegate.appState,
                credentialStore: appDelegate.credentialStore
            )
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .onChange(of: appDelegate.openSettings == nil, initial: true) { _, _ in
            appDelegate.openSettings = {
                openSettings()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let credentialStore = CredentialStore()
    private var statusBarController: StatusBarController?
    private var attentionTask: Task<Void, Never>?
    var openSettings: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController(appState: appState)

        attentionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var lastAttentionState = self.appState.hasUnseenChats
            self.statusBarController?.setAttention(lastAttentionState)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }

                let hasUnseenChats = self.appState.hasUnseenChats
                guard hasUnseenChats != lastAttentionState else { continue }

                lastAttentionState = hasUnseenChats
                self.statusBarController?.setAttention(hasUnseenChats)
            }
        }

        Task {
            await restoreAndConnect()
        }
    }

    private func restoreAndConnect() async {
        do {
            guard let credentials = try credentialStore.load() else {
                NSApp.activate(ignoringOtherApps: true)
                openSettings?()
                return
            }

            appState.setSelectedChannelIDs(
                try credentialStore.loadSelectedChannelIDs()
            )

            appState.configure(serverURL: credentials.serverURL)
            await appState.connect(
                username: credentials.username,
                password: credentials.password
            )
        } catch {
            print("[LiteMM startup] \(error.localizedDescription)")
        }
    }
}
