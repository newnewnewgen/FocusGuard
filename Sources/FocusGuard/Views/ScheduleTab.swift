import FocusGuardCore
import SwiftUI

struct ScheduleTab: View {
    @Environment(AppModel.self) private var model

    private var windows: [ScheduleWindow] { model.config?.schedules ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if windows.isEmpty {
                ContentUnavailableView("No schedule yet", systemImage: "calendar",
                                       description: Text("Add a window: the days and hours when your lists are blocked."))
            } else {
                List(windows) { w in
                    WindowRow(window: w).padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Button("Add window") { addWindow() }
                Spacer()
                Text("Unlock mode controls how hard it is to weaken a window while it is active: Basic applies at once, Friction asks you to type a sentence, Impossible waits for the window to end.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380)
            }
            .padding()
        }
        .disabled(model.config == nil)
    }

    private func addWindow() {
        let lists = model.config?.blockLists.map(\.id) ?? []
        let w = ScheduleWindow(name: "Deep work", days: [.mon, .tue, .wed, .thu, .fri],
                               start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists)
        model.apply { $0.schedules.append(w) }
    }
}

struct WindowRow: View {
    @Environment(AppModel.self) private var model
    let window: ScheduleWindow
    @State private var name = ""
    /// Bumped on every refused edit; `.id(refused)` rebuilds the AppKit-backed controls (switch,
    /// segmented picker, date pickers) from the saved config so the refusal visibly snaps back.
    @State private var refused = 0

    private var mode: UnlockMode? { model.mode(forWindow: window.id) }
    /// Impossible and active: only name, adding lists, and extending the end are allowed.
    private var hardLocked: Bool { mode == .impossible }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Window name", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { commit { $0.update(window: window.id) { $0.name = name } } }
                Toggle("Enabled", isOn: binding(\.enabled)).toggleStyle(.switch).labelsHidden()
                    .disabled(hardLocked)
                if hardLocked { LockBadge(until: model.lockState.lockedUntil) }
                else if mode != nil { Label("Active", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(role: .destructive) { commit { $0.schedules.removeAll { $0.id == window.id } } } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).disabled(hardLocked)
            }
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(Weekday.allCases, id: \.self) { day in
                        Toggle(day.rawValue.prefix(1).uppercased(), isOn: dayBinding(day))
                            .toggleStyle(.button).controlSize(.small)
                    }
                }.disabled(hardLocked)
                DatePicker("from", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                    .disabled(hardLocked)
                DatePicker("to", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                Picker("Unlock", selection: binding(\.unlockMode)) {
                    ForEach(UnlockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220).disabled(hardLocked)
            }
            HStack(spacing: 10) {
                Text("Lists:").foregroundStyle(.secondary)
                ForEach(model.config?.blockLists ?? []) { list in
                    Toggle(list.name, isOn: listBinding(list.id)).toggleStyle(.checkbox)
                        .disabled(hardLocked && window.blockListIDs.contains(list.id))
                }
                if (model.config?.blockLists ?? []).isEmpty { Text("none yet — create one in Block Lists").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .id(refused)
        .onAppear { name = window.name }
        .onChange(of: window.name) { _, new in name = new }
    }

    /// Every mutation goes through here. A refused edit (challenge pending, locked, or failed)
    /// bumps `refused` so the row is rebuilt from the saved config instead of showing the
    /// control's optimistic new value.
    private func commit(_ edit: @escaping (inout Config) -> Void) {
        switch model.apply(edit) {
        case .applied, .noChange: break
        case .challenge, .locked, .failed: refused += 1
        }
    }

    private func binding<T>(_ key: WritableKeyPath<ScheduleWindow, T>) -> Binding<T> {
        Binding(get: { window[keyPath: key] },
                set: { v in commit { $0.update(window: window.id) { $0[keyPath: key] = v } } })
    }

    private func dayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(get: { window.days.contains(day) },
                set: { on in commit { $0.update(window: window.id) { if on { $0.days.insert(day) } else { $0.days.remove(day) } } } })
    }

    private func listBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { window.blockListIDs.contains(id) },
                set: { on in commit { $0.update(window: window.id) {
                    if on { if !$0.blockListIDs.contains(id) { $0.blockListIDs.append(id) } } else { $0.blockListIDs.removeAll { $0 == id } }
                } } })
    }

    private func timeBinding(_ key: WritableKeyPath<ScheduleWindow, TimeOfDay>) -> Binding<Date> {
        Binding(get: {
            let t = window[keyPath: key]
            return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            guard let t = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0) else { return }
            commit { $0.update(window: window.id) { $0[keyPath: key] = t } }
        })
    }
}
