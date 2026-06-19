import SwiftUI

/// Shared grouping rule for the room feed and DM threads.
enum MessageGrouping {
    static func areGrouped(_ previous: NoteMessage, _ current: NoteMessage) -> Bool {
        guard previous.kind != .poll, current.kind != .poll else { return false }
        guard previous.senderID == current.senderID else { return false }
        return Calendar.current.isDate(
            previous.timestamp,
            equalTo: current.timestamp,
            toGranularity: .minute
        )
    }
}

/// Where a message row is rendered — room feed or a 1:1 thread.
enum MessageRowContext {
    case room(onOpenDM: (PeerID) -> Void)
    case direct(peerID: PeerID)
}

/// One entry in the room feed or a DM thread: glowing note-blue bubbles on
/// the right for me, dark blue with a matching glow on the left for others.
/// Polls render as sticky notes instead of bubbles.
struct MessageRowView: View {
    let model: ChatViewModel
    let message: NoteMessage
    let context: MessageRowContext
    var showsHeader = true
    var isGrouped = false
    var showsFooter = true

    @State private var showsActions = false

    private static let quickReactions = ["👍", "❤️", "😂", "‼️"]
    private static let bubbleMaxWidth: CGFloat = 280

    private var isMine: Bool { message.isMine }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            if showsHeader && message.kind != .poll {
                header
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
                if showsActions && message.kind != .poll {
                    reactionPicker
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if message.kind == .poll {
                    content
                } else {
                    interactiveContent
                }

                if showsActions && message.kind != .poll {
                    messageActions
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if !message.reactions.isEmpty {
                reactionsRow
            }

            if showsReceiptFooter {
                receiptFooter
            }
        }
        .padding(.top, isGrouped ? 4 : 14)
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .animation(.snappy, value: showsActions)
    }

    private var showsReceiptFooter: Bool {
        guard showsFooter, isMine, case .direct = context else { return false }
        return true
    }

    private var displayName: String {
        isMine ? model.nickname : message.senderNickname
    }

    @ViewBuilder
    private var header: some View {
        switch context {
        case .room:
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSecondary.opacity(0.6))
            }
            .padding(.leading, isMine ? 0 : 6)
            .padding(.trailing, isMine ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        case .direct:
            if !isMine {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSecondary.opacity(0.6))
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var receiptFooter: some View {
        HStack(spacing: 4) {
            Text(message.timestamp, style: .time)
            receiptIcon(message.receiptState)
        }
        .font(Theme.metaFont)
        .foregroundStyle(Theme.inkSecondary.opacity(0.6))
        .padding(.horizontal, 6)
    }

    // MARK: - Content

    private var interactiveContent: some View {
        content
            .contentShape(Rectangle())
            .scaleEffect(showsActions ? 1.02 : 1)
            .onLongPressGesture(minimumDuration: 0.35) {
                showsActions = true
            }
            .onTapGesture {
                if showsActions {
                    showsActions = false
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            textBubble
        case .image:
            imageBubble
        case .file:
            fileBubble
        case .poll:
            if model.polls[message.id] != nil {
                PollCardView(model: model, pollID: message.id, isMine: isMine)
            }
        }
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyToID = message.replyToID {
                replyQuote(replyToID)
            }
            Text(styledContent)
                .font(.subheadline)
                .foregroundStyle(Theme.bubbleForeground(isMine: isMine))
        }
        .noteBubble(isMine: isMine)
        .frame(maxWidth: Self.bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
    }

    private func replyQuote(_ replyToID: MessageID) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Theme.bubbleForeground(isMine: isMine).opacity(0.6))
                .frame(width: 2)
            Group {
                if let original = referencedMessage(replyToID) {
                    Text("\(original.senderNickname): \(replyPreview(for: original))")
                } else {
                    Text("earlier message")
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.bubbleForeground(isMine: isMine).opacity(0.8))
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private var imageBubble: some View {
        if let data = message.imageData, let image = UIImage(data: data) {
            let size = Self.displaySize(
                for: image,
                maxWidth: Self.bubbleMaxWidth,
                maxHeight: 280
            )
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .imageMessageStyle(isMine: isMine)
        } else {
            HStack(spacing: 8) {
                ProgressView(value: message.transferProgress ?? 0)
                    .frame(width: 110)
                    .tint(Theme.bubbleForeground(isMine: isMine).opacity(0.8))
                Text("\(Int((message.transferProgress ?? 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(Theme.bubbleForeground(isMine: isMine))
            }
            .noteBubble(isMine: isMine)
        }
    }

    @ViewBuilder
    private var fileBubble: some View {
        if let data = message.fileData {
            HStack(spacing: 12) {
                Image(systemName: fileIconName)
                    .font(.title2)
                    .foregroundStyle(Theme.bubbleForeground(isMine: isMine).opacity(isMine ? 1 : 0.9))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.fileName ?? "file")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.bubbleForeground(isMine: isMine))
                        .lineLimit(2)
                    Text(FileUtils.formattedSize(data.count))
                        .font(.caption)
                        .foregroundStyle(Theme.bubbleForeground(isMine: isMine).opacity(0.8))
                }
            }
            .noteBubble(isMine: isMine)
            .frame(maxWidth: Self.bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .foregroundStyle(Theme.bubbleForeground(isMine: isMine))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.fileName ?? "file")
                        .font(.subheadline)
                        .foregroundStyle(Theme.bubbleForeground(isMine: isMine))
                        .lineLimit(1)
                    ProgressView(value: message.transferProgress ?? 0)
                        .frame(width: 120)
                        .tint(Theme.bubbleForeground(isMine: isMine).opacity(0.8))
                }
            }
            .noteBubble(isMine: isMine)
            .frame(maxWidth: Self.bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
        }
    }

