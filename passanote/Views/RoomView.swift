import SwiftUI
import PhotosUI
import CoreBluetooth
import UniformTypeIdentifiers

/// The room: a single broadcast feed of everyone nearby, on the design's
/// paper-blue canvas with a floating glass composer pinned at the bottom.
struct RoomView: View {
    @Bindable var model: ChatViewModel
    @State private var path: [RoomRoute] = []
    @State private var draft = ""
    @State private var showPollComposer = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @Namespace private var nicknameTransition
    @Namespace private var dmTransition

    var body: some View {
        NavigationStack(path: $path) {
            feed
                .paperCanvas()
                .safeAreaBar(edge: .bottom, spacing: 12) { composer }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink(value: RoomRoute.nicknameSettings) {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Edit nickname")
                        .tint(Theme.note)
                        .matchedTransitionSource(id: "nickname", in: nicknameTransition)
                    }
                    if model.bluetoothState == .poweredOn {
                        ToolbarItem(placement: .principal) {
                            nearbyStatusLabel
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink(value: RoomRoute.dmList) {
                            Image(systemName: "envelope")
                        }
                        .badge(model.direct.totalUnread)
                        .accessibilityLabel("Private messages")
                        .tint(Theme.note)
                        .matchedTransitionSource(id: "dmList", in: dmTransition)
                    }
                }
                .navigationDestination(for: RoomRoute.self) { route in
                    switch route {
                    case .dmList:
                        DMListView(model: model)
                            .navigationTransition(.zoom(sourceID: "dmList", in: dmTransition))
                    case .dmThread(let peerID):
                        DMThreadView(model: model, peerID: peerID)
                    case .nicknameSettings:
                        NicknameSetupView(model: model) {
                            if !path.isEmpty { path.removeLast() }
                            model.finishNicknameSetup()
                        }
                        .navigationTransition(.zoom(sourceID: "nickname", in: nicknameTransition))
                    case .features:
                        FeaturesView()
                    case .privacyPolicy:
                        PrivacyPolicyView()
                    }
                }
                .sheet(isPresented: $showPollComposer) {
                    PollComposerView(model: model)
                        .presentationDragIndicator(.visible)
                }
        }
        .tint(Theme.note)
        .onAppear {
            if !model.hasNickname && !path.contains(.nicknameSettings) {
                path.append(.nicknameSettings)
            }
        }
        .onChange(of: model.hasNickname) { _, hasNickname in
            if !hasNickname && !path.contains(.nicknameSettings) {
                path.append(.nicknameSettings)
            }
        }
        .onChange(of: path) { _, newPath in
            if !model.hasNickname && !newPath.contains(.nicknameSettings) {
                path.append(.nicknameSettings)
            }
        }
    }

    // MARK: - Feed

    private var feed: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.bluetoothState != .poweredOn && !model.messages.isEmpty {
                            bluetoothBanner
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 14)
                        }
                        if model.messages.isEmpty && model.bluetoothState == .poweredOn {
                            emptyState
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            MessageRowView(
                                model: model,
                                message: message,
                                context: .room { peerID in
                                    path.append(.dmThread(peerID))
                                },
                                showsHeader: showsMessageHeader(at: index),
                                isGrouped: isGroupedWithPrevious(at: index)
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                if model.bluetoothState != .poweredOn && model.messages.isEmpty {
                    bluetoothBanner
                }
            }
        }
    }

    private func isGroupedWithPrevious(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return messagesAreGrouped(model.messages[index - 1], model.messages[index])
    }

    private func showsMessageHeader(at index: Int) -> Bool {
        !isGroupedWithPrevious(at: index)
    }

    private func messagesAreGrouped(_ previous: NoteMessage, _ current: NoteMessage) -> Bool {
        MessageGrouping.areGrouped(previous, current)
    }

    private var bluetoothBanner: some View {
        Button {
            model.handleBluetoothPermissionAction()
        } label: {
            Label("Allow Bluetooth to chat", systemImage: "exclamationmark.triangle")
                .font(.footnote)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.note)
        .accessibilityLabel("Allow Bluetooth to chat")
    }

    private var nearbyStatusLabel: some View {
        Group {
            if model.peers.activeCount == 0 {
                RippleText(text: "looking for people nearby…", font: .footnote)
            } else {
                let count = model.peers.activeCount
                let label = count == 1 ? "1 person nearby" : "\(count) people nearby"
                RippleText(text: label, font: .footnote)
            }
        }
    }

    private var emptyState: some View {
        PassANoteGuideView()
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Composer

    private var composer: some View {
        ChatComposerView(
            draft: $draft,
            placeholder: "Pass a note…",
            sendAccessibilityLabel: "Send message",
            onSend: send,
            attachments: [
                ChatComposerAttachment(title: "Photo", systemImage: "photo") {
                    showPhotoPicker = true
                },
                ChatComposerAttachment(title: "File", systemImage: "doc") {
                    showFilePicker = true
                },
                ChatComposerAttachment(title: "Poll", systemImage: "chart.bar") {
                    showPollComposer = true
                }
            ]
        ) {
            if let reply = model.replyTarget {
                replyBanner(reply)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFile(from: url)
            case .failure:
                break
            }
        }
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    model.sendImage(image)
                }
            }
        }
    }

    private func replyBanner(_ reply: NoteMessage) -> some View {
        HStack {
            Text("replying to \(reply.senderNickname): \(reply.content)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .glassBannerCapsule()
        .padding(.horizontal, 16)
    }

    private func send() {
        model.sendMessage(draft)
        draft = ""
    }

    private func importFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= FileUtils.maxTransferBytes else { return }
        model.sendFile(
            data: data,
            fileName: url.lastPathComponent,
            mimeType: FileUtils.mimeType(for: url)
        )
    }
}

/// Sweeps a note-blue highlight across secondary ink text.
private struct RippleText: View {
    let text: String
    var font: Font = .body

    var body: some View {
        TimelineView(.animation) { timeline in
            let period = 2.4
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period

            Text(text)
                .font(font)
                .foregroundStyle(Theme.inkSecondary)
                .overlay {
                    Text(text)
                        .font(font)
                        .foregroundStyle(Theme.note)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                let rippleWidth = max(geo.size.width * 0.5, 48)
                                let x = (geo.size.width + rippleWidth) * progress - rippleWidth

                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.clear, .white, .white, .clear],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: rippleWidth)
                                    .offset(x: x)
                            }
                        }
                }
        }
    }
}

/// Navigation destinations inside the room's NavigationStack.
enum RoomRoute: Hashable {
    case dmList
    case dmThread(PeerID)
    case nicknameSettings
    case features
    case privacyPolicy
}
#Preview {
    ContentView()
}
