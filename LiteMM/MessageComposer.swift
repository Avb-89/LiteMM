//
//  MessageComposer.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import AppKit
import SwiftUI

struct MessageComposer: View {
    let onSend: (String) async throws -> Void
    let onClose: () -> Void

    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerTextView(text: $text) {
                send()
            }
            .frame(height: 32)

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Spacer()

                if isSending {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 34)
                }
                .help("Close current chat")
            }
        }
        .padding(10)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let message = trimmedText
        guard !message.isEmpty, !isSending else { return }

        isSending = true
        errorMessage = nil

        Task {
            do {
                try await onSend(message)

                await MainActor.run {
                    text = ""
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 4)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else {
            return
        }

        textView.onSend = onSend

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: ComposerTextView

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if isReturn && !event.modifierFlags.contains(.shift) {
            onSend?()
            return
        }

        super.keyDown(with: event)
    }
}
