//
//  StatusBarController.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let appState: AppState

    private var flashTimer: Timer?
    private var flashPhase = false

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
    }

    deinit {
        flashTimer?.invalidate()
    }

    func setAttention(_ active: Bool) {
        if active {
            startFlashing()
        } else {
            stopFlashing()
        }
    }

    func show() {
        guard !popover.isShown,
              let button = statusItem.button else {
            return
        }

        appState.selectOldestUnseenChat()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        popover.performClose(nil)
    }

    func toggle() {
        if popover.isShown {
            hide()
        } else {
            show()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = normalImage()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.toolTip = "LiteMM"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 480)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ChatView(appState: appState)
        )
    }

    @objc
    private func statusItemClicked() {
        toggle()
    }

    private func startFlashing() {
        guard flashTimer == nil else { return }

        flashPhase = false
        updateAttentionImage()

        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flashPhase.toggle()
                self.updateAttentionImage()
            }
        }
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashPhase = false
        statusItem.button?.contentTintColor = nil
        statusItem.button?.image = normalImage()
    }

    private func updateAttentionImage() {
        statusItem.button?.contentTintColor = nil
        statusItem.button?.image = flashPhase ? attentionImage() : normalImage()
    }

    private func normalImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "message", accessibilityDescription: "LiteMM")
        image?.isTemplate = true
        return image
    }

    private func attentionImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "message.badge.filled.fill",
            accessibilityDescription: "LiteMM has unread messages"
        )
        image?.isTemplate = true
        return image
    }
}
