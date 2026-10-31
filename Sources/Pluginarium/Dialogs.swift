import PluginariumCore
import SwiftUI

/// A question with a few answers, `dialog` of `ui-prototype/app.js`. Tasks that ask the owner
/// something add their dialogs here.
struct ChoiceDialog: Identifiable {
    struct Choice: Identifiable {
        let id = UUID()
        var label: String
        var isPrimary = false
        /// What Escape answers. Without one, the first choice does.
        var isCancel = false
        var action: () -> Void = {}
    }

    let id = UUID()
    var title: String
    var text: String
    /// The primary choice is what Return answers; Escape answers the one that cancels, or else the first.
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

    /// A preset was stored, and the owner decides whether the saved configuration follows.
    static func updateConfiguration(preset: String, configuration: String, save: @escaping () -> Void) -> ChoiceDialog {
        ChoiceDialog(
            title: "Update configuration?",
            text: "\(preset) is saved as a preset. Do you also want to use it in \(configuration)?",
            choices: [
                Choice(label: "Not now"),
                Choice(label: "Save configuration", isPrimary: true, action: save),
            ]
        )
    }
}

extension ChoiceDialog {
    /// `leaveConfig`: asked before the configuration on screen is left behind, or the app quits. Escape cancels,
    /// so it never throws changes away.
    static func saveChanges(
        configuration name: String, dontSave: @escaping () -> Void, cancel: @escaping () -> Void, save: @escaping () -> Void
    ) -> ChoiceDialog {
        ChoiceDialog(
            title: "Save changes?",
            text: SaveFlow.question(forConfigurationNamed: name),
            choices: [
                Choice(label: "Don't save", action: dontSave),
                Choice(label: "Cancel", isCancel: true, action: cancel),
                Choice(label: "Save", isPrimary: true, action: save),
            ]
        )
    }
}

/// A question for a name, `nameDialog` of `ui-prototype/app.js`.
struct NameDialog: Identifiable {
    let id = UUID()
    var title: String
    var label: String
    var value = ""
    var confirmLabel: String
    var note: String?
    var confirm: (String) -> Void
    var cancel: () -> Void = {}
}

extension NameDialog {
    /// A preset is named for its plugin, and starts from the name it has.
    static func savePreset(plugin: String, current: String?, save: @escaping (String) -> Void) -> NameDialog {
        NameDialog(
            title: "Save preset",
            label: "Preset name for \(plugin)",
            value: current ?? "",
            confirmLabel: "Save preset",
            note: "The preset stays available for this plugin in all configurations.",
            confirm: save
        )
    }

    /// A configuration that was never saved is named when it first is.
    static func saveConfiguration(value: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) -> NameDialog {
        NameDialog(title: "Save configuration", label: "Name", value: value, confirmLabel: "Save", confirm: save, cancel: cancel)
    }

    /// Save as starts from the name with "copy" added.
    static func saveAs(value: String, save: @escaping (String) -> Void) -> NameDialog {
        NameDialog(title: "Save as", label: "Name", value: value, confirmLabel: "Save", confirm: save)
    }
}

extension View {
    /// Shows `dialog` over the whole view while it is set, and clears it when a choice is made.
    func choiceDialog(_ dialog: Binding<ChoiceDialog?>) -> some View {
        modifier(ChoiceDialogPresenter(dialog: dialog))
    }

    /// Shows `dialog` over the whole view while it is set, and clears it when it is answered.
    func nameDialog(_ dialog: Binding<NameDialog?>) -> some View {
        disabled(dialog.wrappedValue != nil)
            .accessibilityHidden(dialog.wrappedValue != nil)
            .overlay {
                if let name = dialog.wrappedValue {
                    ZStack {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                        NameDialogBox(dialog: name) { answer in
                            // Return reaches both the field and the default button.
                            guard dialog.wrappedValue?.id == name.id else { return }
                            dialog.wrappedValue = nil
                            if let answer { name.confirm(answer) } else { name.cancel() }
                        }
                        .id(name.id)
                    }
                }
            }
    }

    /// `.toast`: a line at the bottom of the window that asks nothing.
    func toast(_ text: String?) -> some View {
        overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.panelText(14))
                    .foregroundStyle(Color.panelDeep)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Color.legend)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 22)
                    .allowsHitTesting(false)
            }
        }
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
private struct DialogBox<Content: View>: View {
    private static var titleSize: CGFloat { 27 }

    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.panelDisplay(Self.titleSize))
                .panelSpacing(0.05, size: Self.titleSize)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
                .frame(height: Self.titleSize)
                .padding(.bottom, 10)
            content
        }
        .padding(18)
        .frame(width: 420)
        .background(Color.panel)
        .overlay(Rectangle().strokeBorder(Color.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, y: 20)
        .accessibilityAddTraits(.isModal)
    }
}

private struct ChoiceDialogBox: View {
    let dialog: ChoiceDialog
    let choose: (ChoiceDialog.Choice) -> Void

    var body: some View {
        DialogBox(title: dialog.title) {
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
    }

    private func shortcut(of choice: ChoiceDialog.Choice) -> KeyboardShortcut? {
        if choice.isPrimary { return .defaultAction }
        if choice.isCancel { return .cancelAction }
        return !dialog.choices.contains(where: \.isCancel) && choice.id == dialog.choices.first?.id ? .cancelAction : nil
    }
}

/// The name field takes the focus with its text selected, so typing replaces it. A name with nothing
/// in it cannot be confirmed.
private struct NameDialogBox: View {
    let dialog: NameDialog
    /// Called with the trimmed name, or nil for Cancel.
    let answer: (String?) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(dialog: NameDialog, answer: @escaping (String?) -> Void) {
        self.dialog = dialog
        self.answer = answer
        _text = State(initialValue: dialog.value)
    }

    private var name: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func confirm() {
        if !name.isEmpty { answer(name) }
    }

    var body: some View {
        DialogBox(title: dialog.title) {
            if let note = dialog.note {
                Text(note)
                    .font(.panelText(14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            Legend(dialog.label)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.panelText(14))
                .foregroundStyle(Color.legend)
                .focused($isFocused)
                .onSubmit(confirm)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(Color.panelDeep)
                .overlay {
                    if isFocused {
                        Rectangle().strokeBorder(Color.led, lineWidth: 2)
                    } else {
                        Rectangle().strokeBorder(Color.line, lineWidth: 1)
                    }
                }
                .accessibilityLabel(dialog.label)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { answer(nil) }
                    .buttonStyle(.key)
                    .keyboardShortcut(.cancelAction)
                Button(dialog.confirmLabel, action: confirm)
                    .buttonStyle(KeyButtonStyle.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
            .padding(.top, 16)
        }
        .onAppear { isFocused = true }
    }
}
