import Foundation

// MARK: - Peer ID

/// 16-byte ephemeral peer identifier (random UUID, generated once per install).
struct PeerID: Hashable, Comparable, CustomStringConvertible {
    let uuid: UUID

    init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data) }
        self.uuid = UUID(uuid: bytes)
    }

    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    var data: Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    var id: String { uuid.uuidString }
    var description: String { uuid.uuidString }

    static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    /// All-zero sender ID used for anonymous packets (poll votes).
    static let anonymous = PeerID(data: Data(repeating: 0, count: 16))!
}

/// 16-byte message / poll / transfer identifier.
typealias MessageID = PeerID

// MARK: - Packet Types

enum PacketType: UInt8 {
    // mesh presence
    case announce           = 0x01  // join: peerID + nickname + noiseStaticPubKey
    case leave              = 0x02  // graceful disconnect

    // room
    case message            = 0x03  // broadcast text, optional replyToID
    case reaction           = 0x04  // targetMessageID + emoji

    // noise handshake (DMs only)
    case noiseHandshake1    = 0x10  // Alice → Bob: ephemeral pubkey
    case noiseHandshake2    = 0x11  // Bob → Alice: ephemeral+static, encrypted
    case noiseHandshake3    = 0x12  // Alice → Bob: static, encrypted

    // direct messages
    case dm                 = 0x20  // destinationPeerID (clear) + encrypted payload
    case deliveryAck        = 0x21  // ack that DM was received + decrypted
    case readAck            = 0x22  // ack that thread was opened

    // polls
    case pollCreate         = 0x30  // pollID + question + options[]
    case pollVote           = 0x31  // pollID + optionIndex (no sender identity)

    // images
    case imageFragment      = 0x40  // transferID + seqNum + totalFragments + data
    case imageComplete      = 0x41  // transferID + signal reassembly done

    // files
    case fileStart          = 0x42  // transferID + filename + mime type
    case fileFragment       = 0x43  // transferID + seqNum + totalFragments + data
    case fileComplete       = 0x44  // transferID + signal reassembly done

    // 1:1 variants — destinationPeerID (clear) + same body as the room type
    case dmPollCreate       = 0x50
    case dmPollVote         = 0x51
    case dmImageFragment    = 0x52
    case dmImageComplete    = 0x53
    case dmFileStart        = 0x54
    case dmFileFragment     = 0x55
    case dmFileComplete     = 0x56
}

extension PacketType {
    /// Packet types that carry a 16-byte destination peer ID at the start of
    /// their payload, in the clear, so relay nodes can route without decrypting.
    var isDirected: Bool {
        switch self {
        case .noiseHandshake1, .noiseHandshake2, .noiseHandshake3,
             .dm, .deliveryAck, .readAck,
             .dmPollCreate, .dmPollVote,
             .dmImageFragment, .dmImageComplete,
             .dmFileStart, .dmFileFragment, .dmFileComplete:
            return true
        default:
            return false
        }
    }

    /// Room packet type for a directed 1:1 variant, if one exists.
    var roomEquivalent: PacketType? {
        switch self {
        case .dmPollCreate: return .pollCreate
        case .dmPollVote: return .pollVote
        case .dmImageFragment: return .imageFragment
        case .dmImageComplete: return .imageComplete
        case .dmFileStart: return .fileStart
        case .dmFileFragment: return .fileFragment
        case .dmFileComplete: return .fileComplete
        default: return nil
        }
    }
}

// MARK: - Packet

/// One mesh packet. Wire format:
/// ```
/// [1B  type]
/// [16B messageID]
/// [16B senderPeerID]
/// [1B  hopCount]       relay nodes increment, drop at max 5
/// [2B  payloadLength]  big-endian
/// [nB  payload]
/// ```
struct NotePacket {
    static let headerSize = 36
    static let maxHops: UInt8 = 5
    static let maxPayloadLength = 65_535

    let type: PacketType
    let messageID: MessageID
    let senderID: PeerID
    var hopCount: UInt8
    let payload: Data

    init(type: PacketType,
         messageID: MessageID = MessageID(),
         senderID: PeerID,
         hopCount: UInt8 = 0,
         payload: Data = Data()) {
        self.type = type
        self.messageID = messageID
        self.senderID = senderID
        self.hopCount = hopCount
        self.payload = payload
    }

