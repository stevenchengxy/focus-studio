import Foundation

/// Keeps selection separate from navigation and project content.
struct ProjectLibrarySelection: Equatable {
    private(set) var isSelecting = false
    private(set) var ids: Set<UUID> = []
    private(set) var anchorID: UUID?

    mutating func begin() { isSelecting = true }

    mutating func finish() {
        isSelecting = false
        ids.removeAll()
        anchorID = nil
    }

    mutating func toggle(_ id: UUID, in orderedIDs: [UUID], extendingRange: Bool = false) {
        guard orderedIDs.contains(id) else { return }
        isSelecting = true
        if extendingRange, let anchorID,
           let anchor = orderedIDs.firstIndex(of: anchorID),
           let target = orderedIDs.firstIndex(of: id) {
            ids.formUnion(orderedIDs[min(anchor, target)...max(anchor, target)])
        } else {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchorID = id
        }
    }

    mutating func selectAll(_ orderedIDs: [UUID]) {
        isSelecting = true
        ids = Set(orderedIDs)
        anchorID = orderedIDs.first
    }

    mutating func deselectAll() {
        ids.removeAll()
        anchorID = nil
    }

    mutating func retainExisting(_ orderedIDs: [UUID]) {
        ids.formIntersection(orderedIDs)
        if let anchorID, !orderedIDs.contains(anchorID) { self.anchorID = nil }
    }

    mutating func remove(_ removedIDs: Set<UUID>) {
        ids.subtract(removedIDs)
        if let anchorID, removedIDs.contains(anchorID) { self.anchorID = nil }
    }
}
