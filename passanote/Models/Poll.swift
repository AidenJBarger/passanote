import Foundation

/// A live poll. Votes are anonymous — only counts are tracked.
struct Poll: Identifiable, Equatable {
    let pollID: MessageID
    let question: String
    let options: [String]
    let creatorPeerID: PeerID
    var votes: [Int: Int] = [:]     // optionIndex → count
    var myVote: Int?                // local only; disables re-voting

    var id: String { pollID.id }

    var totalVotes: Int {
        votes.values.reduce(0, +)
    }

    func fraction(for optionIndex: Int) -> Double {
        let total = totalVotes
        guard total > 0 else { return 0 }
        return Double(votes[optionIndex] ?? 0) / Double(total)
    }
}