    /// Destination peer ID for directed packets (first 16 bytes of payload).
    var destinationID: PeerID? {
        guard type.isDirected, payload.count >= 16 else { return nil }
        return PeerID(data: payload.prefix(16))
    }

    /// Payload after the destination prefix for directed packets.
    var directedContent: Data {
        guard type.isDirected, payload.count >= 16 else { return payload }
        return payload.dropFirst(16)
    }
}

// MARK: - Payload Structs

/// ANNOUNCE payload — TLV encoded like bitchat's AnnouncementPacket.
struct AnnouncePayload {
    let nickname: String
    let noisePublicKey: Data        // Curve25519.KeyAgreement static public key (32B)

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
    }

    func encode() -> Data? {
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255,
              noisePublicKey.count <= 255 else { return nil }
        var data = Data()
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)
        return data
    }

    static func decode(from data: Data) -> AnnouncePayload? {
        var nickname: String?
        var noiseKey: Data?
        var offset = data.startIndex
        while offset + 2 <= data.endIndex {
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.endIndex else { return nil }
            let value = data[offset..<offset + length]
            offset += length
            switch TLVType(rawValue: typeRaw) {
            case .nickname: nickname = String(data: value, encoding: .utf8)
            case .noisePublicKey: noiseKey = Data(value)
            case nil: continue // tolerant decoder for forward compatibility
            }
        }
        guard let nickname, let noiseKey, noiseKey.count == 32 else { return nil }
        return AnnouncePayload(nickname: nickname, noisePublicKey: noiseKey)
    }
}

/// MESSAGE payload — TLV: content + optional replyToID.
struct MessagePayload {
    let content: String
    let replyToID: MessageID?

    private enum TLVType: UInt8 {
        case content = 0x01
        case replyToID = 0x02
    }

    func encode() -> Data? {
        guard let contentData = content.data(using: .utf8), contentData.count <= 65_000 else { return nil }
        var data = Data()
        // content can exceed 255 bytes; use 2-byte length for it
        data.append(TLVType.content.rawValue)
        data.append(UInt8((contentData.count >> 8) & 0xFF))
        data.append(UInt8(contentData.count & 0xFF))
        data.append(contentData)
        if let replyToID {
            data.append(TLVType.replyToID.rawValue)
            data.append(0)
            data.append(16)
            data.append(replyToID.data)
        }
        return data
    }

    static func decode(from data: Data) -> MessagePayload? {
        var content: String?
        var replyToID: MessageID?
        var offset = data.startIndex
        while offset + 3 <= data.endIndex {
            let typeRaw = data[offset]
            let length = (Int(data[offset + 1]) << 8) | Int(data[offset + 2])
            offset += 3
            guard offset + length <= data.endIndex else { return nil }
            let value = data[offset..<offset + length]
            offset += length
            switch TLVType(rawValue: typeRaw) {
            case .content: content = String(data: value, encoding: .utf8)
            case .replyToID: replyToID = MessageID(data: Data(value))
            case nil: continue
            }
        }
        guard let content else { return nil }
        return MessagePayload(content: content, replyToID: replyToID)
    }
}

/// REACTION payload — targetMessageID (16B) + emoji (UTF8, max 8B).
struct ReactionPayload {
    let targetMessageID: MessageID
    let emoji: String

    func encode() -> Data? {
        guard let emojiData = emoji.data(using: .utf8), emojiData.count <= 8 else { return nil }
        return targetMessageID.data + emojiData
    }

    static func decode(from data: Data) -> ReactionPayload? {
        guard data.count > 16, data.count <= 24,
              let target = MessageID(data: data.prefix(16)),
              let emoji = String(data: data.dropFirst(16), encoding: .utf8) else { return nil }
        return ReactionPayload(targetMessageID: target, emoji: emoji)
    }
}

/// POLL_CREATE payload — pollID (16B) + TLV question/options.
struct PollCreatePayload {
    let pollID: MessageID
    let question: String
    let options: [String]

    private enum TLVType: UInt8 {
        case question = 0x01
        case option = 0x02
    }

    func encode() -> Data? {
        guard let questionData = question.data(using: .utf8), questionData.count <= 255,
              options.count >= 2, options.count <= 4 else { return nil }
        var data = pollID.data
        data.append(TLVType.question.rawValue)
        data.append(UInt8(questionData.count))
        data.append(questionData)
        for option in options {
            guard let optionData = option.data(using: .utf8), optionData.count <= 255 else { return nil }
            data.append(TLVType.option.rawValue)
            data.append(UInt8(optionData.count))
            data.append(optionData)
        }
        return data
    }

