//
//  MattermostModels.swift
//  LiteMM
//
//  Created by SITIS on 9/28/26.
//

import Foundation

struct MattermostUser: Codable, Identifiable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case nickname
    }
}

struct MattermostPost: Codable, Identifiable {
    let id: String
    let channelID: String
    let userID: String
    let message: String
    let createAt: Int64
    let rootID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case userID = "user_id"
        case message
        case createAt = "create_at"
        case rootID = "root_id"
    }
}

struct MattermostChannel: Codable, Identifiable {
    let id: String
    let type: String
    let displayName: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case displayName = "display_name"
        case name
    }
}

struct MattermostCreatePostRequest: Encodable {
    let channelID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case message
    }
}
