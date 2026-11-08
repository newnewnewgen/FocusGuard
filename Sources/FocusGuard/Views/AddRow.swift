import SwiftUI

/// The "type here to add one" row at the foot of a section. A leading plus, a bordered field,
/// and the trailing controls; clicking anywhere on the row focuses the field, and the button
/// turns prominent as soon as there is something to add.
struct AddRow<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    let buttonTitle: String
    let onSubmit: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, buttonTitle: String = "Add",
         onSubmit: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.placeholder = placeholder
        self._text = text
        self.buttonTitle = buttonTitle
        self.onSubmit = onSubmit
        self.trailing = trailing
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(focused || hasText ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(onSubmit)
            trailing()
            if hasText {
                Button(buttonTitle, action: onSubmit).buttonStyle(.borderedProminent)
            } else {
                Button(buttonTitle, action: onSubmit).buttonStyle(.bordered).disabled(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
