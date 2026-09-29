//
//  MattermostClient.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation

final class MattermostClient {
    private let baseURL: URL
    private let session: URLSession

    private(set) var token: String?

    init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func login(username: String, password: String) async throws {
        let url = baseURL.appending(path: "api/v4/users/login")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LoginRequest(loginID: username, password: password)
        )

        let (_, response) = try await session.data(for: request)
        let httpResponse = try requireHTTPResponse(response)

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MattermostClientError.httpStatus(httpResponse.statusCode)
        }

        guard let token = httpResponse.value(forHTTPHeaderField: "Token"),
              !token.isEmpty else {
            throw MattermostClientError.missingToken
        }

        self.token = token
    }

    func currentUser() async throws -> MattermostUser {
        try await get("api/v4/users/me")
    }

    func channel(id: String) async throws -> MattermostChannel {
        try await get("api/v4/channels/\(id)")
    }

    func availableChannels() async throws -> [MattermostChannel] {
        try await get("api/v4/users/me/channels")
    }

    func sendPost(channelID: String, message: String) async throws -> MattermostPost {
        try await post(
            "api/v4/posts",
            body: MattermostCreatePostRequest(channelID: channelID, message: message)
        )
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = try authenticatedRequest(path: path)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        var request = try authenticatedRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func authenticatedRequest(path: String) throws -> URLRequest {
        guard let token else {
            throw MattermostClientError.notAuthenticated
        }

        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let httpResponse = try requireHTTPResponse(response)

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MattermostClientError.httpStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func requireHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MattermostClientError.invalidResponse
        }

        return httpResponse
    }
}

private struct LoginRequest: Encodable {
    let loginID: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case loginID = "login_id"
        case password
    }
}

enum MattermostClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case missingToken
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Mattermost returned an invalid HTTP response."
        case .httpStatus(let statusCode):
            return "Mattermost returned HTTP \(statusCode)."
        case .missingToken:
            return "Mattermost login succeeded, but no session token was returned."
        case .notAuthenticated:
            return "Mattermost client is not authenticated."
        }
    }
}
