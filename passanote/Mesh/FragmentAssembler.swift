import Foundation

/// Splits image data into IMAGE_FRAGMENT-sized chunks and reassembles
/// incoming fragments by transferID.
///
/// Incomplete transfers are discarded after 30 seconds (bitchat's
/// bleFragmentLifetimeSeconds). Not internally synchronized — MeshService
/// only touches it from the BLE queue.
final class FragmentAssembler {
    static let fragmentDataSize = 450
    static let transferTimeout: TimeInterval = 30
    private static let maxConcurrentTransfers = 16

    struct IncomingTransfer {
        var fragments: [UInt16: Data] = [:]
        var totalFragments: UInt16
        var sender: PeerID
        var startedAt: Date
        var receivedBytes: Int = 0

        var progress: Double {
            totalFragments == 0 ? 0 : Double(fragments.count) / Double(totalFragments)
        }
    }

    private(set) var incoming: [MessageID: IncomingTransfer] = [:]
    private var fileMetadata: [MessageID: (fileName: String, mimeType: String)] = [:]

    func registerFileStart(transferID: MessageID, fileName: String, mimeType: String) {
        fileMetadata[transferID] = (fileName, mimeType)
    }

    func consumeFileMetadata(for transferID: MessageID) -> (fileName: String, mimeType: String)? {
        fileMetadata.removeValue(forKey: transferID)
    }

    func clearFileMetadata(for transferID: MessageID) {
        fileMetadata.removeValue(forKey: transferID)
    }

    // MARK: - Outbound

    /// Split data into fragment payloads for one transfer.
    static func fragments(for data: Data, transferID: MessageID, chunkSize: Int = fragmentDataSize) -> [ImageFragmentPayload] {
        let size = max(64, chunkSize)
        let total = (data.count + size - 1) / size
        guard total > 0, total <= Int(UInt16.max) else { return [] }
        return (0..<total).map { index in
            let start = data.index(data.startIndex, offsetBy: index * size)
            let end = data.index(start, offsetBy: min(size, data.distance(from: start, to: data.endIndex)))
            return ImageFragmentPayload(
                transferID: transferID,
                seqNum: UInt16(index),
                totalFragments: UInt16(total),
                data: Data(data[start..<end])
            )
        }
    }

    // MARK: - Inbound

    enum FragmentResult {
        case progress(transferID: MessageID, sender: PeerID, fraction: Double)
        case complete(transferID: MessageID, sender: PeerID, data: Data)
        case ignored
    }

    func handleFragment(_ fragment: ImageFragmentPayload, from sender: PeerID) -> FragmentResult {
        pruneStale()

        var transfer = incoming[fragment.transferID] ?? {
            guard incoming.count < Self.maxConcurrentTransfers else { return nil }
            return IncomingTransfer(totalFragments: fragment.totalFragments, sender: sender, startedAt: Date())
        }() ?? IncomingTransfer(totalFragments: fragment.totalFragments, sender: sender, startedAt: Date())

        guard fragment.totalFragments == transfer.totalFragments,
              fragment.seqNum < transfer.totalFragments,
              transfer.fragments[fragment.seqNum] == nil else {
            return .ignored
        }

        transfer.fragments[fragment.seqNum] = fragment.data
        transfer.receivedBytes += fragment.data.count

        if transfer.fragments.count == Int(transfer.totalFragments) {
            var data = Data(capacity: transfer.receivedBytes)
            for seq in 0..<transfer.totalFragments {
                guard let piece = transfer.fragments[seq] else {
                    incoming.removeValue(forKey: fragment.transferID)
                    return .ignored
                }
                data.append(piece)
            }
            incoming.removeValue(forKey: fragment.transferID)
            return .complete(transferID: fragment.transferID, sender: transfer.sender, data: data)
        }

        incoming[fragment.transferID] = transfer
        return .progress(transferID: fragment.transferID, sender: transfer.sender, fraction: transfer.progress)
    }

    /// Drop transfers that have been stalled past the timeout.
    /// Returns the IDs that were discarded so the UI can remove placeholders.
    @discardableResult
    func pruneStale() -> [MessageID] {
        let cutoff = Date().addingTimeInterval(-Self.transferTimeout)
        let stale = incoming.filter { $0.value.startedAt < cutoff }.map(\.key)
        for id in stale {
            incoming.removeValue(forKey: id)
            fileMetadata.removeValue(forKey: id)
        }
        return stale
    }
}
