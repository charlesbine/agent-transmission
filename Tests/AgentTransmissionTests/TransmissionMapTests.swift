import XCTest
@testable import AgentTransmission
@testable import AgentTransmissionCore

final class TransmissionMapTests: XCTestCase {
    func testDefaultDirectMapping() {
        let map = CodexAgentTarget().defaultTransmissionMap

        XCTAssertEqual(map.preset(for: .first), ModelPreset(name: "Luna", model: "gpt-5.6-luna", effort: .max))
        XCTAssertEqual(map.preset(for: .second), ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .medium))
        XCTAssertEqual(map.preset(for: .fourth), ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .xhigh))
        XCTAssertEqual(map.preset(for: .sixth), ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .ultra))
        XCTAssertEqual(map.preset(for: .reverse)?.name, "Review")
    }

    func testMapRoundTripsThroughCodable() throws {
        let map = CodexAgentTarget().defaultTransmissionMap
        let encoded = try JSONEncoder().encode(map)
        XCTAssertEqual(try JSONDecoder().decode(TransmissionMap.self, from: encoded), map)
    }

    func testSequentialEffortStepsWithinCurrentFamilyAndClamps() {
        let solHigh = ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .high)
        let target = CodexAgentTarget()
        XCTAssertEqual(target.stepEffort(from: solHigh, direction: 1).effort, .xhigh)
        XCTAssertEqual(target.stepEffort(from: solHigh, direction: -1).effort, .medium)
        let solUltra = ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .ultra)
        XCTAssertEqual(target.stepEffort(from: solUltra, direction: 1).effort, .ultra)
    }

    func testModifiedSequentialChangesFamilyAndPreservesClosestEffort() {
        let terraUltra = ModelPreset(name: "Terra", model: "gpt-5.6-terra", effort: .ultra)
        let target = CodexAgentTarget()
        XCTAssertEqual(
            target.stepModelFamily(from: terraUltra, direction: 1),
            ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .ultra)
        )
        XCTAssertEqual(
            target.stepModelFamily(from: terraUltra, direction: -1),
            ModelPreset(name: "Luna", model: "gpt-5.6-luna", effort: .max)
        )
        let solUltra = target.stepModelFamily(from: terraUltra, direction: 1)
        XCTAssertEqual(target.stepModelFamily(from: solUltra, direction: 1).name, "Sol")
    }

    func testTargetSelectionSupportsAutomaticAndPinned() {
        let older = AgentTask(id: "a", title: "Older", workspace: "ha", updatedAt: 1)
        let newer = AgentTask(id: "b", title: "Newer", workspace: "ha", updatedAt: 2)

        XCTAssertEqual(TargetSelection.automatic.resolve(in: [older, newer]), newer)
        XCTAssertEqual(TargetSelection.pinned("a").resolve(in: [older, newer]), older)
        XCTAssertNil(TargetSelection.pinned("missing").resolve(in: [older, newer]))
    }

    func testMapCompatibilityUsesTargetPresetCatalog() {
        let target = CodexAgentTarget()
        XCTAssertTrue(target.defaultTransmissionMap.isCompatible(with: target.supportedPresets))
        XCTAssertFalse(target.defaultTransmissionMap.isCompatible(with: [target.supportedPresets[0]]))
    }
}
