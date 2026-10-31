import Foundation

public enum ChainError: Error, Equatable {
    case rowFull
    case noSuchRow
}

extension Channel {
    /// At most this many effects run side by side in one row.
    public static let maxParallel = 3

    /// Appends the effect as a new row at the end of the chain.
    public mutating func addEffect(_ effect: InsertEffect) {
        effects.append([effect])
    }

    /// Adds the effect next to the ones already in the row.
    public mutating func addParallel(_ effect: InsertEffect, toRow row: Int) throws {
        guard effects.indices.contains(row) else { throw ChainError.noSuchRow }
        guard effects[row].count < Self.maxParallel else { throw ChainError.rowFull }
        effects[row].append(effect)
    }

    /// Takes the effect out of its parallel row and puts it in a new row right below.
    /// Does nothing when the effect is alone in its row or unknown.
    public mutating func moveToSeries(effectID: UUID) {
        for (rowIndex, row) in effects.enumerated() {
            guard let index = row.firstIndex(where: { $0.id == effectID }) else { continue }
            guard row.count > 1 else { return }
            let effect = effects[rowIndex].remove(at: index)
            effects.insert([effect], at: rowIndex + 1)
            return
        }
    }

    /// Removes the effect; a row left empty is dropped. Unknown IDs are ignored.
    public mutating func removeEffect(effectID: UUID) {
        for rowIndex in effects.indices {
            effects[rowIndex].removeAll { $0.id == effectID }
        }
        effects.removeAll(where: \.isEmpty)
    }
}
