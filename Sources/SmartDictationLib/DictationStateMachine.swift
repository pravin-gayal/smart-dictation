import Foundation
import os.log

private let smLogger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "StateMachine")

// MARK: - State

enum DictationState: Equatable {
    case booting
    case permissionDenied
    case llmStarting
    case idle
    case recording
    case correcting(rawTranscript: String)
    case pasting(textToPaste: String)
}

// MARK: - Delegate

protocol DictationStateMachineDelegate: AnyObject {
    func stateMachine(_ sm: DictationStateMachine, didTransitionTo state: DictationState)
}

// MARK: - State Machine

@MainActor
final class DictationStateMachine {

    // MARK: Public state

    private(set) var state: DictationState = .booting {
        didSet {
            smLogger.info("State → \(String(describing: self.state), privacy: .public)")
            delegate?.stateMachine(self, didTransitionTo: state)
        }
    }

    weak var delegate: DictationStateMachineDelegate?

    // MARK: Private storage

    /// Stored by setFinalTranscript(_:); read by toggleDictation() and correctionFailed().
    private var storedTranscript: String?

    // MARK: - Transitions

    /// Called by HotkeyDaemon on every Cmd+D press.
    /// .idle          → .recording
    /// .recording     → .correcting(rawTranscript)   if storedTranscript is non-empty
    /// .recording     → .idle                         if storedTranscript is nil/empty
    func toggleDictation() {
        smLogger.info("toggleDictation() from: \(String(describing: self.state), privacy: .public)")
        switch state {
        case .idle:
            storedTranscript = nil
            state = .recording

        case .recording:
            let transcript = storedTranscript ?? ""
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                storedTranscript = nil
                state = .idle
            } else {
                state = .correcting(rawTranscript: transcript)
            }

        default:
            smLogger.warning("toggleDictation() invalid state \(String(describing: self.state), privacy: .public) — ignoring")
        }
    }

    /// Called by SpeechRecognizer when a final recognition result arrives (or nil on empty result).
    func setFinalTranscript(_ text: String?) {
        guard case .recording = state else {
            print("[DictationStateMachine] WARNING: setFinalTranscript(_:) called from invalid state \(state) — ignoring")
            return
        }
        storedTranscript = text
    }

    /// Called by LLMClient on successful correction.
    /// .correcting → .pasting(correctedText)
    func correctionReceived(_ correctedText: String) {
        guard case .correcting = state else {
            print("[DictationStateMachine] WARNING: correctionReceived(_:) called from invalid state \(state) — ignoring")
            return
        }
        state = .pasting(textToPaste: correctedText)
    }

    /// Called by LLMClient on error/timeout — graceful degradation: paste raw transcript.
    /// .correcting → .pasting(rawTranscript)
    func correctionFailed(rawTranscript: String) {
        guard case .correcting = state else {
            print("[DictationStateMachine] WARNING: correctionFailed(rawTranscript:) called from invalid state \(state) — ignoring")
            return
        }
        state = .pasting(textToPaste: rawTranscript)
    }

    /// Called by PasteController after paste + clipboard restore completes.
    /// .pasting → .idle
    func pasteComplete() {
        guard case .pasting = state else {
            print("[DictationStateMachine] WARNING: pasteComplete() called from invalid state \(state) — ignoring")
            return
        }
        storedTranscript = nil
        state = .idle
    }

    /// Called by PermissionManager when any required permission is denied.
    /// any state → .permissionDenied
    func permissionDenied() {
        state = .permissionDenied
    }

    /// Called by LlamaManager when llama-server /health returns OK.
    /// .llmStarting → .idle
    func llmStarted() {
        guard case .llmStarting = state else {
            print("[DictationStateMachine] WARNING: llmStarted() called from invalid state \(state) — ignoring")
            return
        }
        state = .idle
    }

    /// Called by LlamaManager on 60s health-check timeout.
    /// .llmStarting → .idle  (llmReady flag is managed by LlamaManager itself)
    func llmStartTimeout() {
        guard case .llmStarting = state else {
            print("[DictationStateMachine] WARNING: llmStartTimeout() called from invalid state \(state) — ignoring")
            return
        }
        state = .idle
    }

    /// Called by main.swift after all permissions are confirmed OK.
    /// .booting → .llmStarting
    func beginLLMStartup() {
        guard case .booting = state else {
            print("[DictationStateMachine] WARNING: beginLLMStartup() called from invalid state \(state) — ignoring")
            return
        }
        state = .llmStarting
    }
}
