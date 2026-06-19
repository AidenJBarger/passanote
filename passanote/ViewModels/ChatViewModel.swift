import Foundation
import Observation
import CoreBluetooth
import UIKit
import UserNotifications

/// Root view model: owns the mesh service and fans events out to the room
/// feed, peer list, DM threads, and polls. Mirrors how bitchat's
/// ChatViewModel wires to its mesh service.
@Observable
@MainActor
final class ChatViewModel {
    let mesh: MeshService
    let peers: PeerViewModel
    let direct: DirectViewModel

    /// Room feed, in arrival order. Memory only — gone on app close.
    var messages: [NoteMessage] = []
    var polls: [MessageID: Poll] = [:]
    var bluetoothState: CBManagerState = .unknown
    var isAppActive = true
    /// Message the composer is currently replying to (1 level deep).
    var replyTarget: NoteMessage?

    var hasNickname: Bool
    var nickname: String { CryptoIdentity.shared.nickname }
    var myPeerID: PeerID { mesh.myPeerID }

    init() {
        let mesh = MeshService()
        let peers = PeerViewModel()
        self.mesh = mesh
        self.peers = peers
        self.direct = DirectViewModel(mesh: mesh, peers: peers)
        self.hasNickname = !CryptoIdentity.shared.nickname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        mesh.delegate = self

        var skipNotificationPrompt = false
        #if DEBUG
        if CommandLine.arguments.contains("-demoFeed") {
            seedDemoFeed()
            skipNotificationPrompt = true
        }
        #endif
        if hasNickname {
            mesh.start()
            if !skipNotificationPrompt {
                requestNotificationAuthorization()
            }
            refreshBluetoothState()
        }
    }

