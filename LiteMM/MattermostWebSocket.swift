//
//  MattermostWebSocket.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation

final class MattermostWebSocket {
    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sequence = 1

    var onText: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func connect(token: String) async throws {
        disconnect()

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MattermostWebSocketError.invalidURL
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v4/websocket"

        guard let url = components.url else {
            throw MattermostWebSocketError.invalidURL
        }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        try await sendAuthentication(token: token)
        startReceiving()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        sequence = 1
    }

    private func sendAuthentication(token: String) async throws {
        guard let task else {
            throw MattermostWebSocketError.notConnected
        }

        let request = WebSocketAuthenticationRequest(
            seq: sequence,
            action: "authentication_challenge",
            data: .init(token: token)
        )
        sequence += 1

        let data = try JSONEncoder().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    guard let task = self.task else { return }
                    let message = try await task.receive()

                    switch message {
                    case .string(let text):
                        self.onText?(text)
                    case .data(let data):
                        self.onText?(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.onDisconnect?(error)
                    }
                    return
                }
            }
        }
    }
}

private struct WebSocketAuthenticationRequest: Encodable {
    let seq: Int
    let action: String
    let data: AuthenticationData

    struct AuthenticationData: Encodable {
        let token: String
    }
}

enum MattermostWebSocketError: LocalizedError {
    case invalidURL
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to build the Mattermost WebSocket URL."
        case .notConnected:
            return "Mattermost WebSocket is not connected."
        }
    }
}
