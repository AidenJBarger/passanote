import Foundation

extension PeerID: Identifiable {}

/// A peer currently (or recently) in the room, built from ANNOUNCE packets.
struct Peer: Identifiable, Equatable {
    let peerID: PeerID
    var nickname: String
    var noisePublicKey: Data
    var lastSeen: Date
    var noiseState: NoiseSessionState = .none

    var id: String { peerID.id }

    /// Considered present if announced within the last 15 seconds
    /// (announces go out every 5).
    var isActive: Bool {
        Date().timeIntervalSince(lastSeen) < 15
    }
}
