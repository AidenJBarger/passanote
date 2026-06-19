import SwiftUI

struct ChatComposerAttachment: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
}

/// Shared plus / text field / send row for the room feed and DM threads.
struct ChatComposerView<Banners: View>: View {
    @Binding var draft: String
    @FocusState private var isFocused: Bool
    let placeholder: String
    let sendAccessibilityLabel: String
    let onSend: () -> Void
    var attachments: [ChatComposerAttachment] = []
    @ViewBuilder var banners: () -> Banners

    init(
        draft: Binding<String>,
        placeholder: String,
        sendAccessibilityLabel: String,
        onSend: @escaping () -> Void,
        attachments: [ChatComposerAttachment] = [],
        @ViewBuilder banners: @escaping () -> Banners
    ) {
        _draft = draft
        self.placeholder = placeholder
        self.sendAccessibilityLabel = sendAccessibilityLabel
        self.onSend = onSend
        self.attachments = attachments
        self.banners = banners
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            banners()

            HStack(spacing: 10) {
                attachmentButton
                textField
                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var attachmentButton: some View {
        Group {
            if attachments.isEmpty {
                attachmentLabel
            } else {
                Menu {
                    ForEach(attachments) { attachment in
                        Button(action: attachment.action) {
                            Label(attachment.title, systemImage: attachment.systemImage)
                        }
                    }
                } label: {
                    attachmentLabel
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Attachments")
        .tint(Theme.note)
        .controlSize(.large)
        .disabled(attachments.isEmpty)
    }

    private var attachmentLabel: some View {
        Image(systemName: "plus")
            .fontWeight(.bold)
            .padding(4)
    }

    private var textField: some View {
        TextField(placeholder, text: $draft)
            .font(.body)
            .focused($isFocused)
            .onSubmit(sendMessage)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .glassEffect(.regular, in: .capsule)
    }

    private var sendButton: some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .fontWeight(.semibold)
                .padding(4)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .tint(Theme.note)
        .accessibilityLabel(sendAccessibilityLabel)
        .disabled(!canSend)
    }

    private func sendMessage() {
        guard canSend else { return }
        onSend()
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}

extension ChatComposerView where Banners == EmptyView {
    init(
        draft: Binding<String>,
        placeholder: String,
        sendAccessibilityLabel: String,
        onSend: @escaping () -> Void,
        attachments: [ChatComposerAttachment] = []
    ) {
        self.init(
            draft: draft,
            placeholder: placeholder,
            sendAccessibilityLabel: sendAccessibilityLabel,
            onSend: onSend,
            attachments: attachments,
            banners: { EmptyView() }
        )
    }
}
