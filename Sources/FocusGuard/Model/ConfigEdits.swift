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

    func list(_ id: UUID) -> BlockList? { blockLists.first { $0.id == id } }
    func window(_ id: UUID) -> ScheduleWindow? { schedules.first { $0.id == id } }
}
