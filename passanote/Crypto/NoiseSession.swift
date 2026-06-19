import Foundation
import CryptoKit

/// Noise_XX_25519_ChaChaPoly_SHA256, adapted from bitchat's public-domain
/// NoiseProtocol.swift, trimmed to the XX pattern.
///
/// XX handshake:
/// ```
/// Initiator                              Responder
/// -> e                                   (HANDSHAKE_1)
/// <- e, ee, s, es                        (HANDSHAKE_2)
/// -> s, se                               (HANDSHAKE_3)
/// ```
/// Transport messages carry a 4-byte big-endian nonce prefix so out-of-order
/// BLE delivery decrypts correctly, with sliding-window replay protection.

enum NoiseError: Error {
    case uninitializedCipher
    case invalidCiphertext
    case handshakeComplete
    case handshakeNotComplete
    case missingKeys
    case invalidMessage
    case authenticationFailure
    case invalidPublicKey
    case replayDetected
    case nonceExceeded
    case sessionNotEstablished
    case wrongState
}

enum NoiseRole {
    case initiator
    case responder
}

enum NoiseSessionState: Equatable {
    case none
    case handshakeInitiated
    case handshakeResponded
    case established
    case failed
}

// MARK: - Cipher State

/// ChaCha20-Poly1305 AEAD with counter nonces. When `useExtractedNonce` is on
/// (transport mode), the 4-byte nonce is prepended to ciphertext and verified
/// against a 1024-message sliding replay window.
final class NoiseCipherState {
    private static let nonceSizeBytes = 4
    private static let replayWindowSize = 1024
    private static let replayWindowBytes = replayWindowSize / 8

    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private let useExtractedNonce: Bool

    private var highestReceivedNonce: UInt64 = 0
    private var replayWindow = [UInt8](repeating: 0, count: replayWindowBytes)

    init() {
        self.useExtractedNonce = false
    }

    init(key: SymmetricKey, useExtractedNonce: Bool = false) {
        self.key = key
        self.useExtractedNonce = useExtractedNonce
    }

    func initializeKey(_ key: SymmetricKey) {
        self.key = key
        self.nonce = 0
    }

    func hasKey() -> Bool {
        key != nil
    }

    // MARK: Replay window

    private func isValidNonce(_ receivedNonce: UInt64) -> Bool {
        let windowSize = UInt64(Self.replayWindowSize)
        if highestReceivedNonce >= windowSize && receivedNonce <= highestReceivedNonce - windowSize {
            return false
        }
        if receivedNonce > highestReceivedNonce {
            return true
        }
        let offset = Int(highestReceivedNonce - receivedNonce)
        return (replayWindow[offset / 8] & (1 << (offset % 8))) == 0
    }

    private func markNonceAsSeen(_ receivedNonce: UInt64) {
        if receivedNonce > highestReceivedNonce {
            let shift = Int(receivedNonce - highestReceivedNonce)
            if shift >= Self.replayWindowSize {
                replayWindow = [UInt8](repeating: 0, count: Self.replayWindowBytes)
            } else {
                for i in stride(from: Self.replayWindowBytes - 1, through: 0, by: -1) {
                    let sourceIndex = i - shift / 8
                    var newByte: UInt8 = 0
                    if sourceIndex >= 0 {
                        newByte = replayWindow[sourceIndex] >> (shift % 8)
                        if sourceIndex > 0 && shift % 8 != 0 {
                            newByte |= replayWindow[sourceIndex - 1] << (8 - shift % 8)
                        }
                    }
                    replayWindow[i] = newByte
                }
            }
            highestReceivedNonce = receivedNonce
            replayWindow[0] |= 1
        } else {
            let offset = Int(highestReceivedNonce - receivedNonce)
            replayWindow[offset / 8] |= (1 << (offset % 8))
        }
    }

    // MARK: Encrypt/Decrypt