    #if DEBUG
    /// Sample content for screenshots and previews (launch arg `-demoFeed`).
    private func seedDemoFeed() {
        let alex = PeerID()
        peers.upsert(peerID: alex, nickname: "alex", noisePublicKey: Data())
        messages.append(NoteMessage(
            id: MessageID(), kind: .text,
            content: "Anyone near the park? Getting a weak signal here.",
            senderID: alex, senderNickname: "alex",
            timestamp: Date(), isMine: false, replyToID: nil
        ))
        var mine = NoteMessage(
            id: MessageID(), kind: .text,
            content: "Yeah, I'm at the coffee shop across the street. Passing the packets along!",
            senderID: myPeerID, senderNickname: nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        mine.reactions = ["👍": [alex]]
        messages.append(mine)

        let pollID = MessageID()
        polls[pollID] = Poll(pollID: pollID, question: "lunch spot today?",
                             options: ["tacos", "ramen", "pizza"],
                             creatorPeerID: alex, votes: [0: 3, 1: 5, 2: 1], myVote: 1)
        messages.append(NoteMessage(
            id: pollID, kind: .poll, content: "lunch spot today?",
            senderID: alex, senderNickname: "alex",
            timestamp: Date(), isMine: false, replyToID: nil
        ))
    }
    #endif

    /// Persist draft nickname while typing — does not commit or start Bluetooth.
    func updateNickname(_ name: String) {
        CryptoIdentity.shared.nicknameDraft = NicknameInput.sanitized(name)
    }

    /// Commit the nickname and announce when the mesh is already running.
    func setNickname(_ name: String) {
        let trimmed = NicknameInput.sanitized(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return }
        CryptoIdentity.shared.nickname = trimmed
        CryptoIdentity.shared.nicknameDraft = trimmed
        hasNickname = true
        guard mesh.isRunning else { return }
        mesh.announce()
    }

    /// Text to pre-fill the nickname field: draft if present, else committed name.
    var nicknameForSetup: String {
        let draft = CryptoIdentity.shared.nicknameDraft
        if !draft.isEmpty { return draft }
        return CryptoIdentity.shared.nickname
    }

    /// Called after the nickname setup screen dismisses. First-time users see
    /// Bluetooth and notification prompts over the main chat, not onboarding.
    func finishNicknameSetup() {
        guard hasNickname, !mesh.isRunning else { return }
        mesh.start()
        mesh.announce()
        requestNotificationAuthorization()
        refreshBluetoothState()
    }

    /// Re-sync Bluetooth UI after permission changes or returning to the app.
    func refreshBluetoothState() {
        mesh.refreshBluetoothState()
    }

    private func requestNotificationAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Handles taps on the Bluetooth banner:
    /// - not determined → start mesh to surface the system prompt
    /// - denied/restricted → open Settings
    /// - allowed → refresh state and resume scanning/advertising
    func handleBluetoothPermissionAction() {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            if UIApplication.shared.canOpenURL(settingsURL) {
                UIApplication.shared.open(settingsURL)
            }
        case .notDetermined, .allowedAlways:
            fallthrough
        @unknown default:
            if !mesh.isRunning {
                mesh.start()
            }
            mesh.announce()
            refreshBluetoothState()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                refreshBluetoothState()
            }
        }
    }

    // MARK: - Room sending

    func sendMessage(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let messageID = mesh.sendMessage(trimmed, replyTo: replyTarget?.id)
        let message = NoteMessage(
            id: messageID, kind: .text, content: trimmed,
            senderID: myPeerID, senderNickname: nickname,
            timestamp: Date(), isMine: true, replyToID: replyTarget?.id
        )
        messages.append(message)
        replyTarget = nil
    }

    func sendReaction(_ emoji: String, to message: NoteMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        guard messages[index].reactions[emoji]?.contains(myPeerID) != true else { return }
        messages[index].reactions[emoji, default: []].insert(myPeerID)
        mesh.sendReaction(target: message.id, emoji: emoji)
    }

    func sendImage(_ image: UIImage) {
        guard let data = ImageUtils.prepareForTransfer(image) else { return }
        sendImageData(data)
    }

    /// Sends already-compressed JPEG data.
    func sendImageData(_ data: Data) {
        guard data.count <= ImageUtils.maxTransferBytes else { return }
        let transferID = mesh.sendImage(data)
        var message = NoteMessage(
            id: transferID, kind: .image, content: "",
            senderID: myPeerID, senderNickname: nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        message.imageData = data
        messages.append(message)
    }

    func sendFile(data: Data, fileName: String, mimeType: String) {
        guard data.count <= FileUtils.maxTransferBytes else { return }
        let safeName = FileUtils.sanitizedFileName(fileName)
        let transferID = mesh.sendFile(data, fileName: safeName, mimeType: mimeType)
        var message = NoteMessage(
            id: transferID, kind: .file, content: safeName,
            senderID: myPeerID, senderNickname: nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        message.fileData = data
        message.fileName = safeName
        message.fileMIMEType = mimeType
        messages.append(message)
    }

    // MARK: - Polls

    func createPoll(question: String, options: [String]) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedQuestion.isEmpty, trimmedOptions.count >= 2 else { return }

        let pollID = mesh.sendPoll(question: trimmedQuestion, options: trimmedOptions)
        polls[pollID] = Poll(pollID: pollID, question: trimmedQuestion,
                             options: trimmedOptions, creatorPeerID: myPeerID)
        let message = NoteMessage(
            id: pollID, kind: .poll, content: trimmedQuestion,
            senderID: myPeerID, senderNickname: nickname,
            timestamp: Date(), isMine: true, replyToID: nil
        )
        messages.append(message)
    }

    func vote(pollID: MessageID, optionIndex: Int) {
        guard var poll = polls[pollID], poll.myVote == nil,
              optionIndex >= 0, optionIndex < poll.options.count else { return }
        poll.myVote = optionIndex
        poll.votes[optionIndex, default: 0] += 1
        polls[pollID] = poll
        mesh.sendPollVote(pollID: pollID, optionIndex: optionIndex)
    }

    // MARK: - DM session bootstrap

    /// Called when a DM thread opens, so the handshake is done (or in flight)
    /// before the first message is sent.
    func ensureSession(with peerID: PeerID) {
        guard !mesh.noiseManager.hasEstablishedSession(with: peerID) else { return }
        mesh.initiateHandshake(with: peerID)
    }

    func sessionEstablished(with peerID: PeerID) -> Bool {
        mesh.noiseManager.hasEstablishedSession(with: peerID)
    }

    // MARK: - Mentions

    /// True when `content` mentions our nickname (@nick, case-insensitive,
    /// at a word boundary).
    func mentionsMe(_ content: String) -> Bool {
        let nick = nickname
        guard !nick.isEmpty else { return false }
        let pattern = "@\(NSRegularExpression.escapedPattern(for: nick))\\b"
        return content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Notifications

    private func postLocalNotification(title: String, body: String) {
        guard !isAppActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Feed helpers

    func message(withID id: MessageID) -> NoteMessage? {
        messages.first { $0.id == id }
    }
}

// MARK: - MeshDelegate

extension ChatViewModel: MeshDelegate {

    func mesh(didDiscoverPeer peerID: PeerID, nickname: String, noisePublicKey: Data) {
        peers.upsert(peerID: peerID, nickname: nickname, noisePublicKey: noisePublicKey)
        peers.setNoiseState(mesh.noiseManager.sessionState(for: peerID), for: peerID)
    }

    func mesh(didLosePeer peerID: PeerID) {
        peers.remove(peerID: peerID)
    }

    func mesh(didUpdateBluetoothState state: CBManagerState) {
        bluetoothState = state
    }

    func mesh(didReceiveMessage payload: MessagePayload, id: MessageID, from sender: PeerID) {
        let senderName = peers.nickname(for: sender)
        let message = NoteMessage(
            id: id, kind: .text, content: payload.content,
            senderID: sender, senderNickname: senderName,
            timestamp: Date(), isMine: false, replyToID: payload.replyToID
        )
        messages.append(message)

        if mentionsMe(payload.content) {
            postLocalNotification(title: "\(senderName) mentioned you", body: payload.content)
        }
    }

    func mesh(didReceiveReaction payload: ReactionPayload, from sender: PeerID) {
        guard let index = messages.firstIndex(where: { $0.id == payload.targetMessageID }) else { return }
        messages[index].reactions[payload.emoji, default: []].insert(sender)
    }

    func mesh(didEstablishNoiseSession peerID: PeerID) {
        peers.setNoiseState(.established, for: peerID)
        direct.flushPending(for: peerID)
    }

    func mesh(didFailNoiseSession peerID: PeerID, error: Error) {
        peers.setNoiseState(.failed, for: peerID)
    }

    func mesh(didReceiveDirectMessage content: String, id: MessageID, from sender: PeerID) {
        direct.handleIncoming(content: content, id: id, from: sender)
        if !isAppActive || direct.openThreadPeerID != sender {
            postLocalNotification(title: peers.nickname(for: sender), body: content)
        }
    }

    func mesh(didReceiveDirectEnvelope envelope: DirectEnvelope, id: MessageID, from sender: PeerID) {
        switch envelope.kind {
        case .text:
            guard let content = envelope.content else { return }
            let replyTo = envelope.replyTo.flatMap(MessageID.init(string:))
            direct.handleIncoming(content: content, id: id, from: sender, replyTo: replyTo)
            if !isAppActive || direct.openThreadPeerID != sender {
                postLocalNotification(title: peers.nickname(for: sender), body: content)
            }
        case .reaction:
            guard let messageIDString = envelope.messageID,
                  let messageID = MessageID(string: messageIDString),
                  let emoji = envelope.emoji else { return }
            direct.handleIncomingReaction(emoji, messageID: messageID, from: sender)
        }
    }

    func mesh(didReceiveDeliveryAck messageID: MessageID, from sender: PeerID) {
        direct.handleDeliveryAck(messageID, from: sender)
    }

    func mesh(didReceiveReadAck messageIDs: [MessageID], from sender: PeerID) {
        direct.handleReadAcks(messageIDs, from: sender)
    }

    func mesh(didReceivePoll payload: PollCreatePayload, from sender: PeerID, directPeer: PeerID?) {
        guard directPeer == nil else { return }
        guard polls[payload.pollID] == nil else { return }
        polls[payload.pollID] = Poll(pollID: payload.pollID, question: payload.question,
                                     options: payload.options, creatorPeerID: sender)
        let message = NoteMessage(
            id: payload.pollID, kind: .poll, content: payload.question,
            senderID: sender, senderNickname: peers.nickname(for: sender),
            timestamp: Date(), isMine: false, replyToID: nil
        )
        messages.append(message)
    }

    func mesh(didReceivePollVote payload: PollVotePayload, from sender: PeerID, directPeer: PeerID?) {
        guard directPeer == nil else { return }
        guard var poll = polls[payload.pollID],
              Int(payload.optionIndex) < poll.options.count else { return }
        poll.votes[Int(payload.optionIndex), default: 0] += 1
        polls[payload.pollID] = poll
    }

    func mesh(imageTransferProgress transferID: MessageID, from sender: PeerID, fraction: Double, directPeer: PeerID?) {
        if directPeer != nil {
            direct.handleImageTransferProgress(transferID, from: sender, fraction: fraction)
            return
        }
        if let index = messages.firstIndex(where: { $0.id == transferID }) {
            messages[index].transferProgress = fraction
        } else {
            var message = NoteMessage(
                id: transferID, kind: .image, content: "",
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.transferProgress = fraction
            messages.append(message)
        }
    }

    func mesh(didReceiveImage data: Data, transferID: MessageID, from sender: PeerID, directPeer: PeerID?) {
        if directPeer != nil {
            direct.handleIncomingImage(data, transferID: transferID, from: sender)
            return
        }
        if let index = messages.firstIndex(where: { $0.id == transferID }) {
            messages[index].imageData = data
            messages[index].transferProgress = nil
        } else {
            var message = NoteMessage(
                id: transferID, kind: .image, content: "",
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.imageData = data
            messages.append(message)
        }
    }

    func mesh(didAbandonImageTransfers transferIDs: [MessageID]) {
        let abandoned = Set(transferIDs)
        messages.removeAll {
            abandoned.contains($0.id) && $0.imageData == nil && $0.fileData == nil
        }
        direct.abandonTransfers(transferIDs)
    }

    func mesh(fileTransferStarted transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID, directPeer: PeerID?) {
        if directPeer != nil {
            direct.handleFileTransferStarted(transferID, fileName: fileName, mimeType: mimeType, from: sender)
            return
        }
        guard !messages.contains(where: { $0.id == transferID }) else { return }
        var message = NoteMessage(
            id: transferID, kind: .file, content: fileName,
            senderID: sender, senderNickname: peers.nickname(for: sender),
            timestamp: Date(), isMine: false, replyToID: nil
        )
        message.fileName = fileName
        message.fileMIMEType = mimeType
        message.transferProgress = 0
        messages.append(message)
    }

    func mesh(fileTransferProgress transferID: MessageID, from sender: PeerID, fraction: Double, directPeer: PeerID?) {
        if directPeer != nil {
            direct.handleFileTransferProgress(transferID, from: sender, fraction: fraction)
            return
        }
        if let index = messages.firstIndex(where: { $0.id == transferID }) {
            messages[index].transferProgress = fraction
        } else {
            var message = NoteMessage(
                id: transferID, kind: .file, content: "file",
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.transferProgress = fraction
            messages.append(message)
        }
    }

    func mesh(didReceiveFile data: Data, transferID: MessageID, fileName: String, mimeType: String, from sender: PeerID, directPeer: PeerID?) {
        if directPeer != nil {
            direct.handleIncomingFile(data, transferID: transferID, fileName: fileName, mimeType: mimeType, from: sender)
            return
        }
        if let index = messages.firstIndex(where: { $0.id == transferID }) {
            messages[index].fileData = data
            messages[index].fileName = fileName
            messages[index].fileMIMEType = mimeType
            messages[index].content = fileName
            messages[index].transferProgress = nil
        } else {
            var message = NoteMessage(
                id: transferID, kind: .file, content: fileName,
                senderID: sender, senderNickname: peers.nickname(for: sender),
                timestamp: Date(), isMine: false, replyToID: nil
            )
            message.fileData = data
            message.fileName = fileName
            message.fileMIMEType = mimeType
            messages.append(message)
        }
    }
}
