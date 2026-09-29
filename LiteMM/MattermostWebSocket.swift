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
    private var reconnectTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var token: String?
    private var shouldReconnect = false
    private var sequence = 1

    var onText: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onReconnect: (() -> Void)?

    init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func connect(token: String) async throws {
        disconnect()
        self.token = token
        shouldReconnect = true
        try await openConnection(token: token)
    }

    func disconnect() {
        shouldReconnect = false
        token = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        closeConnection()
    }

    private func openConnection(token: String) async throws {
        closeConnection()

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

        do {
            try await sendAuthentication(token: token)
            try await verifyConnection()
            startReceiving()
            startHealthChecks()
        } catch {
            closeConnection()
            throw error
        }
    }

    private func closeConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        sequence = 1
    }

    private func scheduleReconnect() {
        guard shouldReconnect,
              reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }

                guard let self,
                      self.shouldReconnect,
                      let token = self.token else { break }

                do {
                    try await self.openConnection(token: token)
                    self.onReconnect?()
                    break
                } catch {
                    continue
                }
            }

            self?.reconnectTask = nil
        }
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

    private func verifyConnection() async throws {
        guard let task else {
            throw MattermostWebSocketError.notConnected
        }

        let message = try await task.receive()

        switch message {
        case .string(let text):
            onText?(text)
        case .data(let data):
            onText?(String(decoding: data, as: UTF8.self))
        @unknown default:
            break
        }
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
                        self.receiveTask = nil
                        self.healthCheckTask?.cancel()
                        self.healthCheckTask = nil
                        self.task?.cancel(with: .normalClosure, reason: nil)
                        self.task = nil
                        self.sequence = 1
                        self.onDisconnect?(error)
                        self.scheduleReconnect()
                    }
                    return
                }
            }
        }
    }

    private func startHealthChecks() {
        healthCheckTask?.cancel()

        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }

                guard let self,
                      self.shouldReconnect else { return }

                do {
                    var request = URLRequest(
                        url: self.baseURL.appending(path: "api/v4/users/me")
                    )
                    request.httpMethod = "GET"
                    request.timeoutInterval = 5

                    guard let token = self.token else { return }
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                    let (_, response) = try await self.session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw MattermostWebSocketError.healthCheckFailed
                    }
                } catch {
                    guard !Task.isCancelled else { return }

                    self.healthCheckTask = nil
                    self.receiveTask?.cancel()
                    self.receiveTask = nil
                    self.task?.cancel(with: .normalClosure, reason: nil)
                    self.task = nil
                    self.sequence = 1
                    self.onDisconnect?(error)
                    self.scheduleReconnect()
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
    case healthCheckFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to build the Mattermost WebSocket URL."
        case .notConnected:
            return "Mattermost WebSocket is not connected."
        case .healthCheckFailed:
            return "Mattermost health check failed."
        }
    }
}
