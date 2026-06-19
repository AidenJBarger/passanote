import Foundation
import CoreBluetooth

/// Bluetooth mesh transport: simultaneous CBCentralManager + CBPeripheralManager,
/// peer discovery, broadcast, multi-hop relay, and Noise-encrypted DMs.
///
/// Patterns follow bitchat's BLEService:
/// - every CoreBluetooth call and delegate callback runs on one dedicated queue
/// - state restoration for background BLE
/// - frames are reassembled from MTU-sized chunks via the self-framing header
/// - notify/write backpressure queues drained on -IsReady callbacks
final class MeshService: NSObject {

    // MARK: - Constants

    static let serviceUUID = CBUUID(string: "8A1F0CE2-7D43-4B6E-9C2A-5E3D1F8B4A6C")
    static let characteristicUUID = CBUUID(string: "D4C9B2E1-3A5F-4E8D-B7C6-2F1A9E0D8C3B")
    private static let centralRestorationID = "com.passanote.ble.central"
    private static let peripheralRestorationID = "com.passanote.ble.peripheral"

    private static let maxCentralLinks = 6
    private static let announceInterval: TimeInterval = 5.0
    private static let fragmentSpacingMs = 30

    // MARK: - State (all owned by bleQueue)

    private let bleQueue = DispatchQueue(label: "com.passanote.ble", qos: .userInitiated)

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?

    private struct PeripheralLink {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic? = nil
        var peerID: PeerID? = nil
        var isConnecting = false
        var isConnected = false
        var assembler = PacketStreamAssembler()
        var pendingWrites: [Data] = []
    }
    private var peripheralLinks: [UUID: PeripheralLink] = [:]

    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var centralAssemblers: [UUID: PacketStreamAssembler] = [:]
    private var centralPeerBindings: [UUID: PeerID] = [:]
    /// Chunks waiting for the peripheral manager's notify queue to drain.
    private var pendingNotifications: [(data: Data, central: CBCentral)] = []

    private lazy var dedupCache = DeduplicationCache(queue: bleQueue)
    private let fragmentAssembler = FragmentAssembler()
    private var announceTimer: DispatchSourceTimer?
    private var isStarted = false
    private var centralState: CBManagerState = .unknown
    private var peripheralState: CBManagerState = .unknown

    // MARK: - Identity & Crypto

    private let identity = CryptoIdentity.shared
    let noiseManager: NoiseSessionManager
    var myPeerID: PeerID { identity.peerID }

    /// Known peers (peerID → noise key), used for auto-handshake decisions.
    private var knownPeers: [PeerID: Data] = [:]

    weak var delegate: MeshDelegate?

    // MARK: - Lifecycle

    override init() {
        noiseManager = NoiseSessionManager(localStaticKey: identity.staticKey)
        super.init()

        noiseManager.onSessionEstablished = { [weak self] peerID in
            self?.notifyUI { delegate in delegate.mesh(didEstablishNoiseSession: peerID) }
        }
        noiseManager.onSessionFailed = { [weak self] peerID, error in
            self?.notifyUI { delegate in delegate.mesh(didFailNoiseSession: peerID, error: error) }
        }
    }

    deinit {
        announceTimer?.cancel()
    }

    /// Starts CoreBluetooth managers and the announce timer. Deferred until
    /// onboarding completes so permission prompts appear over the main chat.
    func start() {
        bleQueue.async { [weak self] in
            self?.startLocked()
        }
    }

    var isRunning: Bool {
        bleQueue.sync { isStarted }
    }

    /// Re-read manager states and push an update to the UI — useful after the
    /// Bluetooth permission dialog, which sometimes skips delegate callbacks.
    func refreshBluetoothState() {
        bleQueue.async { [weak self] in
            self?.refreshBluetoothStateLocked()
        }
    }

    private func refreshBluetoothStateLocked() {
        if let central = centralManager {
            centralState = central.state
        }
        if let peripheral = peripheralManager {
            peripheralState = peripheral.state
        }
        publishBluetoothStateLocked()

        if combinedBluetoothStateLocked() == .poweredOn {
            startScanning()
            if characteristic != nil {
                startAdvertising()
            }
        }
    }

