import Foundation

struct StatisticsTimelineSelection {
    private(set) var isCheckboxMode = false
    private(set) var eventIDs = Set<UUID>()

    mutating func enterCheckboxMode() {
        isCheckboxMode = true
    }

    mutating func leaveCheckboxMode() {
        isCheckboxMode = false
    }

    mutating func setCheckboxSelection(_ selected: Bool, for eventID: UUID) {
        guard isCheckboxMode else { return }
        if selected {
            eventIDs.insert(eventID)
        } else {
            eventIDs.remove(eventID)
        }
    }

    mutating func setRowSelection(_ eventIDs: [UUID]) {
        guard !isCheckboxMode else { return }
        self.eventIDs = Set(eventIDs)
    }

    mutating func clear() {
        isCheckboxMode = false
        eventIDs.removeAll()
    }
}
