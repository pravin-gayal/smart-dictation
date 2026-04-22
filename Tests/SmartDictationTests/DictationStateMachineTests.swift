import XCTest
@testable import SmartDictationLib

// MARK: - Mock Delegate

@MainActor
final class MockDelegate: DictationStateMachineDelegate {
    var transitions: [DictationState] = []

    nonisolated func stateMachine(_ sm: DictationStateMachine, didTransitionTo state: DictationState) {
        MainActor.assumeIsolated {
            transitions.append(state)
        }
    }
}

// MARK: - Tests

@MainActor
final class DictationStateMachineTests: XCTestCase {

    var sm: DictationStateMachine!
    var delegate: MockDelegate!

    override func setUp() {
        super.setUp()
        sm = DictationStateMachine()
        delegate = MockDelegate()
        sm.delegate = delegate
    }

    // MARK: - Valid transitions

    func testBootingToPermissionDenied() {
        XCTAssertEqual(sm.state, .booting)
        sm.permissionDenied()
        XCTAssertEqual(sm.state, .permissionDenied)
        XCTAssertEqual(delegate.transitions, [.permissionDenied])
    }

    func testBootingToLLMStarting() {
        sm.beginLLMStartup()
        XCTAssertEqual(sm.state, .llmStarting)
        XCTAssertEqual(delegate.transitions, [.llmStarting])
    }

    func testLLMStartingToIdleViaLLMStarted() {
        sm.beginLLMStartup()
        delegate.transitions.removeAll()

        sm.llmStarted()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(delegate.transitions, [.idle])
    }

    func testLLMStartingToIdleViaTimeout() {
        sm.beginLLMStartup()
        delegate.transitions.removeAll()

        sm.llmStartTimeout()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(delegate.transitions, [.idle])
    }

    func testIdleToRecording() {
        // Advance to idle
        sm.beginLLMStartup()
        sm.llmStarted()
        delegate.transitions.removeAll()

        sm.toggleDictation()
        XCTAssertEqual(sm.state, .recording)
        XCTAssertEqual(delegate.transitions, [.recording])
    }

    func testRecordingToIdleWhenTranscriptNil() {
        advanceToRecording()
        delegate.transitions.removeAll()

        // nil transcript → back to idle
        sm.setFinalTranscript(nil)
        sm.toggleDictation()

        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(delegate.transitions, [.idle])
    }

    func testRecordingToCorrectingWhenTranscriptSet() {
        advanceToRecording()
        delegate.transitions.removeAll()

        sm.setFinalTranscript("hello")
        sm.toggleDictation()

        XCTAssertEqual(sm.state, .correcting(rawTranscript: "hello"))
        XCTAssertEqual(delegate.transitions, [.correcting(rawTranscript: "hello")])
    }

    func testCorrectingToPastingViaCorrectionReceived() {
        advanceToCorrectingWith("hello")
        delegate.transitions.removeAll()

        sm.correctionReceived("fixed hello")

        XCTAssertEqual(sm.state, .pasting(textToPaste: "fixed hello"))
        XCTAssertEqual(delegate.transitions, [.pasting(textToPaste: "fixed hello")])
    }

    func testCorrectingToPastingViaCorrectionFailed() {
        advanceToCorrectingWith("hello")
        delegate.transitions.removeAll()

        sm.correctionFailed(rawTranscript: "hello")

        XCTAssertEqual(sm.state, .pasting(textToPaste: "hello"))
        XCTAssertEqual(delegate.transitions, [.pasting(textToPaste: "hello")])
    }

    func testPastingToIdle() {
        advanceToPastingWith("fixed hello")
        delegate.transitions.removeAll()

        sm.pasteComplete()

        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(delegate.transitions, [.idle])
    }

    // MARK: - Invalid transitions (must be no-ops)

    func testCorrectionReceivedFromIdleIsNoOp() {
        advanceToIdle()
        let stateBefore = sm.state
        delegate.transitions.removeAll()

        sm.correctionReceived("should be ignored")

        XCTAssertEqual(sm.state, stateBefore)
        XCTAssertTrue(delegate.transitions.isEmpty, "No delegate calls expected for invalid transition")
    }

    func testToggleDictationFromPastingIsNoOp() {
        advanceToPastingWith("text")
        let stateBefore = sm.state
        delegate.transitions.removeAll()

        sm.toggleDictation()

        XCTAssertEqual(sm.state, stateBefore)
        XCTAssertTrue(delegate.transitions.isEmpty, "No delegate calls expected for invalid transition")
    }

    func testPasteCompleteFromIdleIsNoOp() {
        advanceToIdle()
        let stateBefore = sm.state
        delegate.transitions.removeAll()

        sm.pasteComplete()

        XCTAssertEqual(sm.state, stateBefore)
        XCTAssertTrue(delegate.transitions.isEmpty, "No delegate calls expected for invalid transition")
    }

    // MARK: - Delegate notification for every valid transition

    func testDelegateCalledForEachValidTransition() {
        // booting → llmStarting → idle → recording → correcting → pasting → idle
        sm.beginLLMStartup()
        sm.llmStarted()
        sm.toggleDictation()
        sm.setFinalTranscript("hello world")
        sm.toggleDictation()
        sm.correctionReceived("hello world")
        sm.pasteComplete()

        let expected: [DictationState] = [
            .llmStarting,
            .idle,
            .recording,
            .correcting(rawTranscript: "hello world"),
            .pasting(textToPaste: "hello world"),
            .idle
        ]
        XCTAssertEqual(delegate.transitions, expected)
    }

    // MARK: - Helpers

    private func advanceToIdle() {
        sm.beginLLMStartup()
        sm.llmStarted()
    }

    private func advanceToRecording() {
        advanceToIdle()
        sm.toggleDictation()
    }

    private func advanceToCorrectingWith(_ transcript: String) {
        advanceToRecording()
        sm.setFinalTranscript(transcript)
        sm.toggleDictation()
    }

    private func advanceToPastingWith(_ text: String) {
        advanceToCorrectingWith("raw")
        sm.correctionReceived(text)
    }
}
