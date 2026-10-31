// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalArrivalTracker.swift
import Foundation

/// Suppress repeated sound and OS notification events across inbox polls.
/// The bounded ring prevents unbounded growth during long-running sessions.
@MainActor
final class ApprovalArrivalTracker {
    private var seen = Set<String>()
    private var order: [String] = []
    private let limit = 2048

    func newlyObserved(_ items: [ApprovalInboxItem]) -> [ApprovalInboxItem] {
        var arrivals: [ApprovalInboxItem] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            order.append(item.id)
            arrivals.append(item)
        }
        if order.count > limit {
            let removed = order.count - limit
            for id in order.prefix(removed) { seen.remove(id) }
            order.removeFirst(removed)
        }
        return arrivals
    }
}
