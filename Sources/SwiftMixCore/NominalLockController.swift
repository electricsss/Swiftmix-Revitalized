import Foundation

public struct NominalLockPolicy: Equatable, Sendable {
    public var nominalValue: Int
    public var tolerance: Int

    public init(nominalValue: Int = HUI.defaultNominalValue, tolerance: Int = 32) {
        self.nominalValue = min(max(nominalValue, HUI.minimumFaderValue), HUI.maximumFaderValue)
        self.tolerance = max(tolerance, 0)
    }

    public func shouldRestore(observedValue: Int) -> Bool {
        abs(observedValue - nominalValue) > tolerance
    }

    public func restoreValue(observedValue: Int, lockIsArmed: Bool) -> Int? {
        guard lockIsArmed, shouldRestore(observedValue: observedValue) else {
            return nil
        }
        return nominalValue
    }
}