    private func chaChaNonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
        var nonceData = Data(count: 12)
        withUnsafeBytes(of: counter.littleEndian) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        return try ChaChaPoly.Nonce(data: nonceData)
    }

    func encrypt(plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { throw NoiseError.uninitializedCipher }
        guard nonce <= UInt64(UInt32.max) - 1 else { throw NoiseError.nonceExceeded }

        let currentNonce = nonce
        let sealedBox = try ChaChaPoly.seal(
            plaintext, using: key,
            nonce: chaChaNonce(for: currentNonce),
            authenticating: associatedData
        )
        nonce += 1

        if useExtractedNonce {
            var nonceBytes = Data(count: Self.nonceSizeBytes)
            for i in 0..<Self.nonceSizeBytes {
                nonceBytes[i] = UInt8((currentNonce >> (8 * UInt64(Self.nonceSizeBytes - 1 - i))) & 0xFF)
            }
            return nonceBytes + sealedBox.ciphertext + sealedBox.tag
        }
        return sealedBox.ciphertext + sealedBox.tag
    }

    func decrypt(ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { throw NoiseError.uninitializedCipher }
        guard ciphertext.count >= 16 else { throw NoiseError.invalidCiphertext }

        let encryptedData: Data
        let tag: Data
        let decryptionNonce: UInt64

        if useExtractedNonce {
            guard ciphertext.count >= Self.nonceSizeBytes + 16 else { throw NoiseError.invalidCiphertext }
            var extracted: UInt64 = 0
            for byte in ciphertext.prefix(Self.nonceSizeBytes) {
                extracted = (extracted << 8) | UInt64(byte)
            }
            guard isValidNonce(extracted) else { throw NoiseError.replayDetected }
            let body = ciphertext.dropFirst(Self.nonceSizeBytes)
            encryptedData = body.prefix(body.count - 16)
            tag = body.suffix(16)
            decryptionNonce = extracted
        } else {
            encryptedData = ciphertext.prefix(ciphertext.count - 16)
            tag = ciphertext.suffix(16)
            decryptionNonce = nonce
        }

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chaChaNonce(for: decryptionNonce),
            ciphertext: encryptedData,
            tag: tag
        )
        let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: associatedData)

        // Update replay state only after successful decryption.
        if useExtractedNonce {
            markNonceAsSeen(decryptionNonce)
        }
        nonce += 1
        return plaintext
    }
}

// MARK: - Symmetric State

final class NoiseSymmetricState {
    private var cipherState = NoiseCipherState()
    private var chainingKey: Data
    private var hash: Data

    init(protocolName: String) {
        let nameData = Data(protocolName.utf8)
        if nameData.count <= 32 {
            self.hash = nameData + Data(repeating: 0, count: 32 - nameData.count)
        } else {
            self.hash = Data(SHA256.hash(data: nameData))
        }
        self.chainingKey = self.hash
    }

    func mixKey(_ inputKeyMaterial: Data) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, numOutputs: 2)
        chainingKey = output[0]
        cipherState.initializeKey(SymmetricKey(data: output[1]))
    }

    func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    func hasCipherKey() -> Bool {
        cipherState.hasKey()
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        if cipherState.hasKey() {
            let ciphertext = try cipherState.encrypt(plaintext: plaintext, associatedData: hash)
            mixHash(ciphertext)
            return ciphertext
        } else {
            mixHash(plaintext)
            return plaintext
        }
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        if cipherState.hasKey() {
            let plaintext = try cipherState.decrypt(ciphertext: ciphertext, associatedData: hash)
            mixHash(ciphertext)
            return plaintext
        } else {
            mixHash(ciphertext)
            return ciphertext
        }
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), numOutputs: 2)
        let c1 = NoiseCipherState(key: SymmetricKey(data: output[0]), useExtractedNonce: true)
        let c2 = NoiseCipherState(key: SymmetricKey(data: output[1]), useExtractedNonce: true)
        // Per Noise spec, clear symmetric state after split.
        chainingKey = Data(repeating: 0, count: chainingKey.count)
        hash = Data(repeating: 0, count: hash.count)
        return (c1, c2)
    }

    private func hkdf(chainingKey: Data, inputKeyMaterial: Data, numOutputs: Int) -> [Data] {
        let tempKey = Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey)))
        var outputs: [Data] = []
        var current = Data()
        for i in 1...numOutputs {
            current = Data(HMAC<SHA256>.authenticationCode(
                for: current + Data([UInt8(i)]),
                using: SymmetricKey(data: tempKey)
            ))
            outputs.append(current)
        }
        return outputs
    }
}

// MARK: - Handshake State

/// Drives the XX message patterns. Each instance is single-use.
final class NoiseHandshakeState {
    private enum Token {
        case e, s, ee, es, se
    }