    static func decode(from data: Data) -> PollCreatePayload? {
        guard data.count > 16, let pollID = MessageID(data: data.prefix(16)) else { return nil }
        var question: String?
        var options: [String] = []
        var offset = data.startIndex + 16
        while offset + 2 <= data.endIndex {
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.endIndex else { return nil }
            let value = data[offset..<offset + length]
            offset += length
            switch TLVType(rawValue: typeRaw) {
            case .question: question = String(data: value, encoding: .utf8)
            case .option:
                if let option = String(data: value, encoding: .utf8) { options.append(option) }
            case nil: continue
            }
        }
        guard let question, options.count >= 2 else { return nil }
        return PollCreatePayload(pollID: pollID, question: question, options: options)
    }
}

/// POLL_VOTE payload — pollID (16B) + optionIndex (1B). Sender ID is zeroed.
struct PollVotePayload {
    let pollID: MessageID
    let optionIndex: UInt8

    func encode() -> Data {
        pollID.data + Data([optionIndex])
    }

    static func decode(from data: Data) -> PollVotePayload? {
        guard data.count == 17, let pollID = MessageID(data: data.prefix(16)) else { return nil }
        return PollVotePayload(pollID: pollID, optionIndex: data[data.startIndex + 16])
    }
}

/// IMAGE_FRAGMENT payload — transferID (16B) + seqNum (2B) + totalFragments (2B) + data.
struct ImageFragmentPayload {
    let transferID: MessageID
    let seqNum: UInt16
    let totalFragments: UInt16
    let data: Data

    func encode() -> Data {
        var encoded = transferID.data
        encoded.append(UInt8((seqNum >> 8) & 0xFF))
        encoded.append(UInt8(seqNum & 0xFF))
        encoded.append(UInt8((totalFragments >> 8) & 0xFF))
        encoded.append(UInt8(totalFragments & 0xFF))
        encoded.append(data)
        return encoded
    }

    static func decode(from payload: Data) -> ImageFragmentPayload? {
        guard payload.count > 20, let transferID = MessageID(data: payload.prefix(16)) else { return nil }
        let base = payload.startIndex + 16
        let seq = (UInt16(payload[base]) << 8) | UInt16(payload[base + 1])
        let total = (UInt16(payload[base + 2]) << 8) | UInt16(payload[base + 3])
        return ImageFragmentPayload(
            transferID: transferID,
            seqNum: seq,
            totalFragments: total,
            data: Data(payload.dropFirst(20))
        )
    }
}

/// FILE_START payload — transferID (16B) + TLV filename + mime type.
struct FileStartPayload {
    let transferID: MessageID
    let fileName: String
    let mimeType: String

    private enum TLVType: UInt8 {
        case fileName = 0x01
        case mimeType = 0x02
    }

    func encode() -> Data? {
        guard let nameData = fileName.data(using: .utf8), nameData.count <= 255,
              let mimeData = mimeType.data(using: .utf8), mimeData.count <= 127 else { return nil }
        var data = transferID.data
        data.append(TLVType.fileName.rawValue)
        data.append(UInt8(nameData.count))
        data.append(nameData)
        data.append(TLVType.mimeType.rawValue)
        data.append(UInt8(mimeData.count))
        data.append(mimeData)
        return data
    }

    static func decode(from data: Data) -> FileStartPayload? {
        guard data.count > 16, let transferID = MessageID(data: data.prefix(16)) else { return nil }
        var fileName: String?
        var mimeType: String?
        var offset = data.startIndex + 16
        while offset + 2 <= data.endIndex {
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.endIndex else { return nil }
            let value = data[offset..<offset + length]
            offset += length
            switch TLVType(rawValue: typeRaw) {
            case .fileName: fileName = String(data: value, encoding: .utf8)
            case .mimeType: mimeType = String(data: value, encoding: .utf8)
            case nil: continue
            }
        }
        guard let fileName, let mimeType, !fileName.isEmpty else { return nil }
        return FileStartPayload(transferID: transferID, fileName: fileName, mimeType: mimeType)
    }
}
