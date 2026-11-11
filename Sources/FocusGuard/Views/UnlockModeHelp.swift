import FocusGuardCore
import SwiftUI

/// The `info.circle` popover beside a window's unlock-mode control (UI polish spec §1): one
/// page per mode, preselected to the window's own. Friction shows the real `ChallengeSheet` in
/// preview mode; Impossible shows the real locked controls. Live views, not images: they follow
/// the real views when those change and honour the current appearance.
struct UnlockModeHelp: View {
    @State private var page: UnlockMode

    /// Ten words from `Challenge.words`, so it looks like a sentence the real sheet would draw.
    static let sampleSentence = "quiet river seven green bottle garden morning silver window travel"
    private static let sampleUntil = TimeOfDay("20:00")!

    init(mode: UnlockMode) {
        _page = State(initialValue: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Unlock mode", selection: $page) {
                ForEach(UnlockMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch page {
            case .basic:
                Text("Changes apply at once, even while the window is active.")
            case .friction:
                Text("While the window is active, weakening it (removing a site, ending it early, turning it off) first asks you to type a sentence. Paste and autocorrect do not work.")
                ChallengeSheet(challenge: PendingChallenge(sentence: Self.sampleSentence) {}, dismiss: {}, isPreview: true)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
            case .impossible:
                Text("While the window is active nothing can weaken it, not even you. Edits that would are held by the daemon until the window ends. Only `sudo` on the command line gets around it.")
                lockedPreview
            }
        }
        .padding(20)
        .frame(width: 600)   // 560 of content, the sheet's own width
    }

    /// A Block Lists row and a Schedule row as they look under an active Impossible window, built
    /// from the same `RemoveButton` and `ProtectionBadge` the real tabs use.
    private var lockedPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("reddit.com")
                Spacer()
                RemoveButton(locked: true, lockedHelp: "Locked until \(Self.sampleUntil.string)") {}
            }
            Divider()
            HStack {
                TextField("Window name", text: .constant("Deep work")).textFieldStyle(.roundedBorder).frame(width: 180).disabled(true)
                Toggle("Enabled", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().disabled(true)
                ProtectionBadge(mode: .impossible, until: Self.sampleUntil)
                Spacer()
                Button(role: .destructive) {} label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(true)
            }
            Text("Remove and delete are disabled; their tooltip says until when.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}