    private static let xxPatterns: [[Token]] = [
        [.e],               // -> e
        [.e, .ee, .s, .es], // <- e, ee, s, es
        [.s, .se]           // -> s, se
    ]

    private let role: NoiseRole
    private let symmetricState: NoiseSymmetricState
    private let localStaticPrivate: Curve25519.KeyAgreement.PrivateKey
    private var localEphemeralPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var remoteStaticPublic: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeralPublic: Curve25519.KeyAgreement.PublicKey?
    private var currentPattern = 0

    init(role: NoiseRole, localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.role = role
        self.localStaticPrivate = localStaticKey
        self.symmetricState = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
        // Empty prologue; XX has no pre-message keys.
        symmetricState.mixHash(Data())
    }

    func writeMessage(payload: Data = Data()) throws -> Data {
        guard currentPattern < Self.xxPatterns.count else { throw NoiseError.handshakeComplete }
        var buffer = Data()
        for token in Self.xxPatterns[currentPattern] {
            switch token {
            case .e:
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                localEphemeralPrivate = ephemeral
                buffer.append(ephemeral.publicKey.rawRepresentation)
                symmetricState.mixHash(ephemeral.publicKey.rawRepresentation)
            case .s:
                let encrypted = try symmetricState.encryptAndHash(localStaticPrivate.publicKey.rawRepresentation)
                buffer.append(encrypted)
            case .ee, .es, .se:
                try performDH(token)
            }
        }
        buffer.append(try symmetricState.encryptAndHash(payload))
        currentPattern += 1
        return buffer
    }

    func readMessage(_ message: Data) throws -> Data {
        guard currentPattern < Self.xxPatterns.count else { throw NoiseError.handshakeComplete }
        var buffer = message
        for token in Self.xxPatterns[currentPattern] {
            switch token {
            case .e:
                guard buffer.count >= 32 else { throw NoiseError.invalidMessage }
                let ephemeralData = Data(buffer.prefix(32))
                buffer = buffer.dropFirst(32)
                remoteEphemeralPublic = try Self.validatePublicKey(ephemeralData)
                symmetricState.mixHash(ephemeralData)
            case .s:
                let keyLength = symmetricState.hasCipherKey() ? 48 : 32
                guard buffer.count >= keyLength else { throw NoiseError.invalidMessage }
                let staticData = Data(buffer.prefix(keyLength))
                buffer = buffer.dropFirst(keyLength)
                do {
                    let decrypted = try symmetricState.decryptAndHash(staticData)
                    remoteStaticPublic = try Self.validatePublicKey(decrypted)
                } catch {
                    throw NoiseError.authenticationFailure
                }
            case .ee, .es, .se:
                try performDH(token)
            }
        }
        let payload = try symmetricState.decryptAndHash(Data(buffer))
        currentPattern += 1
        return payload
    }

    private func performDH(_ token: Token) throws {
        let shared: SharedSecret
        switch token {
        case .ee:
            guard let localEphemeral = localEphemeralPrivate,
                  let remoteEphemeral = remoteEphemeralPublic else { throw NoiseError.missingKeys }
            shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
        case .es:
            if role == .initiator {
                guard let localEphemeral = localEphemeralPrivate,
                      let remoteStatic = remoteStaticPublic else { throw NoiseError.missingKeys }
                shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
            } else {
                guard let remoteEphemeral = remoteEphemeralPublic else { throw NoiseError.missingKeys }
                shared = try localStaticPrivate.sharedSecretFromKeyAgreement(with: remoteEphemeral)
            }
        case .se:
            if role == .initiator {
                guard let remoteEphemeral = remoteEphemeralPublic else { throw NoiseError.missingKeys }
                shared = try localStaticPrivate.sharedSecretFromKeyAgreement(with: remoteEphemeral)
            } else {
                guard let localEphemeral = localEphemeralPrivate,
                      let remoteStatic = remoteStaticPublic else { throw NoiseError.missingKeys }
                shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
            }
        case .e, .s:
            return
        }
        symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
    }

    func isHandshakeComplete() -> Bool {
        currentPattern >= Self.xxPatterns.count
    }

