import Foundation

/// Binary encode/decode for NotePacket. No JSON anywhere on the wire.
/// All multi-byte values are big-endian (network byte order), matching
/// bitchat's BinaryProtocol conventions.
enum PacketEncoder {

    static func encode(_ packet: NotePacket) -> Data? {
        guard packet.payload.count <= NotePacket.maxPayloadLength else { return nil }
        var data = Data()
        data.reserveCapacity(NotePacket.headerSize + packet.payload.count)
        data.append(packet.type.rawValue)
        data.append(packet.messageID.data)
        data.append(packet.senderID.data)
        data.append(packet.hopCount)
        let length = UInt16(packet.payload.count)
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(packet.payload)
        return data
    }

    static func decode(_ data: Data) -> NotePacket? {
        guard data.count >= NotePacket.headerSize else { return nil }
        let bytes = [UInt8](data)
        guard let type = PacketType(rawValue: bytes[0]) else { return nil }
        guard let messageID = MessageID(data: Data(bytes[1..<17])),
              let senderID = PeerID(data: Data(bytes[17..<33])) else { return nil }
        let hopCount = bytes[33]
        let payloadLength = (Int(bytes[34]) << 8) | Int(bytes[35])
        guard data.count == NotePacket.headerSize + payloadLength else { return nil }
        let payload = payloadLength > 0 ? Data(bytes[36..<(36 + payloadLength)]) : Data()
        return NotePacket(type: type, messageID: messageID, senderID: senderID,
                          hopCount: hopCount, payload: payload)
    }
}

/// Reassembles NotePacket frames from a BLE byte stream.
///
/// BLE delivers data in MTU-sized chunks (notifications and long writes), so a
/// single chunk may hold a partial frame or several frames. The 36-byte packet
/// header carries an explicit payload length, making the stream self-framing —
/// same approach as bitchat's NotificationStreamAssembler.
struct PacketStreamAssembler {
    private var buffer = Data()
    private static let maxBufferBytes = 131_072

    mutating func append(_ chunk: Data) -> [NotePacket] {
        buffer.append(chunk)
        var frames: [NotePacket] = []
        while buffer.count >= NotePacket.headerSize {
            // Validate the type byte; an unknown type means the stream is
            // corrupt and can't be resynced — drop the buffer.
            guard PacketType(rawValue: buffer[buffer.startIndex]) != nil else {
                buffer.removeAll()
                break
            }
            let lengthOffset = buffer.startIndex + 34
            let payloadLength = (Int(buffer[lengthOffset]) << 8) | Int(buffer[lengthOffset + 1])
            let frameLength = NotePacket.headerSize + payloadLength
            guard buffer.count >= frameLength else { break }
            let frame = buffer.prefix(frameLength)
            buffer.removeFirst(frameLength)
            if let packet = PacketEncoder.decode(Data(frame)) {
                frames.append(packet)
            }
        }
        if buffer.count > Self.maxBufferBytes {
            buffer.removeAll()
        }
        return frames
    }

    mutating func reset() {
        buffer.removeAll()
    }
}
