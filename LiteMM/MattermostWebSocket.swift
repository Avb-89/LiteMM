//
//  MattermostWebSocket.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation
import AppKit

@MainActor
final class MattermostWebSocket {
    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var openingTimeoutTask: Task<Void, Never>?
    private var pingTimeoutTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var reconnectID: UUID?
    private var pendingPingID: UUID?
    private var timedOutConnectionID: UUID?
    private var powerObservers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var token: String?
    private var shouldReconnect = false
    private var sequence = 1
    private(set) var isConnected = false

    var onText: (@MainActor (String) -> Void)?
    var onDisconnect: (@MainActor (Error?) -> Void)?
    var onReconnect: (@MainActor () -> Void)?

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
        observePowerChanges()
    }

    func disconnect() {
        shouldReconnect = false
        token = nil
        isSleeping = false
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.forEach { center.removeObserver($0) }
        powerObservers.removeAll()
        cancelReconnect()
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

        let id = connectionID
        let task = session.webSocketTask(with: url)
        self.task = task
        openingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self, self.connectionID == id else { return }
            self.timedOutConnectionID = id
            task.cancel()
        }
        task.resume()

        do {
            let authSequence = try await sendAuthentication(token: token, task: task)
            try await verifyConnection(task: task, connectionID: id, authSequence: authSequence)
            try Task.checkCancellation()
            guard connectionID == id, shouldReconnect, !isSleeping else { throw CancellationError() }
            openingTimeoutTask?.cancel()
            openingTimeoutTask = nil
            isConnected = true
            startReceiving(task: task, connectionID: id)
            startHealthChecks(connectionID: id)
            onReconnect?()
        } catch {
            let didTimeOut = timedOutConnectionID == id
            if connectionID == id { closeConnection() }
            if didTimeOut { throw MattermostWebSocketError.connectionTimedOut }
            throw error
        }
    }

    private func closeConnection() {
        connectionID = UUID()
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        openingTimeoutTask?.cancel()
        openingTimeoutTask = nil
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        pendingPingID = nil
        timedOutConnectionID = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        sequence = 1
    }

    private func cancelReconnect() {
        reconnectID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func scheduleReconnect(immediately: Bool = false) {
        guard shouldReconnect, !isSleeping,
              reconnectTask == nil else { return }

        let id = UUID()
        reconnectID = id
        reconnectTask = Task { [weak self] in
            var needsDelay = !immediately
            defer {
                if self?.reconnectID == id {
                    self?.reconnectTask = nil
                    self?.reconnectID = nil
                }
            }
            while !Task.isCancelled {
                if needsDelay {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                }
                needsDelay = true

                guard let self,
                      self.shouldReconnect, !self.isSleeping,
                      self.reconnectID == id,
                      let token = self.token else { return }

                do {
                    try await self.openConnection(token: token)
                    return
                } catch {
                    guard !Task.isCancelled, self.reconnectID == id else { return }
                }
            }
        }
    }

    private func sendAuthentication(token: String, task: URLSessionWebSocketTask) async throws -> Int {
        let authSequence = sequence
        let request = WebSocketAuthenticationRequest(
            seq: sequence,
            action: "authentication_challenge",
            data: .init(token: token)
        )
        sequence += 1

        let data = try JSONEncoder().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
        return authSequence
    }

    private func verifyConnection(
        task: URLSessionWebSocketTask, connectionID id: UUID, authSequence: Int
    ) async throws {
        while !Task.isCancelled {
            let message = try await task.receive()
            guard connectionID == id, shouldReconnect else { throw CancellationError() }
            guard let text = messageText(message) else { continue }
            onText?(text)
            guard let response = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                continue
            }
            if response["event"] as? String == "hello" { return }
            guard response["seq_reply"] as? Int == authSequence else { continue }
            guard response["status"] as? String == "OK" else {
                throw MattermostWebSocketError.authenticationFailed
            }
            return
        }
        throw CancellationError()
    }

    private func startReceiving(task: URLSessionWebSocketTask, connectionID id: UUID) {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard !Task.isCancelled, self.connectionID == id else { return }
                    if let text = self.messageText(message) {
                        self.onText?(text)
                    }
                } catch {
                    if !Task.isCancelled {
                        self.connectionFailed(error, connectionID: id)
                    }
                    return
                }
            }
        }
    }

    private func connectionFailed(_ error: Error, connectionID id: UUID) {
        guard connectionID == id, shouldReconnect else { return }
        closeConnection()
        onDisconnect?(error)
        scheduleReconnect()
    }

    private func startHealthChecks(connectionID id: UUID) {
        healthCheckTask?.cancel()

        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connectionID == id, self.isConnected else { return }
                self.checkWebSocket(connectionID: id)
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    private func checkWebSocket(connectionID id: UUID) {
        guard connectionID == id, isConnected, !isSleeping,
              pendingPingID == nil, let task else { return }
        let pingID = UUID()
        pendingPingID = pingID
        pingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self, self.connectionID == id, self.pendingPingID == pingID else { return }
            self.connectionFailed(MattermostWebSocketError.healthCheckFailed, connectionID: id)
        }
        task.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == id, self.pendingPingID == pingID else { return }
                self.pingTimeoutTask?.cancel()
                self.pingTimeoutTask = nil
                self.pendingPingID = nil
                if let error { self.connectionFailed(error, connectionID: id) }
            }
        }
    }

    private func observePowerChanges() {
        guard powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForSleep() }
        })
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAfterWake() }
        })
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkWebSocket(connectionID: self.connectionID)
            }
        })
    }

    private func suspendForSleep() {
        guard shouldReconnect else { return }
        isSleeping = true
        cancelReconnect()
        closeConnection()
        onDisconnect?(nil)
    }

    private func recoverAfterWake() {
        guard shouldReconnect, token != nil else { return }
        isSleeping = false
        cancelReconnect()
        closeConnection()
        onDisconnect?(nil)
        scheduleReconnect(immediately: true)
    }

    private func messageText(_ message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return nil
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
    case connectionTimedOut
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to build the Mattermost WebSocket URL."
        case .notConnected:
            return "Mattermost WebSocket is not connected."
        case .healthCheckFailed:
            return "Mattermost WebSocket did not answer ping."
        case .connectionTimedOut:
            return "Mattermost WebSocket connection timed out."
        case .authenticationFailed:
            return "Mattermost WebSocket authentication failed."
        }
    }
}
