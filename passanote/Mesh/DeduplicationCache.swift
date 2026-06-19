import Foundation

/// Seen-message cache with TTL eviction, used to suppress relay loops.
///
/// Entries expire after 60 seconds; a timer prunes every 30 seconds (per the
/// build plan) and a hard cap of 1000 entries bounds memory, mirroring
/// bitchat's MessageDeduplicator.
///
/// Not internally synchronized — MeshService only touches it from the BLE queue.
final class DeduplicationCache {
    private var seen: Set<String> = []
    private var timestamps: [String: Date] = [:]
    private var insertionOrder: [String] = []
    private let maxAge: TimeInterval
    private let maxCount: Int
    private var pruneTimer: DispatchSourceTimer?

    init(maxAge: TimeInterval = 60, maxCount: Int = 1000, queue: DispatchQueue) {
        self.maxAge = maxAge
        self.maxCount = maxCount
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.prune()
        }
        timer.resume()
        pruneTimer = timer
    }

    deinit {
        pruneTimer?.cancel()
    }

    /// Returns true if the ID was already seen; records it otherwise.
    func isDuplicate(_ id: String) -> Bool {
        if seen.contains(id) { return true }
        seen.insert(id)
        timestamps[id] = Date()
        insertionOrder.append(id)
        trimIfNeeded()
        return false
    }

    /// Record an ID without checking (e.g. our own outgoing messages, so a
    /// relayed copy of our own broadcast is ignored).
    func markProcessed(_ id: String) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        timestamps[id] = Date()
        insertionOrder.append(id)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        while insertionOrder.count > maxCount {
            let oldest = insertionOrder.removeFirst()
            seen.remove(oldest)
            timestamps.removeValue(forKey: oldest)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var kept: [String] = []
        for id in insertionOrder {
            if let stamp = timestamps[id], stamp < cutoff {
                seen.remove(id)
                timestamps.removeValue(forKey: id)
            } else {
                kept.append(id)
            }
        }
        insertionOrder = kept
    }
}