    private func combinedBluetoothStateLocked() -> CBManagerState {
        guard isStarted else { return .unknown }
        let states = [centralState, peripheralState]
        if states.contains(.unauthorized) { return .unauthorized }
        if states.contains(.poweredOff) { return .poweredOff }
        if states.contains(.unsupported) { return .unsupported }
        if states.contains(.resetting) { return .resetting }
        if centralState == .poweredOn, peripheralState == .poweredOn { return .poweredOn }
        return .unknown
    }

    private func publishBluetoothStateLocked() {
        let state = combinedBluetoothStateLocked()
        notifyUI { delegate in delegate.mesh(didUpdateBluetoothState: state) }
    }

    private func startLocked() {
        guard !isStarted else { return }
        isStarted = true

        centralManager = CBCentralManager(
            delegate: self, queue: bleQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestorationID]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self, queue: bleQueue,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestorationID]
        )

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 1, repeating: Self.announceInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sendAnnounceLocked()
            self?.handleStaleImageTransfersLocked()
        }
        timer.resume()
        announceTimer = timer
    }

    /// Send LEAVE before the app terminates.
    func sendLeave() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let packet = NotePacket(type: .leave, senderID: self.myPeerID)
            self.broadcastLocked(packet)
        }
    }

    // MARK: - Public Send API (callable from any thread)

    @discardableResult
    func sendMessage(_ content: String, replyTo: MessageID?) -> MessageID {
        let messageID = MessageID()
        bleQueue.async { [weak self] in
            guard let self, let payload = MessagePayload(content: content, replyToID: replyTo).encode() else { return }
            let packet = NotePacket(type: .message, messageID: messageID, senderID: self.myPeerID, payload: payload)
            self.broadcastLocked(packet)
        }
        return messageID
    }

    func sendReaction(target: MessageID, emoji: String) {
        bleQueue.async { [weak self] in
            guard let self, let payload = ReactionPayload(targetMessageID: target, emoji: emoji).encode() else { return }
            let packet = NotePacket(type: .reaction, senderID: self.myPeerID, payload: payload)
            self.broadcastLocked(packet)
        }
    }

    /// Encrypts and sends a DM. Returns nil when no established Noise session
    /// exists (and kicks off a handshake instead).
    @discardableResult
    func sendDirectMessage(_ content: String, to peerID: PeerID, replyTo: MessageID? = nil) -> MessageID? {
        sendDirectEnvelope(.text(content, replyTo: replyTo), to: peerID)
    }

    @discardableResult
    func sendDirectReaction(target: MessageID, emoji: String, to peerID: PeerID) -> MessageID? {
        sendDirectEnvelope(.reaction(messageID: target, emoji: emoji), to: peerID)
    }

    @discardableResult
    func sendDirectEnvelope(_ envelope: DirectEnvelope, to peerID: PeerID) -> MessageID? {
        guard noiseManager.hasEstablishedSession(with: peerID) else {
            initiateHandshake(with: peerID)
            return nil
        }
        guard let plaintext = try? JSONEncoder().encode(envelope),
              let ciphertext = try? noiseManager.encrypt(plaintext, for: peerID) else { return nil }
        let messageID = MessageID()
        bleQueue.async { [weak self] in
            guard let self else { return }
            let packet = NotePacket(type: .dm, messageID: messageID, senderID: self.myPeerID,
                                    payload: peerID.data + ciphertext)
            self.broadcastLocked(packet)
        }
        return messageID
    }

    func sendDeliveryAck(for messageID: MessageID, to peerID: PeerID) {
        sendEncryptedAck(type: .deliveryAck, messageIDs: [messageID], to: peerID)
    }

    func sendReadAcks(for messageIDs: [MessageID], to peerID: PeerID) {
        guard !messageIDs.isEmpty else { return }
        sendEncryptedAck(type: .readAck, messageIDs: messageIDs, to: peerID)
    }

    private func sendEncryptedAck(type: PacketType, messageIDs: [MessageID], to peerID: PeerID) {
        let plaintext = messageIDs.reduce(Data()) { $0 + $1.data }
        guard let ciphertext = try? noiseManager.encrypt(plaintext, for: peerID) else { return }
        bleQueue.async { [weak self] in
            guard let self else { return }
            let packet = NotePacket(type: type, senderID: self.myPeerID, payload: peerID.data + ciphertext)
            self.broadcastLocked(packet)
        }
    }

    @discardableResult
    func sendPoll(question: String, options: [String], to peerID: PeerID? = nil) -> MessageID {
        let pollID = MessageID()
        bleQueue.async { [weak self] in
            guard let self,
                  let body = PollCreatePayload(pollID: pollID, question: question, options: options).encode() else { return }
            let packetType: PacketType = peerID == nil ? .pollCreate : .dmPollCreate
            let payload = self.directedPayload(body, to: peerID)
            let packet = NotePacket(type: packetType, messageID: pollID, senderID: self.myPeerID, payload: payload)
            self.broadcastLocked(packet)
        }
        return pollID
    }

    func sendPollVote(pollID: MessageID, optionIndex: Int, to peerID: PeerID? = nil) {
        bleQueue.async { [weak self] in
            guard let self, optionIndex >= 0, optionIndex < 256 else { return }
            let body = PollVotePayload(pollID: pollID, optionIndex: UInt8(optionIndex)).encode()
            if let peerID {
                let payload = self.directedPayload(body, to: peerID)
                let packet = NotePacket(type: .dmPollVote, senderID: self.myPeerID, payload: payload)
                self.broadcastLocked(packet)
            } else {
                let packet = NotePacket(type: .pollVote, senderID: .anonymous, payload: body)
                self.broadcastLocked(packet)
            }
        }
    }

    /// Fragments image data and sends it paced (~30ms apart, per bitchat's
    /// fragment spacing) to avoid BLE buffer overflow. Returns the transferID.
    @discardableResult
    func sendImage(_ jpegData: Data, to peerID: PeerID? = nil) -> MessageID {
        let transferID = MessageID()
        let fragmentType: PacketType = peerID == nil ? .imageFragment : .dmImageFragment
        let completeType: PacketType = peerID == nil ? .imageComplete : .dmImageComplete
        bleQueue.async { [weak self] in
            guard let self else { return }
            let fragments = FragmentAssembler.fragments(for: jpegData, transferID: transferID)
            for (index, fragment) in fragments.enumerated() {
                let delay = DispatchTimeInterval.milliseconds(index * Self.fragmentSpacingMs)
                self.bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let body = fragment.encode()
                    let payload = self.directedPayload(body, to: peerID)
                    let packet = NotePacket(type: fragmentType, senderID: self.myPeerID, payload: payload)
                    self.broadcastLocked(packet)
                }
            }
            let completeDelay = DispatchTimeInterval.milliseconds(fragments.count * Self.fragmentSpacingMs)
            self.bleQueue.asyncAfter(deadline: .now() + completeDelay) { [weak self] in
                guard let self else { return }
                let payload = self.directedPayload(transferID.data, to: peerID)
                let packet = NotePacket(type: completeType, senderID: self.myPeerID, payload: payload)
                self.broadcastLocked(packet)
            }
        }
        return transferID
    }

    /// Fragments file data after announcing metadata. Returns the transferID.
    @discardableResult
    func sendFile(_ data: Data, fileName: String, mimeType: String, to peerID: PeerID? = nil) -> MessageID {
        let transferID = MessageID()
        let startType: PacketType = peerID == nil ? .fileStart : .dmFileStart
        let fragmentType: PacketType = peerID == nil ? .fileFragment : .dmFileFragment
        let completeType: PacketType = peerID == nil ? .fileComplete : .dmFileComplete
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard let startBody = FileStartPayload(
                transferID: transferID, fileName: fileName, mimeType: mimeType
            ).encode() else { return }
            let startPayload = self.directedPayload(startBody, to: peerID)
            let startPacket = NotePacket(type: startType, messageID: transferID,
                                         senderID: self.myPeerID, payload: startPayload)
            self.broadcastLocked(startPacket)

            let fragments = FragmentAssembler.fragments(for: data, transferID: transferID)
            for (index, fragment) in fragments.enumerated() {
                let delay = DispatchTimeInterval.milliseconds(index * Self.fragmentSpacingMs)
                self.bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let body = fragment.encode()
                    let payload = self.directedPayload(body, to: peerID)
                    let packet = NotePacket(type: fragmentType, senderID: self.myPeerID, payload: payload)
                    self.broadcastLocked(packet)
                }
            }
            let completeDelay = DispatchTimeInterval.milliseconds(fragments.count * Self.fragmentSpacingMs)
            self.bleQueue.asyncAfter(deadline: .now() + completeDelay) { [weak self] in
                guard let self else { return }
                let payload = self.directedPayload(transferID.data, to: peerID)
                let packet = NotePacket(type: completeType, senderID: self.myPeerID, payload: payload)
                self.broadcastLocked(packet)
            }
        }
        return transferID
    }

    /// Re-announce immediately (e.g. after the nickname changes).
    func announce() {
        bleQueue.async { [weak self] in
            self?.sendAnnounceLocked()
        }
    }

    /// Prefixes a payload with the destination peer ID for directed delivery.
    private func directedPayload(_ body: Data, to peerID: PeerID?) -> Data {
        guard let peerID else { return body }
        return peerID.data + body
    }

    func initiateHandshake(with peerID: PeerID) {
        guard let handshake1 = noiseManager.initiateHandshake(with: peerID) else { return }
        bleQueue.async { [weak self] in
            guard let self else { return }
            let packet = NotePacket(type: .noiseHandshake1, senderID: self.myPeerID,
                                    payload: peerID.data + handshake1)
            self.broadcastLocked(packet)
        }
    }

    // MARK: - Announce

    private func sendAnnounceLocked(force: Bool = false) {
        guard let payload = AnnouncePayload(
            nickname: identity.nickname,
            noisePublicKey: identity.staticPublicKeyData
        ).encode() else { return }
        let packet = NotePacket(type: .announce, senderID: myPeerID, payload: payload)
        broadcastLocked(packet)
    }

    // MARK: - Transmit (bleQueue only)

    /// Encode and send a locally-created packet on every link.
    private func broadcastLocked(_ packet: NotePacket) {
        guard let data = PacketEncoder.encode(packet) else { return }
        // Pre-mark our own broadcast so a relayed copy isn't reprocessed.
        dedupCache.markProcessed(packet.messageID.id)
        transmitLocked(data, excludePeripheral: nil, excludeCentral: nil)
    }

    private func transmitLocked(_ data: Data, excludePeripheral: UUID?, excludeCentral: UUID?) {
        // Central role: write to connected peripherals.
        for (id, link) in peripheralLinks {
            guard id != excludePeripheral, link.isConnected, let characteristic = link.characteristic else { continue }
            writeOrEnqueue(data, link: link, linkID: id, characteristic: characteristic)
        }

        // Peripheral role: notify subscribed centrals, chunked to each
        // central's update limit (receiver reassembles via stream framing).
        guard let mutableCharacteristic = self.characteristic else { return }
        for (id, central) in subscribedCentrals {
            guard id != excludeCentral else { continue }
            let chunkSize = max(20, central.maximumUpdateValueLength)
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: min(chunkSize, data.distance(from: offset, to: data.endIndex)))
                let chunk = Data(data[offset..<end])
                offset = end
                if !pendingNotifications.isEmpty {
                    pendingNotifications.append((chunk, central))
                } else if peripheralManager?.updateValue(chunk, for: mutableCharacteristic, onSubscribedCentrals: [central]) != true {
                    pendingNotifications.append((chunk, central))
                }
            }
        }
    }

    private func writeOrEnqueue(_ data: Data, link: PeripheralLink, linkID: UUID, characteristic: CBCharacteristic) {
        let maxWithoutResponse = link.peripheral.maximumWriteValueLength(for: .withoutResponse)
        if data.count > maxWithoutResponse {
            // CoreBluetooth performs the long-write chunking for .withResponse.
            link.peripheral.writeValue(data, for: characteristic, type: .withResponse)
            return
        }
        if link.peripheral.canSendWriteWithoutResponse && peripheralLinks[linkID]?.pendingWrites.isEmpty != false {
            link.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            peripheralLinks[linkID]?.pendingWrites.append(data)
        }
    }

    private func drainPendingWrites(for peripheral: CBPeripheral) {
        let linkID = peripheral.identifier
        guard var link = peripheralLinks[linkID], let characteristic = link.characteristic else { return }
        while !link.pendingWrites.isEmpty && peripheral.canSendWriteWithoutResponse {
            let data = link.pendingWrites.removeFirst()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
        peripheralLinks[linkID] = link
    }

    private func drainPendingNotifications() {
        guard let mutableCharacteristic = characteristic else { return }
        while !pendingNotifications.isEmpty {
            let (data, central) = pendingNotifications[0]
            guard peripheralManager?.updateValue(data, for: mutableCharacteristic, onSubscribedCentrals: [central]) == true else { break }
            pendingNotifications.removeFirst()
        }
    }

    // MARK: - Receive & Relay (bleQueue only)

    private func handlePacket(_ packet: NotePacket, fromPeripheral: UUID?, fromCentral: UUID?) {
        guard packet.senderID != myPeerID else { return }
        guard !dedupCache.isDuplicate(packet.messageID.id) else { return }

        // Bind direct links to peer IDs on first-hop announces.
        if packet.type == .announce, packet.hopCount == 0 {
            if let peripheralID = fromPeripheral {
                peripheralLinks[peripheralID]?.peerID = packet.senderID
            }
            if let centralID = fromCentral {
                centralPeerBindings[centralID] = packet.senderID
            }
        }

        let isForMe = packet.destinationID == myPeerID
        if !packet.type.isDirected || isForMe {
            processLocked(packet)
        }

        // Relay: flood with hop limiting. Directed packets addressed to us
        // stop here; everything else is forwarded (relays never decrypt).
        if !isForMe {
            var relayed = packet
            relayed.hopCount += 1
            if relayed.hopCount < NotePacket.maxHops, let data = PacketEncoder.encode(relayed) {
                transmitLocked(data, excludePeripheral: fromPeripheral, excludeCentral: fromCentral)
            }
        }
    }

    private func processLocked(_ packet: NotePacket) {
        let sender = packet.senderID
        switch packet.type {
        case .announce:
            guard let announce = AnnouncePayload.decode(from: packet.payload) else { return }
            let isNewPeer = knownPeers[sender] == nil
            knownPeers[sender] = announce.noisePublicKey
            notifyUI { delegate in
                delegate.mesh(didDiscoverPeer: sender, nickname: announce.nickname,
                              noisePublicKey: announce.noisePublicKey)
            }
            // Auto-handshake so sessions are in transport mode before anyone
            // opens a DM. Only the lexicographically-lower peer initiates,
            // avoiding simultaneous-initiation races.
            if isNewPeer || !noiseManager.hasEstablishedSession(with: sender) {
                if myPeerID < sender, noiseManager.sessionState(for: sender) == .none {
                    initiateHandshakeLocked(with: sender)
                }
            }

        case .leave:
            knownPeers.removeValue(forKey: sender)
            notifyUI { delegate in delegate.mesh(didLosePeer: sender) }

        case .message:
            guard let payload = MessagePayload.decode(from: packet.payload) else { return }
            notifyUI { delegate in
                delegate.mesh(didReceiveMessage: payload, id: packet.messageID, from: sender)
            }

        case .reaction:
            guard let payload = ReactionPayload.decode(from: packet.payload) else { return }
            notifyUI { delegate in delegate.mesh(didReceiveReaction: payload, from: sender) }

        case .noiseHandshake1, .noiseHandshake2, .noiseHandshake3:
            handleHandshakePacketLocked(packet)

        case .dm:
            let ciphertext = Data(packet.directedContent)
            guard let plaintext = try? noiseManager.decrypt(ciphertext, from: sender) else {
                noiseManager.removeSession(for: sender)
                if myPeerID < sender { initiateHandshakeLocked(with: sender) }
                return
            }
            if let envelope = try? JSONDecoder().decode(DirectEnvelope.self, from: plaintext) {
                notifyUI { delegate in
                    delegate.mesh(didReceiveDirectEnvelope: envelope, id: packet.messageID, from: sender)
                }
                if envelope.kind == .text,
                   let ack = try? noiseManager.encrypt(packet.messageID.data, for: sender) {
                    let ackPacket = NotePacket(type: .deliveryAck, senderID: myPeerID, payload: sender.data + ack)
                    broadcastLocked(ackPacket)
                }
            } else if let content = String(data: plaintext, encoding: .utf8) {
                notifyUI { delegate in
                    delegate.mesh(didReceiveDirectMessage: content, id: packet.messageID, from: sender)
                }
                if let ack = try? noiseManager.encrypt(packet.messageID.data, for: sender) {
                    let ackPacket = NotePacket(type: .deliveryAck, senderID: myPeerID, payload: sender.data + ack)
                    broadcastLocked(ackPacket)
                }
            } else {
                noiseManager.removeSession(for: sender)
                if myPeerID < sender { initiateHandshakeLocked(with: sender) }
            }

        case .deliveryAck, .readAck:
            guard let plaintext = try? noiseManager.decrypt(Data(packet.directedContent), from: sender),
                  plaintext.count % 16 == 0 else { return }
            let ids = stride(from: 0, to: plaintext.count, by: 16).compactMap {
                MessageID(data: plaintext.subdata(in: plaintext.startIndex + $0..<plaintext.startIndex + $0 + 16))
            }
            let isDelivery = packet.type == .deliveryAck
            notifyUI { delegate in
                if isDelivery {
                    ids.forEach { delegate.mesh(didReceiveDeliveryAck: $0, from: sender) }
                } else {
                    delegate.mesh(didReceiveReadAck: ids, from: sender)
                }
            }

        case .pollCreate:
            guard let payload = PollCreatePayload.decode(from: packet.payload) else { return }
            notifyUI { delegate in
                delegate.mesh(didReceivePoll: payload, from: sender, directPeer: nil)
            }

        case .pollVote:
            guard let payload = PollVotePayload.decode(from: packet.payload) else { return }
            notifyUI { delegate in
                delegate.mesh(didReceivePollVote: payload, from: sender, directPeer: nil)
            }

        case .dmPollCreate:
            guard let payload = PollCreatePayload.decode(from: Data(packet.directedContent)) else { return }
            notifyUI { delegate in
                delegate.mesh(didReceivePoll: payload, from: sender, directPeer: sender)
            }

        case .dmPollVote:
            guard let payload = PollVotePayload.decode(from: Data(packet.directedContent)) else { return }
            notifyUI { delegate in
                delegate.mesh(didReceivePollVote: payload, from: sender, directPeer: sender)
            }

        case .imageFragment, .dmImageFragment:
            let body = packet.type == .dmImageFragment ? Data(packet.directedContent) : packet.payload
            guard let fragment = ImageFragmentPayload.decode(from: body) else { return }
            let directPeer = packet.type == .dmImageFragment ? sender : nil
            switch fragmentAssembler.handleFragment(fragment, from: sender) {
            case .progress(let transferID, let sender, let fraction):
                notifyUI { delegate in
                    delegate.mesh(imageTransferProgress: transferID, from: sender, fraction: fraction, directPeer: directPeer)
                }
            case .complete(let transferID, let sender, let data):
                notifyUI { delegate in
                    delegate.mesh(didReceiveImage: data, transferID: transferID, from: sender, directPeer: directPeer)
                }
            case .ignored:
                break
            }

        case .imageComplete, .dmImageComplete:
            break // reassembly completes when all fragments arrive

        case .fileStart, .dmFileStart:
            let body = packet.type == .dmFileStart ? Data(packet.directedContent) : packet.payload
            guard let payload = FileStartPayload.decode(from: body) else { return }
            let directPeer = packet.type == .dmFileStart ? sender : nil
            fragmentAssembler.registerFileStart(
                transferID: payload.transferID, fileName: payload.fileName, mimeType: payload.mimeType
            )
            notifyUI { delegate in
                delegate.mesh(
                    fileTransferStarted: payload.transferID,
                    fileName: payload.fileName,
                    mimeType: payload.mimeType,
                    from: sender,
                    directPeer: directPeer
                )
            }

        case .fileFragment, .dmFileFragment:
            let body = packet.type == .dmFileFragment ? Data(packet.directedContent) : packet.payload
            guard let fragment = ImageFragmentPayload.decode(from: body) else { return }
            let directPeer = packet.type == .dmFileFragment ? sender : nil
            switch fragmentAssembler.handleFragment(fragment, from: sender) {
            case .progress(let transferID, let sender, let fraction):
                notifyUI { delegate in
                    delegate.mesh(fileTransferProgress: transferID, from: sender, fraction: fraction, directPeer: directPeer)
                }
            case .complete(let transferID, let sender, let data):
                let metadata = fragmentAssembler.consumeFileMetadata(for: transferID)
                    ?? (fileName: "file", mimeType: "application/octet-stream")
                notifyUI { delegate in
                    delegate.mesh(
                        didReceiveFile: data,
                        transferID: transferID,
                        fileName: metadata.fileName,
                        mimeType: metadata.mimeType,
                        from: sender,
                        directPeer: directPeer
                    )
                }
            case .ignored:
                break
            }

        case .fileComplete, .dmFileComplete:
            break
        }
    }

    private func initiateHandshakeLocked(with peerID: PeerID) {
        guard let handshake1 = noiseManager.initiateHandshake(with: peerID) else { return }
        let packet = NotePacket(type: .noiseHandshake1, senderID: myPeerID, payload: peerID.data + handshake1)
        broadcastLocked(packet)
    }

    private func handleHandshakePacketLocked(_ packet: NotePacket) {
        let sender = packet.senderID
        let message = Data(packet.directedContent)
        let isInitiation = packet.type == .noiseHandshake1
        // try? flattens the Data?? — nil means error or no response message due.
        guard let responseData = try? noiseManager.handleIncomingHandshake(
            from: sender, message: message, isInitiation: isInitiation
        ) else { return }

        let responseType: PacketType = isInitiation ? .noiseHandshake2 : .noiseHandshake3
        let responsePacket = NotePacket(type: responseType, senderID: myPeerID,
                                        payload: sender.data + responseData)
        broadcastLocked(responsePacket)
    }

    private func handleStaleImageTransfersLocked() {
        let abandoned = fragmentAssembler.pruneStale()
        guard !abandoned.isEmpty else { return }
        notifyUI { delegate in delegate.mesh(didAbandonImageTransfers: abandoned) }
    }

    // MARK: - Delegate marshaling

    private func notifyUI(_ block: @escaping @MainActor (MeshDelegate) -> Void) {
        Task { @MainActor [weak self] in
            guard let delegate = self?.delegate else { return }
            block(delegate)
        }
    }

    // MARK: - Scanning / Advertising

    private func startScanning() {
        guard let central = centralManager, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startAdvertising() {
        guard let peripheral = peripheralManager, peripheral.state == .poweredOn, !peripheral.isAdvertising else { return }
        // Service UUID only — no local name, matching bitchat's privacy posture.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }
}

// MARK: - CBCentralManagerDelegate

extension MeshService: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for peripheral in restored {
            peripheral.delegate = self
            var link = peripheralLinks[peripheral.identifier] ?? PeripheralLink(peripheral: peripheral)
            link.isConnected = peripheral.state == .connected
            link.isConnecting = peripheral.state == .connecting
            peripheralLinks[peripheral.identifier] = link
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        publishBluetoothStateLocked()

        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .unauthorized:
            central.stopScan()
            for (_, link) in peripheralLinks {
                central.cancelPeripheralConnection(link.peripheral)
            }
            peripheralLinks.removeAll()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        if let existing = peripheralLinks[id], existing.isConnected || existing.isConnecting { return }
        let activeLinks = peripheralLinks.values.filter { $0.isConnected || $0.isConnecting }.count
        guard activeLinks < Self.maxCentralLinks else { return }

        peripheral.delegate = self
        var link = PeripheralLink(peripheral: peripheral)
        link.isConnecting = true
        peripheralLinks[id] = link
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheralLinks[peripheral.identifier]?.isConnecting = false
        peripheralLinks[peripheral.identifier]?.isConnected = true
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripheralLinks.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripheralLinks.removeValue(forKey: peripheral.identifier)
        // Restart scan so the peer is rediscovered quickly.
        if central.state == .poweredOn {
            central.stopScan()
            bleQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MeshService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) else { return }
        peripheralLinks[peripheral.identifier]?.characteristic = characteristic
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        // Introduce ourselves on the new link.
        bleQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendAnnounceLocked(force: true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        let id = peripheral.identifier
        guard var link = peripheralLinks[id] else { return }
        let packets = link.assembler.append(data)
        peripheralLinks[id] = link
        for packet in packets {
            handlePacket(packet, fromPeripheral: id, fromCentral: nil)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainPendingWrites(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) {
            peripheralLinks[peripheral.identifier]?.characteristic = nil
            peripheral.discoverServices([Self.serviceUUID])
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension MeshService: CBPeripheralManagerDelegate {

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let restoredServices = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        if characteristic == nil,
           let service = restoredServices.first(where: { $0.uuid == Self.serviceUUID }),
           let restored = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) as? CBMutableCharacteristic {
            characteristic = restored
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peripheralState = peripheral.state
        publishBluetoothStateLocked()

        switch peripheral.state {
        case .poweredOn:
            peripheral.removeAllServices()
            let mutableCharacteristic = CBMutableCharacteristic(
                type: Self.characteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse, .read],
                value: nil,
                permissions: [.readable, .writeable]
            )
            characteristic = mutableCharacteristic
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [mutableCharacteristic]
            peripheral.add(service)
        case .poweredOff, .unauthorized:
            peripheral.stopAdvertising()
            subscribedCentrals.removeAll()
            centralAssemblers.removeAll()
            centralPeerBindings.removeAll()
            characteristic = nil
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals[central.identifier] = central
        bleQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendAnnounceLocked(force: true)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        centralAssemblers.removeValue(forKey: central.identifier)
        centralPeerBindings.removeValue(forKey: central.identifier)
        if !peripheral.isAdvertising {
            startAdvertising()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainPendingNotifications()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Respond immediately — the central times out within milliseconds.
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        // Long writes arrive as multiple requests with offsets; feed them to
        // the per-central stream assembler in offset order.
        let grouped = Dictionary(grouping: requests) { $0.central.identifier }
        for (centralID, group) in grouped {
            if subscribedCentrals[centralID] == nil, let central = group.first?.central {
                subscribedCentrals[centralID] = central
            }
            var assembler = centralAssemblers[centralID] ?? PacketStreamAssembler()
            var packets: [NotePacket] = []
            for request in group.sorted(by: { $0.offset < $1.offset }) {
                guard let value = request.value, !value.isEmpty else { continue }
                packets.append(contentsOf: assembler.append(value))
            }
            centralAssemblers[centralID] = assembler
            for packet in packets {
                handlePacket(packet, fromPeripheral: nil, fromCentral: centralID)
            }
        }
    }
}
