import Foundation

public enum FaderExerciseTarget: String, Equatable, Sendable {
    case maximum
    case minimum
    case nominal

    public func value(nominalValue: Int) -> Int {
        switch self {
        case .maximum:
            return HUI.maximumFaderValue
        case .minimum:
            return HUI.minimumFaderValue
        case .nominal:
            return min(max(nominalValue, HUI.minimumFaderValue), HUI.maximumFaderValue)
        }
    }
}

public enum CommissioningSequenceFailure: Equatable, Sendable {
    case timedOut(channel: Int, target: FaderExerciseTarget)
}

public enum CommissioningSequencePhase: Equatable, Sendable {
    case idle
    case testing(channel: Int, target: FaderExerciseTarget)
    case vegas
    case failed(CommissioningSequenceFailure)
}

public enum CommissioningSequenceAction: Equatable, Sendable {
    case send(channel: Int, value: Int)
    case enterVegas
    case failed(CommissioningSequenceFailure)
}

/// Drives one global fader channel at a time through maximum, minimum, and
/// verified nominal. A stage is accepted only after at least one post-command
/// position away from its target is observed, followed by a report at target.
/// This prevents an immediate byte-for-byte MIDI loopback from passing a stage.
public struct CommissioningSequence: Sendable {
    public let channelCount: Int
    public let nominalValue: Int
    public let nominalTolerance: Int
    public let endpointTolerance: Int
    public let stageTimeout: TimeInterval

    public private(set) var phase: CommissioningSequencePhase = .idle
    public private(set) var completedChannelCount = 0

    private var stageStartedAt: TimeInterval?
    private var deadline: TimeInterval?
    private var sawPostCommandMovement = false

    public init(
        channelCount: Int,
        nominalValue: Int,
        nominalTolerance: Int,
        endpointTolerance: Int = 64,
        stageTimeout: TimeInterval = 8
    ) {
        self.channelCount = max(channelCount, 1)
        self.nominalValue = min(max(nominalValue, HUI.minimumFaderValue), HUI.maximumFaderValue)
        self.nominalTolerance = max(nominalTolerance, 0)
        self.endpointTolerance = max(endpointTolerance, 0)
        self.stageTimeout = max(stageTimeout, 0.1)
    }

    public mutating func start(at time: TimeInterval) -> CommissioningSequenceAction {
        completedChannelCount = 0
        return begin(channel: 0, target: .maximum, at: time)
    }

    public mutating func observe(
        channel: Int,
        value: Int,
        at time: TimeInterval
    ) -> CommissioningSequenceAction? {
        guard case let .testing(expectedChannel, target) = phase,
              channel == expectedChannel,
              let stageStartedAt,
              let deadline,
              time > stageStartedAt,
              time <= deadline else {
            return nil
        }

        let targetValue = target.value(nominalValue: nominalValue)
        let tolerance = target == .nominal ? nominalTolerance : endpointTolerance

        guard abs(value - targetValue) <= tolerance else {
            sawPostCommandMovement = true
            return nil
        }

        // A command echoed directly into the selected source reports the target
        // without any intervening travel. Do not treat that as motor movement.
        guard sawPostCommandMovement else {
            return nil
        }

        switch target {
        case .maximum:
            return begin(channel: channel, target: .minimum, at: time)
        case .minimum:
            return begin(channel: channel, target: .nominal, at: time)
        case .nominal:
            completedChannelCount = channel + 1
            if completedChannelCount == channelCount {
                self.stageStartedAt = nil
                self.deadline = nil
                phase = .vegas
                return .enterVegas
            }
            return begin(channel: channel + 1, target: .maximum, at: time)
        }
    }

    public mutating func tick(at time: TimeInterval) -> CommissioningSequenceAction? {
        guard case let .testing(channel, target) = phase,
              let deadline,
              time >= deadline else {
            return nil
        }

        let failure = CommissioningSequenceFailure.timedOut(channel: channel, target: target)
        phase = .failed(failure)
        stageStartedAt = nil
        self.deadline = nil
        return .failed(failure)
    }

    public mutating func stop() {
        phase = .idle
        stageStartedAt = nil
        deadline = nil
        sawPostCommandMovement = false
    }

    private mutating func begin(
        channel: Int,
        target: FaderExerciseTarget,
        at time: TimeInterval
    ) -> CommissioningSequenceAction {
        phase = .testing(channel: channel, target: target)
        stageStartedAt = time
        deadline = time + stageTimeout
        sawPostCommandMovement = false
        return .send(channel: channel, value: target.value(nominalValue: nominalValue))
    }
}

public struct VegasWave: Equatable, Sendable {
    public let channelCount: Int
    public let minimumValue: Int
    public let maximumValue: Int
    public let cycleDuration: TimeInterval

    public init(
        channelCount: Int,
        minimumValue: Int = HUI.minimumFaderValue,
        maximumValue: Int = HUI.maximumFaderValue,
        cycleDuration: TimeInterval = 3
    ) {
        self.channelCount = max(channelCount, 1)
        self.minimumValue = min(max(minimumValue, HUI.minimumFaderValue), HUI.maximumFaderValue)
        self.maximumValue = min(
            max(maximumValue, self.minimumValue),
            HUI.maximumFaderValue
        )
        self.cycleDuration = max(cycleDuration, 0.1)
    }

    /// Returns one point in a single sine wave spanning the complete desk.
    public func value(channel: Int, elapsed: TimeInterval) -> Int {
        let safeChannel = min(max(channel, 0), channelCount - 1)
        let spatialPhase = 2 * Double.pi * Double(safeChannel) / Double(channelCount)
        let timePhase = 2 * Double.pi * elapsed / cycleDuration
        let normalized = (sin(spatialPhase - timePhase) + 1) / 2
        let range = Double(maximumValue - minimumValue)
        return minimumValue + Int((normalized * range).rounded())
    }
}
