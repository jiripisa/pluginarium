import PluginariumCore
import SwiftUI

/// `.fx-row`: the effects of one row side by side, joined by split and merge lines when there is
/// more than one.
struct EffectRow: View {
    let channel: Channel
    let row: [InsertEffect]

    @Environment(AppModel.self) private var model

    private var isParallel: Bool { row.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(row) { effect in
                    EffectSlot(channel: channel.id, effect: effect, failure: model.audio?.runner?.failure(effect: effect.id))
                }
            }
            ForEach(row.filter { $0.sidechainIn != nil }) { effect in
                if let source = effect.sidechainIn {
                    Text("Sidechain from \(source.label(prefix: "In"))")
                        .font(.panelText(12))
                        .foregroundStyle(Color.muted)
                }
            }
        }
        .padding(.vertical, isParallel ? 7 : 0)
        .background {
            if isParallel { SplitAndMergeLines().stroke(Color.lineStrong, lineWidth: 1) }
        }
    }
}

/// `.fx-row.parallel::before` and `::after`: a bracket above the row and one below it, with its legs
/// reaching towards the effects.
private struct SplitAndMergeLines: Shape {
    private static let inset: CGFloat = 0.22
    private static let height: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        // On pixel centers, so the 1 pt stroke stays sharp.
        let left = (rect.width * Self.inset).rounded() + 0.5
        let right = (rect.width * (1 - Self.inset)).rounded() - 0.5
        let top = rect.minY + 0.5
        let bottom = rect.maxY - 0.5
        var path = Path()
        path.addLines([CGPoint(x: left, y: rect.minY + Self.height), CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: rect.minY + Self.height)])
        path.addLines([CGPoint(x: left, y: rect.maxY - Self.height), CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom), CGPoint(x: right, y: rect.maxY - Self.height)])
        return path
    }
}

/// `.fx`. An effect that did not load shows that in its name, and why in its tooltip.
private struct EffectSlot: View {
    let channel: UUID
    let effect: InsertEffect
    let failure: String?

    @Environment(AppModel.self) private var model
    @State private var isHovered = false
    @State private var anchor = CGRect.zero

    var body: some View {
        Button { model.showEffectMenu(channel: channel, effect: effect.id, anchor: anchor) } label: {
            Text(effect.slot.displayName)
                .font(.panelText(12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(failure == nil ? Color.ledSoft : Color.fault)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panelDeep)
                .overlay {
                    Rectangle().strokeBorder(Color.led.opacity(0.15), lineWidth: 8).blur(radius: 4).clipped()
                }
                .overlay(Rectangle().strokeBorder(isHovered ? Color.led : Color.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .panelMenuAnchor($anchor)
    }

    private var help: String {
        if let failure { return failure }
        guard let source = effect.sidechainIn else { return effect.slot.displayName }
        return "\(effect.slot.displayName), sidechain from \(source.label(prefix: "In"))"
    }
}
