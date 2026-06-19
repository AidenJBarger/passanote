import Foundation

/// One item in the room feed or a DM thread. Memory only — never persisted.
struct NoteMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case image          // imageData holds the JPEG once complete
        case file           // fileData + fileName once complete
        case poll           // pollID == id; rendered as PollResultsView
    }

    /// DM receipt progression (own messages only).
    enum ReceiptState: Int, Comparable {
        case sent
        case delivered
        case read

        static func < (lhs: ReceiptState, rhs: ReceiptState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: MessageID
    let kind: Kind
    var content: String
    let senderID: PeerID
    var senderNickname: String
    let timestamp: Date
    let isMine: Bool
    var replyToID: MessageID?

    /// emoji → set of peers who reacted with it.
    var reactions: [String: Set<PeerID>] = [:]

    /// Image transfers: data once reassembled, progress while receiving.
    var imageData: Data?
    /// File transfers: raw bytes once reassembled.
    var fileData: Data?
    var fileName: String?
    var fileMIMEType: String?
    var transferProgress: Double?

    /// DMs only.
    var receiptState: ReceiptState?

    var idString: String { id.id }
}
