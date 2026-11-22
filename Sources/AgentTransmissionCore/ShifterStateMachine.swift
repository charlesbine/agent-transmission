import Foundation

public enum RawShifterEvent: Equatable, Sendable {
    case engaged(GearPosition)
    case enteredNeutral
    case sequentialStep(Int)
    case parkingChanged(Bool)
}

public struct ShifterStateMachine: Sendable {
    public let settleInterval: TimeInterval
    public let neutralSettleInterval: TimeInterval

    private var previousButtons: Set<Int> = []
    private var candidate: GearPosition?
    private var candidateSince: TimeInterval?
    private var neutralSince: TimeInterval?
    private var lastEmittedDirectPosition: GearPosition?

    public init(settleInterval: TimeInterval = 0.025, neutralSettleInterval: TimeInterval = 0.100) {
        self.settleInterval = settleInterval
        self.neutralSettleInterval = neutralSettleInterval
    }

    public mutating func sample(
        buttons: Set<Int>,
        at timestamp: TimeInterval
    ) -> [RawShifterEvent] {
        var events: [RawShifterEvent] = []
        let rising = buttons.subtracting(previousButtons)
        let falling = previousButtons.subtracting(buttons)

        if rising.contains(10) { events.append(.parkingChanged(true)) }
        if falling.contains(10) { events.append(.parkingChanged(false)) }
        if rising.contains(GearPosition.sequentialUp.rawValue) { events.append(.sequentialStep(1)) }
        if rising.contains(GearPosition.sequentialDown.rawValue) { events.append(.sequentialStep(-1)) }

        let directButtons = buttons.intersection(1...7)
        let position = directButtons.count == 1
            ? directButtons.first.flatMap(GearPosition.init(rawValue:))
            : nil

        if directButtons.isEmpty {
            if lastEmittedDirectPosition != nil {
                if let neutralSince {
                    if timestamp - neutralSince >= neutralSettleInterval {
                        lastEmittedDirectPosition = nil
                        self.neutralSince = nil
                        events.append(.enteredNeutral)
                    }
                } else {
                    neutralSince = timestamp
                }
            }
        } else {
            neutralSince = nil
        }

        if position != candidate {
            candidate = position
            candidateSince = position == nil ? nil : timestamp
        } else if let position,
                  position != lastEmittedDirectPosition,
                  let candidateSince,
                  timestamp - candidateSince >= settleInterval {
            lastEmittedDirectPosition = position
            neutralSince = nil
            events.append(.engaged(position))
        }

        previousButtons = buttons
        return events
    }
}
