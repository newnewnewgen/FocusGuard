import AppKit
import FocusGuardCore
import SwiftUI
import UniformTypeIdentifiers

/// Paste or import a whole list of sites or keywords and add them to a block list in one edit.
struct BulkAddSheet: View {
    enum Kind: String, Identifiable {
        case sites, keywords
        var id: String { rawValue }
    }

    let kind: Kind
    let listName: String
    /// What the list already holds: site names for `.sites`, `KeywordRule.itemKey`s for `.keywords`.
    let existing: Set<String>
    /// Items of this kind across every list in the config, the number the limit applies to.
    let totalInConfig: Int
    /// Called once with the items to append (already filtered against `existing`) and, for
    /// keywords, the match mode for the whole batch.
    let onAdd: ([String], KeywordRule.Match) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var match: KeywordRule.Match = .contains
    @State private var importMessage: String?

    private static let maxImportBytes = 4 * 1024 * 1024

    private var parsed: (accepted: [String], rejected: [String]) {
        switch kind {
        case .sites:
            let r = BulkInput.sites(from: text)
            return (r.accepted, r.rejected)
        case .keywords:
            let r = BulkInput.keywords(from: text)
            return (r.accepted, r.rejected)
        }
    }

    private func key(_ item: String) -> String {
        kind == .sites ? item : KeywordRule(text: item, match: match).itemKey
    }

    private var toAdd: [String] { parsed.accepted.filter { !existing.contains(key($0)) } }
    private var alreadyPresent: Int { parsed.accepted.count - toAdd.count }
    private var skipped: [String] { parsed.rejected }

    private var limit: Int { kind == .sites ? Config.Limits.maxDomains : Config.Limits.maxKeywords }
    private var overLimit: Bool { totalInConfig + toAdd.count > limit }

    private var noun: String { kind == .sites ? "sites" : "keywords" }
    private var title: String { "Add \(noun) to \(listName)" }
    private var placeholder: String {
        switch kind {
        case .sites: return "One per line, or paste a list \u{2014} commas, spaces, URLs and hosts-file lines all work."
        case .keywords: return "One per line or separated by spaces/commas."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Button("Import file\u{2026}", action: importFile)
                if kind == .keywords {
                    Spacer()
                    Picker("Match", selection: $match) {
                        ForEach(KeywordRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                }
            }
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.red)
            }

            preview

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(toAdd.count) \(noun)") {
                    let items = toAdd
                    onAdd(items, match)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(toAdd.isEmpty || overLimit)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(toAdd.count) will be added \u{00B7} \(alreadyPresent) already in the list \u{00B7} \(skipped.count) skipped")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !skipped.isEmpty {
                let shown = skipped.prefix(8).joined(separator: ", ")
                Text("Skipped: " + shown + (skipped.count > 8 ? " +\(skipped.count - 8) more" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if overLimit {
                Text("That would exceed the limit of \(limit) \(noun) in total (you have \(totalInConfig)).")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Import

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text]
        // The content-type filter alone hides extensionless files such as a copied "hosts".
        let delegate = ExtensionlessFriendlyDelegate(types: panel.allowedContentTypes)
        panel.delegate = delegate
        guard panel.runModal() == .OK, let url = panel.url else { return }
        withExtendedLifetime(delegate) {}
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maxImportBytes else {
                importMessage = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); files over 4 MB are not imported."
                return
            }
            let data = try Data(contentsOf: url)
            guard let contents = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                importMessage = "\(url.lastPathComponent) could not be read as text."
                return
            }
            importMessage = nil
            if text.isEmpty || text.hasSuffix("\n") { text += contents } else { text += "\n" + contents }
        } catch {
            importMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Lets the open panel enable text files and files with no extension; everything else stays grey.
private final class ExtensionlessFriendlyDelegate: NSObject, NSOpenSavePanelDelegate {
    let types: [UTType]
    init(types: [UTType]) { self.types = types }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        if url.pathExtension.isEmpty { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }
}
