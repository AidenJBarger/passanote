import SwiftUI

/// Polls render as sticky notes pinned into the feed — same paper language
/// as the nickname note from the Figma design. Tap an option to vote (once,
/// anonymous); live results replace the buttons.
struct PollCardView: View {
    let model: ChatViewModel
    let pollID: MessageID
    var isMine: Bool = false

    private var poll: Poll? {
        model.polls[pollID]
    }

    var body: some View {
        if let poll {
            VStack(alignment: .leading, spacing: 10) {
                Text(poll.question)
                    .font(.title3)
                    .foregroundStyle(Theme.inkOnNote)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(poll.options.indices, id: \.self) { index in
                    if poll.myVote == nil {
                        Button {
                            withAnimation(.snappy) {
                                model.vote(pollID: poll.pollID, optionIndex: index)
                            }
                        } label: {
                            Text(poll.options[index])
                                .font(.subheadline)
                                .foregroundStyle(Theme.inkOnNote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                                .padding(.horizontal, 12)
                                .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(poll.options[index])
                                    .font(.subheadline)
                                    .fontWeight(poll.myVote == index ? .semibold : .regular)
                                if poll.myVote == index {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                                Spacer()
                                Text("\(poll.votes[index] ?? 0)")
                                    .font(.caption)
                                    .opacity(0.7)
                            }
                            .foregroundStyle(Theme.inkOnNote)
                            ProgressView(value: poll.fraction(for: index))
                                .tint(Theme.inkOnNote)
                        }
                    }
                }

                Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s") · anonymous")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkOnNote.opacity(0.6))
            }
            .padding(20)
            .frame(width: 264)
            .background {
                Rectangle()
                    .fill(Theme.note)
                    .shadow(color: Theme.note.opacity(0.35), radius: 4, y: 2)
            }
            .rotationEffect(.degrees(isMine ? 1.2 : -1.2))
            .padding(.vertical, 6)
        }
    }
}

/// Sheet for creating a poll: a question plus 2–4 options.
struct PollComposerView: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var options = ["", ""]

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask the room…", text: $question)
                }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { index in
                        TextField("Option \(index + 1)", text: $options[index])
                    }
                    if options.count < 4 {
                        Button("Add option", systemImage: "plus") {
                            options.append("")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .paperCanvas()
            .tint(Theme.note)
            .navigationTitle("New Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark") {
                        model.createPoll(question: question, options: options)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canCreate)
                }
            }
        }
    }
}
