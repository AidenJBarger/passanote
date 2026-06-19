import Foundation
import Observation

/// Live peer list with Noise handshake status per peer.
@Observable
@MainActor
final class PeerViewModel {
    var peers: [PeerID: Peer] = [:]

    var sortedPeers: [Peer] {
        peers.values.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending
        }
    }

    var activeCount: Int {
        peers.values.filter(\.isActive).count
    }

    func nickname(for peerID: PeerID) -> String {
        peers[peerID]?.nickname ?? "someone"
    }

    func upsert(peerID: PeerID, nickname: String, noisePublicKey: Data) {
        if var existing = peers[peerID] {
            existing.nickname = nickname
            existing.noisePublicKey = noisePublicKey
            existing.lastSeen = Date()
            peers[peerID] = existing
        } else {
            peers[peerID] = Peer(peerID: peerID, nickname: nickname,
                                 noisePublicKey: noisePublicKey, lastSeen: Date())
        }
    }

    func remove(peerID: PeerID) {
        peers.removeValue(forKey: peerID)
    }

    func setNoiseState(_ state: NoiseSessionState, for peerID: PeerID) {
        peers[peerID]?.noiseState = state
    }
}
