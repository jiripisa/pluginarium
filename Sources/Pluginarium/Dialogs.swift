import SwiftUI

/// A question with a few answers, `dialog` of `ui-prototype/app.js`. Tasks that ask the owner
/// something add their dialogs here.
struct ChoiceDialog: Identifiable {
    struct Choice: Identifiable {
        let id = UUID()
        var label: String
        var isPrimary = false
        var action: () -> Void = {}
    }

    let id = UUID()
    var title: String
    var text: String
    /// The first choice is also what Escape answers; the primary one is what Return answers.
    var choices: [Choice]
}

extension ChoiceDialog {
    /// Removing is asked about before anything goes.
    static func removeChannel(named name: String, remove: @escaping () -> Void) -> ChoiceDialog {
        ChoiceDialog(
            title: "Remove channel?",
            text: "\(name) and its effects will be removed from this configuration.",
            choices: [
                Choice(label: "Cancel"),
                Choice(label: "Remove", isPrimary: true, action: remove),
            ]
        )
    }
}

extension View {
    /// Shows `dialog` over the whole view while it is set, and clears it when a choice is made.
    func choiceDialog(_ dialog: Binding<ChoiceDialog?>) -> some View {
        modifier(ChoiceDialogPresenter(dialog: dialog))
    }
}

private struct ChoiceDialogPresenter: ViewModifier {
    @Binding var dialog: ChoiceDialog?

    func body(content: Content) -> some View {
        content
            .disabled(dialog != nil)
            .accessibilityHidden(dialog != nil)
            .overlay {
                if let dialog {
                    ZStack {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                        ChoiceDialogBox(dialog: dialog) { choice in
                            self.dialog = nil
                            choice.action()
                        }
                    }
                }
            }
    }
}

/// `dialog`: 420 pt wide on the panel, with a strong outline.
private struct ChoiceDialogBox: View {
    private static let titleSize: CGFloat = 27

    let dialog: ChoiceDialog
    let choose: (ChoiceDialog.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dialog.title)
                .font(.panelDisplay(Self.titleSize))
                .panelSpacing(0.05, size: Self.titleSize)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
                .frame(height: Self.titleSize)
                .padding(.bottom, 10)
            Text(dialog.text)
                .font(.panelText(14))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(dialog.choices) { choice in
                    Button(choice.label) { self.choose(choice) }
                        .buttonStyle(choice.isPrimary ? KeyButtonStyle.primary : .key)
                        .keyboardShortcut(shortcut(of: choice))
                }
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(width: 420)
        .background(Color.panel)
        .overlay(Rectangle().strokeBorder(Color.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, y: 20)
        .accessibilityAddTraits(.isModal)
    }

    private func shortcut(of choice: ChoiceDialog.Choice) -> KeyboardShortcut? {
        if choice.isPrimary { return .defaultAction }
        return choice.id == dialog.choices.first?.id ? .cancelAction : nil
    }
}
