import XCTest
@testable import AgentTransmissionCore

final class ShifterStateMachineTests: XCTestCase {
    func testNeutralDoesNotEmitOrClearLastGear() {
        var state = ShifterStateMachine(settleInterval: 0.025)

        XCTAssertEqual(state.sample(buttons: [1], at: 0), [])
        XCTAssertEqual(state.sample(buttons: [1], at: 0.030), [.engaged(.first)])
        XCTAssertEqual(state.sample(buttons: [], at: 0.040), [])
        XCTAssertEqual(state.sample(buttons: [1], at: 0.050), [])
        XCTAssertEqual(state.sample(buttons: [1], at: 0.080), [])
    }

    func testColumnTransitionIsBreakBeforeMake() {
        var state = ShifterStateMachine(settleInterval: 0.025)

        _ = state.sample(buttons: [1], at: 0)
        XCTAssertEqual(state.sample(buttons: [1], at: 0.030), [.engaged(.first)])
        XCTAssertEqual(state.sample(buttons: [], at: 0.040), [])
        XCTAssertEqual(state.sample(buttons: [2], at: 0.054), [])
        XCTAssertEqual(state.sample(buttons: [2], at: 0.080), [.engaged(.second)])
    }

    func testPressingKnobInThirdAndReleasingIsIdempotent() {
        var state = ShifterStateMachine(settleInterval: 0.025)

        _ = state.sample(buttons: [3], at: 0)
        XCTAssertEqual(state.sample(buttons: [3], at: 0.030), [.engaged(.third)])
        XCTAssertEqual(state.sample(buttons: [], at: 0.050), [])
        XCTAssertEqual(state.sample(buttons: [3], at: 0.080), [])
        XCTAssertEqual(state.sample(buttons: [3], at: 0.110), [])
    }

    func testSequentialUsesRisingEdgesAndParkingReportsBothEdges() {
        var state = ShifterStateMachine()

        XCTAssertEqual(state.sample(buttons: [8], at: 0), [.sequentialStep(1)])
        XCTAssertEqual(state.sample(buttons: [8], at: 0.010), [])
        XCTAssertEqual(state.sample(buttons: [], at: 0.020), [])
        XCTAssertEqual(state.sample(buttons: [9, 10], at: 0.030), [.parkingChanged(true), .sequentialStep(-1)])
        XCTAssertEqual(state.sample(buttons: [9], at: 0.040), [.parkingChanged(false)])
    }

    func testAmbiguousDirectButtonsDoNotEmit() {
        var state = ShifterStateMachine(settleInterval: 0.025)

        XCTAssertEqual(state.sample(buttons: [1, 2], at: 0), [])
        XCTAssertEqual(state.sample(buttons: [1, 2], at: 1), [])
    }
}
