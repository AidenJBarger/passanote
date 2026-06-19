import Foundation

/// JSON payload encrypted inside a `.dm` packet — text, replies, and reactions.
struct DirectEnvelope: Codable {
    enum Kind: String, Codable {
        case text
        case reaction
    }

    let kind: Kind
    var content: String?
    var replyTo: String?
    var messageID: String?
    var emoji: String?

    static func text(_ content: String, replyTo: MessageID? = nil) -> DirectEnvelope {
        DirectEnvelope(
            kind: .text,
            content: content,
            replyTo: replyTo?.id,
            messageID: nil,
            emoji: nil
        )
    }

    static func reaction(messageID: MessageID, emoji: String) -> DirectEnvelope {
        DirectEnvelope(
            kind: .reaction,
            content: nil,
            replyTo: nil,
            messageID: messageID.id,
            emoji: emoji
        )
    }
}
