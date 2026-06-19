import Foundation
import CryptoKit

/// Per-peer Noise session registry, following bitchat's NoiseSessionManager:
/// - new handshake initiations replace stale in-flight sessions, so peers that
///   restarted can always re-establish
/// - simultaneous-initiation races are avoided by only auto-initiating when our
///   peer ID sorts lower; the higher side waits to respond
final class NoiseSessionManager {
    private var sessions: [PeerID: NoiseSession] = [:]
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private let queue = DispatchQueue(label: "com.passanote.noise.manager")

    var onSessionEstablished: ((PeerID) -> Void)?
    var onSessionFailed: ((PeerID, Error) -> Void)?

    init(localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.localStaticKey = localStaticKey
    }

    func sessionState(for peerID: PeerID) -> NoiseSessionState {
        queue.sync { sessions[peerID]?.state ?? .none }
    }

    func hasEstablishedSession(with peerID: PeerID) -> Bool {
        queue.sync { sessions[peerID]?.isEstablished ?? false }
    }

    func removeSession(for peerID: PeerID) {
        queue.sync { _ = sessions.removeValue(forKey: peerID) }
    }

    /// Start a handshake as initiator. Returns HANDSHAKE_1 to send, or nil if a
    /// session is already established or mid-handshake.
    func initiateHandshake(with peerID: PeerID) -> Data? {
        queue.sync {
            if let existing = sessions[peerID] {
                if existing.isEstablished { return nil }
                // Replace failed sessions; leave in-flight handshakes alone.
                if existing.state == .handshakeInitiated || existing.state == .handshakeResponded {
                    return nil
                }
                sessions.removeValue(forKey: peerID)
            }
            let session = NoiseSession(peerID: peerID, role: .initiator, localStaticKey: localStaticKey)
            sessions[peerID] = session
            do {
                return try session.startHandshake()
            } catch {
                sessions.removeValue(forKey: peerID)
                return nil
            }
        }
    }

    /// Handle an incoming handshake packet. Returns a response message to send
    /// back, if the pattern calls for one.
    func handleIncomingHandshake(from peerID: PeerID, message: Data, isInitiation: Bool) throws -> Data? {
        let result: Result<Data?, Error> = queue.sync {
            var session = sessions[peerID]

            if isInitiation {
                // A fresh HANDSHAKE_1 always wins: the peer either restarted or
                // cleared its session (bitchat behavior). Reset and respond.
                sessions.removeValue(forKey: peerID)
                session = NoiseSession(peerID: peerID, role: .responder, localStaticKey: localStaticKey)
                sessions[peerID] = session
            }

            guard let session else {
                return .failure(NoiseError.wrongState)
            }

            do {
                let response = try session.processHandshakeMessage(message)
                return .success(response)
            } catch {
                session.markFailed()
                sessions.removeValue(forKey: peerID)
                return .failure(error)
            }
        }

        switch result {
        case .success(let response):
            if hasEstablishedSession(with: peerID) {
                onSessionEstablished?(peerID)
            }
            return response
        case .failure(let error):
            onSessionFailed?(peerID, error)
            throw error
        }
    }

    func encrypt(_ plaintext: Data, for peerID: PeerID) throws -> Data {
        try queue.sync {
            guard let session = sessions[peerID], session.isEstablished else {
                throw NoiseError.sessionNotEstablished
            }
            return try session.encrypt(plaintext)
        }
    }

    func decrypt(_ ciphertext: Data, from peerID: PeerID) throws -> Data {
        try queue.sync {
            guard let session = sessions[peerID], session.isEstablished else {
                throw NoiseError.sessionNotEstablished
            }
            return try session.decrypt(ciphertext)
        }
    }
}
