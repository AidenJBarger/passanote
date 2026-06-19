import Foundation
import CoreBluetooth

/// Callbacks from MeshService to the UI layer. All methods are invoked on the
/// main actor (MeshService marshals off its BLE queue before calling).
@MainActor
protocol MeshDelegate: AnyObject {
    // Presence
    func mesh(didDiscoverPeer peerID: PeerID, nickname: String, noisePublicKey: Data)
    func mesh(didLosePeer peerID: PeerID)
    func mesh(didUpdateBluetoothState state: CBManagerState)

    // Room
    func mesh(didReceiveMessage payload: MessagePayload, id: MessageID, from sender: PeerID)
    func mesh(didReceiveReaction payload: ReactionPayload, from sender: PeerID)

    // Noise session lifecycle
    func mesh(didEstablishNoiseSession with: PeerID)
    func mesh(didFailNoiseSession with: PeerID, error: Error)

    // Direct messages (already decrypted)
    func mesh(didReceiveDirectMessage content: String, id: MessageID, from sender: PeerID)
    func mesh(didReceiveDirectEnvelope envelope: DirectEnvelope, id: MessageID, from sender: PeerID)
    func mesh(didReceiveDeliveryAck messageID: MessageID, from sender: PeerID)
    func mesh(didReceiveReadAck messageIDs: [MessageID], from sender: PeerID)

    // Polls
    func mesh(didReceivePoll payload: PollCreatePayload, from sender: PeerID, directPeer: PeerID?)
    func mesh(didReceivePollVote payload: PollVotePayload, from sender: PeerID, directPeer: PeerID?)

    // Images
    func mesh(imageTransferProgress transferID: MessageID, from sender: PeerID, fraction: Double, directPeer: PeerID?)
    func mesh(didReceiveImage data: Data, transferID: MessageID, from sender: PeerID, directPeer: PeerID?)
    func mesh(didAbandonImageTransfers transferIDs: [MessageID])

    // Files
    func mesh(fileTransferStarted transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID, directPeer: PeerID?)
    func mesh(fileTransferProgress transferID: MessageID, from sender: PeerID, fraction: Double, directPeer: PeerID?)
    func mesh(didReceiveFile data: Data, transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID, directPeer: PeerID?)
}