    func getTransportCiphers() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isHandshakeComplete() else { throw NoiseError.handshakeNotComplete }
        let (c1, c2) = symmetricState.split()
        // Initiator sends with c1, receives with c2; responder is mirrored.
        return role == .initiator ? (c1, c2) : (c2, c1)
    }

    func getRemoteStaticPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        remoteStaticPublic
    }

    /// Reject malformed and known low-order Curve25519 points (bitchat BCH-01-010).
    static func validatePublicKey(_ keyData: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        guard keyData.count == 32 else { throw NoiseError.invalidPublicKey }
        let lowOrderPoints: [Data] = [
            Data(repeating: 0x00, count: 32),
            Data([0x01] + [UInt8](repeating: 0x00, count: 31)),
            Data([UInt8](repeating: 0x00, count: 31) + [0x01]),
            Data([0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3,
                  0xfa, 0xf1, 0x9f, 0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32,
                  0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00]),
            Data([0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1,
                  0x55, 0x9c, 0x83, 0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c,
                  0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57]),
            Data(repeating: 0xFF, count: 32)
        ]
        // Constant-time accumulation to avoid early-exit timing leaks.
        var foundBadPoint = false
        for badPoint in lowOrderPoints {
            var diff: UInt8 = 0
            for (a, b) in zip(keyData, badPoint) { diff |= a ^ b }
            if diff == 0 { foundBadPoint = true }
        }
        guard !foundBadPoint else { throw NoiseError.invalidPublicKey }
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else {
            throw NoiseError.invalidPublicKey
        }
        return key
    }
}

// MARK: - Session

/// One peer's Noise session: handshake state machine, then transport ciphers.
/// Not internally synchronized — NoiseSessionManager serializes access.
final class NoiseSession {
    let peerID: PeerID
    private(set) var role: NoiseRole
    private(set) var state: NoiseSessionState = .none

    private var handshake: NoiseHandshakeState?
    private var sendCipher: NoiseCipherState?
    private var receiveCipher: NoiseCipherState?
    private(set) var remoteStaticPublicKey: Curve25519.KeyAgreement.PublicKey?
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey

    init(peerID: PeerID, role: NoiseRole, localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.peerID = peerID
        self.role = role
        self.localStaticKey = localStaticKey
    }

    var isEstablished: Bool { state == .established }

    /// Initiator: produce HANDSHAKE_1 (-> e).
    func startHandshake() throws -> Data {
        guard state == .none, role == .initiator else { throw NoiseError.wrongState }
        let handshake = NoiseHandshakeState(role: .initiator, localStaticKey: localStaticKey)
        self.handshake = handshake
        let message = try handshake.writeMessage()
        state = .handshakeInitiated
        return message
    }

    /// Process an incoming handshake message; returns the response to send, if any.
    func processHandshakeMessage(_ message: Data) throws -> Data? {
        switch (role, state) {
        case (.responder, .none):
            // <- HANDSHAKE_1, respond with HANDSHAKE_2
            let handshake = NoiseHandshakeState(role: .responder, localStaticKey: localStaticKey)
            self.handshake = handshake
            _ = try handshake.readMessage(message)
            let response = try handshake.writeMessage()
            state = .handshakeResponded
            return response

        case (.initiator, .handshakeInitiated):
            // <- HANDSHAKE_2, respond with HANDSHAKE_3 and complete
            guard let handshake else { throw NoiseError.wrongState }
            _ = try handshake.readMessage(message)
            let response = try handshake.writeMessage()
            try completeHandshake(handshake)
            return response

        case (.responder, .handshakeResponded):
            // <- HANDSHAKE_3, complete
            guard let handshake else { throw NoiseError.wrongState }
            _ = try handshake.readMessage(message)
            try completeHandshake(handshake)
            return nil

        default:
            throw NoiseError.wrongState
        }
    }

    private func completeHandshake(_ handshake: NoiseHandshakeState) throws {
        let ciphers = try handshake.getTransportCiphers()
        sendCipher = ciphers.send
        receiveCipher = ciphers.receive
        remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
        self.handshake = nil
        state = .established
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        guard state == .established, let sendCipher else { throw NoiseError.sessionNotEstablished }
        return try sendCipher.encrypt(plaintext: plaintext)
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        guard state == .established, let receiveCipher else { throw NoiseError.sessionNotEstablished }
        return try receiveCipher.decrypt(ciphertext: ciphertext)
    }

    func markFailed() {
        state = .failed
        handshake = nil
        sendCipher = nil
        receiveCipher = nil
    }
}
