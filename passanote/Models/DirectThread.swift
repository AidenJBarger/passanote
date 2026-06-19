import Foundation

/// One 1:1 encrypted conversation. Memory only.
struct DirectThread: Identifiable {
    let peerID: PeerID
    var messages: [NoteMessage] = []
    var unreadCount: Int = 0

    var id: String { peerID.id }

    var lastMessage: NoteMessage? {
        messages.last
    }
}
