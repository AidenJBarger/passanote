import SwiftUI
import PhotosUI
import CoreBluetooth
import UniformTypeIdentifiers
import UIKit

// MARK: - Thread list

/// Open 1:1 conversations plus everyone nearby — tap a person to start or
/// resume a private chat.
struct DMListView: View {
    let model: ChatViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                messagesSection
                nearbySection
                aboutSection
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .tint(Theme.note)
        .paperCanvas()
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Messages")

            if model.direct.sortedThreads.isEmpty {
                emptyRow("No private messages yet. Tap someone nearby to start one.")
            } else {
                ForEach(model.direct.sortedThreads) { thread in
                    NavigationLink(value: RoomRoute.dmThread(thread.peerID)) {
                        threadRow(thread)
                    }
                    .buttonStyle(.plain)
                    .badge(thread.unreadCount)
                }
            }
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Nearby (\(model.peers.activeCount))")

            if model.peers.sortedPeers.isEmpty {
                emptyRow("No one yet — make sure Bluetooth is on.")
            } else {
                ForEach(model.peers.sortedPeers) { peer in
                    NavigationLink(value: RoomRoute.dmThread(peer.peerID)) {
                        peerRow(peer)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("About the app")

            NavigationLink(value: RoomRoute.features) {
                aboutRow("Features")
            }
            .buttonStyle(.plain)

            Link(destination: PassANoteLinks.privacyPolicy) {
                aboutRow("Privacy Policy")
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.sectionFont)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.bottom, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.secondaryFont)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.vertical, Theme.listRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func threadRow(_ thread: DirectThread) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: Theme.listRowLineSpacing) {
                Text(model.peers.nickname(for: thread.peerID))
                    .font(Theme.nameFont)
                    .foregroundStyle(Theme.ink)
                if let last = thread.lastMessage {
                    Text(previewText(for: last))
                        .font(Theme.secondaryFont)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let last = thread.lastMessage {
                Text(last.timestamp, style: .time)
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.inkSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, Theme.listRowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func previewText(for message: NoteMessage) -> String {
        switch message.kind {
        case .text: return message.content
        case .image: return "Photo"
        case .file: return message.fileName ?? message.content
        case .poll: return "Poll"
        }
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(peer.isActive ? Theme.note : Theme.inkSecondary.opacity(0.35))
                .frame(width: 10, height: 10)
            Text(peer.nickname)
                .font(Theme.nameFont)
                .foregroundStyle(Theme.ink)
            Spacer()
            if peer.noiseState == .established {
                Image(systemName: "lock.fill")
                    .font(Theme.secondaryFont)
                    .foregroundStyle(Theme.note)
            }
        }
        .padding(.vertical, Theme.listRowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func aboutRow(_ title: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(Theme.nameFont)
                .foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(Theme.metaFont.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary.opacity(0.5))
        }
        .padding(.vertical, Theme.listRowVerticalPadding)
        .contentShape(Rectangle())
    }
}

// MARK: - Thread

/// One end-to-end encrypted conversation with receipt indicators, using the
/// same bubble language and interactions as the room.
struct DMThreadView: View {
    let model: ChatViewModel
    let peerID: PeerID
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    private var thread: DirectThread {
        model.direct.thread(for: peerID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !model.sessionEstablished(with: peerID) {
                        Label("securing connection…", systemImage: "lock.open")
                            .font(Theme.secondaryFont)
                            .foregroundStyle(Theme.inkSecondary)
                            .glassBanner(cornerRadius: 12)
                            .padding(.top, 10)
                            .padding(.bottom, 14)
                    }
                    ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRowView(
                            model: model,
                            message: message,
                            context: .direct(peerID: peerID),
                            showsHeader: showsMessageHeader(at: index),
                            isGrouped: isGroupedWithPrevious(at: index),
                            showsFooter: !isGroupedWithNext(at: index)
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, Theme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: thread.messages.count) {
                if let last = thread.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .paperCanvas()
        .tint(Theme.note)
        .safeAreaBar(edge: .bottom, spacing: 12) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(model.peers.nickname(for: peerID))
                        .font(Theme.navTitleFont)
                        .foregroundStyle(Theme.ink)
                    if model.sessionEstablished(with: peerID) {
                        Image(systemName: "lock.fill")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.note)
                    }
                }
            }
        }
        .onAppear {
            model.ensureSession(with: peerID)
            model.direct.markThreadRead(peerID)
        }
        .onDisappear {
            model.direct.closeThread()
        }
    }

    private func isGroupedWithPrevious(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return MessageGrouping.areGrouped(thread.messages[index - 1], thread.messages[index])
    }

    private func isGroupedWithNext(at index: Int) -> Bool {
        guard index + 1 < thread.messages.count else { return false }
        return MessageGrouping.areGrouped(thread.messages[index], thread.messages[index + 1])
    }

    private func showsMessageHeader(at index: Int) -> Bool {
        !isGroupedWithPrevious(at: index)
    }

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
                }
            ]
        ) {
            if let reply = model.direct.replyTarget {
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
                    model.direct.sendImage(image, to: peerID)
                }
            }
        }
    }

    private func replyBanner(_ reply: NoteMessage) -> some View {
        HStack {
            Text("replying to \(reply.senderNickname): \(replyPreview(for: reply))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.direct.replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .glassBannerCapsule()
        .padding(.horizontal, 16)
    }

    private func replyPreview(for message: NoteMessage) -> String {
        switch message.kind {
        case .text: return message.content
        case .image: return "an image"
        case .file: return message.fileName ?? "a file"
        case .poll: return message.content
        }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.direct.send(trimmed, to: peerID)
        draft = ""
    }

    private func importFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= FileUtils.maxTransferBytes else { return }
        model.direct.sendFile(
            data: data,
            fileName: url.lastPathComponent,
            mimeType: FileUtils.mimeType(for: url),
            to: peerID
        )
    }
}
