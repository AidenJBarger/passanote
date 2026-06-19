import Foundation
import Observation
import UIKit

/// All open DM threads. Receipt tracking:
/// - sent: packet broadcast into the mesh
/// - delivered: DELIVERY_ACK received (peer decrypted it)
/// - read: READ_ACK received (peer opened the thread)
@Observable
@MainActor
final class DirectViewModel {
    private let mesh: MeshService
    private let peers: PeerViewModel

    var threads: [PeerID: DirectThread] = [:]
    /// Thread currently on screen; incoming messages there are auto-read.
    var openThreadPeerID: PeerID?
    /// Message the composer is replying to (1 level deep).
    var replyTarget: NoteMessage?
    /// Messages typed before the Noise session established, keyed by their
    /// placeholder ID. Flushed (re-sent with real wire IDs) on establishment.
    private var pendingOutbox: [PeerID: [(placeholderID: MessageID, content: String, replyTo: MessageID?)]] = [:]

    init(mesh: MeshService, peers: PeerViewModel) {
        self.mesh = mesh
        self.peers = peers
    }

    var sortedThreads: [DirectThread] {
        threads.values.sorted {
            ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast)
        }
    }

    var totalUnread: Int {
        threads.values.reduce(0) { $0 + $1.unreadCount }
    }

    func thread(for peerID: PeerID) -> DirectThread {
        threads[peerID] ?? DirectThread(peerID: peerID)
    }

    func message(withID id: MessageID, in peerID: PeerID) -> NoteMessage? {
        threads[peerID]?.messages.first { $0.id == id }
    }

    // MARK: - Sending

    func send(_ content: String, to peerID: PeerID) {
        let replyTo = replyTarget?.id
        if let messageID = mesh.sendDirectMessage(content, to: peerID, replyTo: replyTo) {
            var message = NoteMessage(
                id: messageID, kind: .text, content: content,
                senderID: mesh.myPeerID, senderNickname: CryptoIdentity.shared.nickname,
                timestamp: Date(), isMine: true, replyToID: replyTo
            )
            message.receiptState = .sent
            appendMessage(message, to: peerID)
            replyTarget = nil
        } else {
            let placeholderID = MessageID()
            pendingOutbox[peerID, default: []].append((placeholderID, content, replyTo))
            let message = NoteMessage(
                id: placeholderID, kind: .text, content: content,
                senderID: mesh.myPeerID, senderNickname: CryptoIdentity.shared.nickname,
                timestamp: Date(), isMine: true, replyToID: replyTo
            )
            appendMessage(message, to: peerID)
            replyTarget = nil
        }
    }

    func sendReaction(_ emoji: String, to message: NoteMessage, in peerID: PeerID) {
        guard let index = messageIndex(message.id, in: peerID) else { return }
        guard threads[peerID]?.messages[index].reactions[emoji]?.contains(mesh.myPeerID) != true else { return }
        threads[peerID]?.messages[index].reactions[emoji, default: []].insert(mesh.myPeerID)
        mesh.sendDirectReaction(target: message.id, emoji: emoji, to: peerID)
    }

    func sendImage(_ image: UIImage, to peerID: PeerID) {
        guard let data = ImageUtils.prepareForTransfer(image) else { return }
        sendImageData(data, to: peerID)
    }

    func sendImageData(_ data: Data, to peerID: PeerID) {
        guard data.count <= ImageUtils.maxTransferBytes else { return }
        let transferID = mesh.sendImage(data, to: peerID)
        var message = NoteMessage(
            id: transferID, kind: .image, content: "",
            senderID: mesh.myPeerID, senderNickname: CryptoIdentity.shared.nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        message.imageData = data
        message.receiptState = .sent
        appendMessage(message, to: peerID)
    }

    func sendFile(data: Data, fileName: String, mimeType: String, to peerID: PeerID) {
        guard data.count <= FileUtils.maxTransferBytes else { return }
        let safeName = FileUtils.sanitizedFileName(fileName)
        let transferID = mesh.sendFile(data, fileName: safeName, mimeType: mimeType, to: peerID)
        var message = NoteMessage(
            id: transferID, kind: .file, content: safeName,
            senderID: mesh.myPeerID, senderNickname: CryptoIdentity.shared.nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        message.fileData = data
        message.fileName = safeName
        message.fileMIMEType = mimeType
        message.receiptState = .sent
        appendMessage(message, to: peerID)
    }

    /// Re-send queued messages now that the Noise session is up, swapping each
    /// placeholder for the real wire message so receipts match.
    func flushPending(for peerID: PeerID) {
        guard let pending = pendingOutbox.removeValue(forKey: peerID), !pending.isEmpty else { return }
        for (placeholderID, content, replyTo) in pending {
            guard let messageID = mesh.sendDirectMessage(content, to: peerID, replyTo: replyTo) else {
                pendingOutbox[peerID, default: []].append((placeholderID, content, replyTo))
                continue
            }
            guard var thread = threads[peerID],
                  let index = thread.messages.firstIndex(where: { $0.id == placeholderID }) else { continue }
            var message = thread.messages[index]
            message = NoteMessage(
                id: messageID, kind: .text, content: message.content,
                senderID: message.senderID, senderNickname: message.senderNickname,
                timestamp: message.timestamp, isMine: true, replyToID: replyTo
            )
            message.receiptState = .sent
            thread.messages[index] = message
            threads[peerID] = thread
        }
    }

    // MARK: - Mesh events

    func handleIncoming(content: String, id: MessageID, from sender: PeerID, replyTo: MessageID? = nil) {
        let message = NoteMessage(
            id: id, kind: .text, content: content,
            senderID: sender, senderNickname: peers.nickname(for: sender),
            timestamp: Date(), isMine: false, replyToID: replyTo
        )
        appendMessage(message, to: sender)
        markIncomingReadIfNeeded(from: sender, messageIDs: [id])
    }

    func handleIncomingReaction(_ emoji: String, messageID: MessageID, from sender: PeerID) {
        guard var thread = threads[sender],
              let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
        thread.messages[index].reactions[emoji, default: []].insert(sender)
        threads[sender] = thread
    }

    func handleImageTransferProgress(_ transferID: MessageID, from sender: PeerID, fraction: Double) {
        upsertIncomingTransfer(
            transferID: transferID, from: sender, kind: .image,
            progress: fraction
        )
    }

    func handleIncomingImage(_ data: Data, transferID: MessageID, from sender: PeerID) {
        if let index = messageIndex(transferID, in: sender) {
            threads[sender]?.messages[index].imageData = data
            threads[sender]?.messages[index].transferProgress = nil
        } else {
            var message = NoteMessage(
                id: transferID, kind: .image, content: "",
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.imageData = data
            appendMessage(message, to: sender)
        }
        markIncomingReadIfNeeded(from: sender, messageIDs: [transferID])
    }

    func handleFileTransferStarted(_ transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID) {
        guard messageIndex(transferID, in: sender) == nil else { return }
        var message = NoteMessage(
            id: transferID, kind: .file, content: fileName,
            senderID: sender, senderNickname: peers.nickname(for: sender),
            timestamp: Date(), isMine: false, replyToID: nil
        )
        message.fileName = fileName
        message.fileMIMEType = mimeType
        message.transferProgress = 0
        appendMessage(message, to: sender)
    }

    func handleFileTransferProgress(_ transferID: MessageID, from sender: PeerID, fraction: Double) {
        upsertIncomingTransfer(
            transferID: transferID, from: sender, kind: .file,
            progress: fraction, fileName: "file"
        )
    }

    func handleIncomingFile(_ data: Data, transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID) {
        if let index = messageIndex(transferID, in: sender) {
            threads[sender]?.messages[index].fileData = data
            threads[sender]?.messages[index].fileName = fileName
            threads[sender]?.messages[index].fileMIMEType = mimeType
            threads[sender]?.messages[index].content = fileName
            threads[sender]?.messages[index].transferProgress = nil
        } else {
            var message = NoteMessage(
                id: transferID, kind: .file, content: fileName,
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.fileData = data
            message.fileName = fileName
            message.fileMIMEType = mimeType
            appendMessage(message, to: sender)
        }
        markIncomingReadIfNeeded(from: sender, messageIDs: [transferID])
    }

    func abandonTransfers(_ transferIDs: [MessageID]) {
        let abandoned = Set(transferIDs)
        for peerID in threads.keys {
            guard var thread = threads[peerID] else { continue }
            thread.messages.removeAll {
                abandoned.contains($0.id) && $0.imageData == nil && $0.fileData == nil
            }
            threads[peerID] = thread
        }
    }

    func handleDeliveryAck(_ messageID: MessageID, from sender: PeerID) {
        upgradeReceipt(of: messageID, in: sender, to: .delivered)
    }

    func handleReadAcks(_ messageIDs: [MessageID], from sender: PeerID) {
        for id in messageIDs {
            upgradeReceipt(of: id, in: sender, to: .read)
        }
    }

    // MARK: - Read state

    /// Called by DMThreadView.onAppear — marks everything read and ACKs it.
    func markThreadRead(_ peerID: PeerID) {
        openThreadPeerID = peerID
        guard var thread = threads[peerID], thread.unreadCount > 0 else { return }
        let unreadIDs = thread.messages.filter { !$0.isMine }.suffix(thread.unreadCount).map(\.id)
        thread.unreadCount = 0
        threads[peerID] = thread
        mesh.sendReadAcks(for: Array(unreadIDs), to: peerID)
    }

    func closeThread() {
        openThreadPeerID = nil
        replyTarget = nil
    }

    // MARK: - Helpers

    private func appendMessage(_ message: NoteMessage, to peerID: PeerID) {
        var thread = threads[peerID] ?? DirectThread(peerID: peerID)
        thread.messages.append(message)
        threads[peerID] = thread
    }

    private func messageIndex(_ messageID: MessageID, in peerID: PeerID) -> Int? {
        threads[peerID]?.messages.firstIndex(where: { $0.id == messageID })
    }

    private func upsertIncomingTransfer(
        transferID: MessageID,
        from sender: PeerID,
        kind: NoteMessage.Kind,
        progress: Double,
        fileName: String? = nil
    ) {
        if let index = messageIndex(transferID, in: sender) {
            threads[sender]?.messages[index].transferProgress = progress
        } else {
            var message = NoteMessage(
                id: transferID, kind: kind, content: fileName ?? "",
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.transferProgress = progress
            if let fileName {
                message.fileName = fileName
            }
            appendMessage(message, to: sender)
        }
    }

    private func markIncomingReadIfNeeded(from sender: PeerID, messageIDs: [MessageID]) {
        if openThreadPeerID == sender {
            mesh.sendReadAcks(for: messageIDs, to: sender)
        } else {
            threads[sender]?.unreadCount += messageIDs.count
        }
    }

    private func upgradeReceipt(of messageID: MessageID, in peerID: PeerID, to state: NoteMessage.ReceiptState) {
        guard var thread = threads[peerID],
              let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let current = thread.messages[index].receiptState ?? .sent
        guard state > current else { return }
        thread.messages[index].receiptState = state
        threads[peerID] = thread
    }
}
