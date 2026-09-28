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

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let credentialStore = CredentialStore()
    private var statusBarController: StatusBarController?
    private var attentionTask: Task<Void, Never>?

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
                return
            }

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
