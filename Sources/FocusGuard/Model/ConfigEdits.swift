import Foundation
import FocusGuardCore

extension Config {
    mutating func update(list id: UUID, _ change: (inout BlockList) -> Void) {
        guard let i = blockLists.firstIndex(where: { $0.id == id }) else { return }
        change(&blockLists[i])
    }

    mutating func update(window id: UUID, _ change: (inout ScheduleWindow) -> Void) {
        guard let i = schedules.firstIndex(where: { $0.id == id }) else { return }
        change(&schedules[i])
    }

    mutating func removeList(id: UUID) {
        blockLists.removeAll { $0.id == id }
        for i in schedules.indices { schedules[i].blockListIDs.removeAll { $0 == id } }
    }

    /// The window the Schedule tab's ghost row adds: weekdays 09:00–12:00, attached to the
    /// default list (the first one) and to nothing when there is no list yet (UI polish spec §6).
    func newWindow() -> ScheduleWindow {
        ScheduleWindow(name: "Deep work", days: [.mon, .tue, .wed, .thu, .fri],
                       start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
                       blockListIDs: blockLists.first.map { [$0.id] } ?? [])
    }

    /// Sidebar drag-to-reorder. Only the order of `blockLists` changes — no window's
    /// `blockListIDs` — so `weakens(from:)` is nil and the edit is never gated.
    mutating func moveLists(fromOffsets source: IndexSet, toOffset destination: Int) {
        blockLists.move(fromOffsets: source, toOffset: destination)
    }

    func list(_ id: UUID) -> BlockList? { blockLists.first { $0.id == id } }
    func window(_ id: UUID) -> ScheduleWindow? { schedules.first { $0.id == id } }
}
