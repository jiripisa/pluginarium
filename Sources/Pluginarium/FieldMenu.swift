import PluginariumCore
import SwiftUI

/// `.field`: a selector on a dark inset, which opens a menu with the current entry ticked.
struct FieldMenu<Value: Hashable & Sendable>: View {
    private static var fontSize: CGFloat { 14 }

    let title: String
    let options: [RouteOption<Value>]
    let selection: Value
    let select: (Value) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Menu {
            Picker(title, selection: Binding(get: { selection }, set: { select($0) })) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(.panelText(Self.fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
            .foregroundStyle(Color.legend)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelDeep)
            .overlay(Rectangle().strokeBorder(isHovered && isEnabled ? Color.lineStrong : Color.line, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}