    private var fileIconName: String {
        let ext = (message.fileName as NSString?)?.pathExtension.lowercased() ?? ""
        switch ext {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar": return "doc.zipper"
        case "mp3", "wav", "m4a": return "waveform"
        case "mp4", "mov": return "film"
        case "txt", "md": return "doc.text"
        default: return "doc.fill"
        }
    }

    private func replyPreview(for message: NoteMessage) -> String {
        switch message.kind {
        case .text: return message.content
        case .image: return "an image"
        case .file: return message.fileName ?? "a file"
        case .poll: return message.content
        }
    }

    // MARK: - Actions

    private var reactionPicker: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button {
                        sendReaction(emoji)
                        showsActions = false
                    } label: {
                        Text(emoji)
                            .font(.title3)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("React with \(emoji)")
                }
            }
        }
    }

    private var messageActions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                actionButton(title: "Reply", systemImage: "arrowshape.turn.up.left") {
                    setReplyTarget()
                    showsActions = false
                }

                if canSaveAttachment {
                    actionButton(title: "Save", systemImage: "square.and.arrow.down") {
                        saveAttachment()
                        showsActions = false
                    }
                }

                if case .room(let onOpenDM) = context, !isMine {
                    actionButton(title: "Message", systemImage: "envelope") {
                        onOpenDM(message.senderID)
                        showsActions = false
                    }
                }
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(Theme.note)
    }

    private var canSaveAttachment: Bool {
        switch message.kind {
        case .image:
            return message.imageData != nil
        case .file:
            return message.fileData != nil
        default:
            return false
        }
    }

    private func saveAttachment() {
        switch message.kind {
        case .image:
            guard let data = message.imageData, let image = UIImage(data: data) else { return }
            ImageUtils.saveToPhotoLibrary(image)
        case .file:
            guard let data = message.fileData, let name = message.fileName else { return }
            FileUtils.presentSaveSheet(data: data, fileName: name)
        default:
            break
        }
    }

    private var reactionsRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, reactors in
                    Button {
                        sendReaction(emoji)
                    } label: {
                        Text("\(emoji) \(reactors.count)")
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("\(emoji), \(reactors.count) reactions")
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func receiptIcon(_ state: NoteMessage.ReceiptState?) -> some View {
        switch state {
        case nil:
            Image(systemName: "clock")
        case .sent:
            Image(systemName: "checkmark")
        case .delivered:
            Image(systemName: "checkmark.circle")
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.note)
        }
    }

    private func referencedMessage(_ id: MessageID) -> NoteMessage? {
        switch context {
        case .room:
            return model.message(withID: id)
        case .direct(let peerID):
            return model.direct.message(withID: id, in: peerID)
        }
    }

    private func sendReaction(_ emoji: String) {
        switch context {
        case .room:
            model.sendReaction(emoji, to: message)
        case .direct(let peerID):
            model.direct.sendReaction(emoji, to: message, in: peerID)
        }
    }

    private func setReplyTarget() {
        switch context {
        case .room:
            model.replyTarget = message
        case .direct:
            model.direct.replyTarget = message
        }
    }

    /// Highlights @mentions of known peers (and ourselves) in bold.
    private var styledContent: AttributedString {
        var attributed = AttributedString(message.content)
        var knownNames = Set(model.peers.peers.values.map { $0.nickname.lowercased() })
        knownNames.insert(model.nickname.lowercased())

        guard let regex = try? NSRegularExpression(pattern: "@([\\p{L}\\p{N}_]+)") else { return attributed }
        let text = message.content
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange]).lowercased()
            guard knownNames.contains(name),
                  let attrRange = Range(fullRange, in: attributed) else { continue }
            attributed[attrRange].font = .subheadline.bold()
            attributed[attrRange].underlineStyle = .single
        }
        return attributed
    }

    private static func displaySize(
        for image: UIImage,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return CGSize(width: width * scale, height: height * scale)
    }
}
