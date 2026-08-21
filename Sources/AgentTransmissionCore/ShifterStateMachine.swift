import Foundation

public enum RawShifterEvent: Equatable, Sendable {
    case engaged(GearPosition)
    case sequentialStep(Int)
    case parkingChanged(Bool)
}

public struct ShifterStateMachine: Sendable {
    public let settleInterval: TimeInterval

    private var previousButtons: Set<Int> = []
    private var candidate: GearPosition?
    private var candidateSince: TimeInterval?
    private var lastEmittedDirectPosition: GearPosition?

    public init(settleInterval: TimeInterval = 0.025) {
        self.settleInterval = settleInterval
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

        if position != candidate {
            candidate = position
            candidateSince = position == nil ? nil : timestamp
        } else if let position,
                  position != lastEmittedDirectPosition,
                  let candidateSince,
                  timestamp - candidateSince >= settleInterval {
            lastEmittedDirectPosition = position
            events.append(.engaged(position))
        }

        previousButtons = buttons
        return events
    }
}
