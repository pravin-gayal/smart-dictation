import AppKit
import Foundation
import SmartDictationLib

// MARK: - Signal handler global storage

// Signal handlers are C function pointers — they cannot capture Swift context.
// We store a raw pointer to LlamaManager here so the signal handlers can call stop().
private var gLlamaManagerPtr: UnsafeMutableRawPointer?

// MARK: - DictationCoordinator

/// Coordinates state transitions between all components.
/// Owns the wiring between DictationStateMachine, SpeechRecognizer,
/// OverlayWindow, LLMClient, and PasteController.
@MainActor
final class DictationCoordinator: DictationStateMachineDelegate {

    let stateMachine: DictationStateMachine
    let speechRecognizer: SpeechRecognizer
    let overlay: OverlayWindow
    let llmClient: LLMClient
    let pasteController: PasteController

    private var lastPastedText: String = ""

    init(
        stateMachine: DictationStateMachine,
        speechRecognizer: SpeechRecognizer,
        overlay: OverlayWindow,
        llmClient: LLMClient,
        pasteController: PasteController
    ) {
        self.stateMachine = stateMachine
        self.speechRecognizer = speechRecognizer
        self.overlay = overlay
        self.llmClient = llmClient
        self.pasteController = pasteController
    }

    // MARK: - DictationStateMachineDelegate

    nonisolated func stateMachine(_ sm: DictationStateMachine, didTransitionTo state: DictationState) {
        // The delegate is called from DictationStateMachine which is @MainActor,
        // so we are already on the main thread — assumeIsolated is safe.
        MainActor.assumeIsolated {
            handleTransition(sm: sm, state: state)
        }
    }

    private func handleTransition(sm: DictationStateMachine, state: DictationState) {
        switch state {

        case .booting:
            // Boot sequence runs in the top-level Task — nothing here.
            break

        case .llmStarting:
            overlay.show(state: .warmingUp)

        case .idle:
            // Show "done" briefly if we just finished pasting.
            if !lastPastedText.isEmpty {
                overlay.show(state: .done(finalText: lastPastedText))
                lastPastedText = ""
            } else {
                overlay.dismiss(animated: true)
            }

        case .recording:
            overlay.show(state: .recording(partialText: ""))
            do {
                try speechRecognizer.startRecording()
            } catch {
                print("[SpeechRecognizer] Failed to start: \(error)")
                // No recording started — abort back to idle.
                stateMachine.setFinalTranscript(nil)
                stateMachine.toggleDictation()
            }

        case .correcting(let rawTranscript):
            // The final transcript was stored by onFinalTranscript before
            // toggleDictation() advanced state to .correcting.
            // Stop recording is safe to call here (idempotent).
            speechRecognizer.stopRecording()
            overlay.show(state: .correcting)
            Task { @MainActor in
                do {
                    let corrected = try await self.llmClient.correct(rawTranscript: rawTranscript)
                    sm.correctionReceived(corrected)
                } catch LLMError.offline {
                    self.overlay.show(state: .llmOffline)
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch LLMError.timeout {
                    self.overlay.show(state: .llmOffline)
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch {
                    sm.correctionFailed(rawTranscript: rawTranscript)
                }
            }

        case .pasting(let text):
            lastPastedText = text
            let targetApp = sm.recordingTargetApp
            Task { @MainActor in
                await self.pasteController.paste(text, into: targetApp)
                sm.pasteComplete()
            }

        case .permissionDenied:
            overlay.dismiss(animated: false)
        }
    }
}

// MARK: - Boot

// All @MainActor components are instantiated inside MainActor.assumeIsolated,
// which is valid because main.swift top-level code always runs on the main thread.
MainActor.assumeIsolated {

    // MARK: Instantiate components

    let stateMachine = DictationStateMachine()
    let permissionManager = PermissionManager()
    let llamaManager = LlamaManager()
    let overlay = OverlayWindow()
    let speechRecognizer = SpeechRecognizer()
    let llmClient = LLMClient()
    let pasteController = PasteController()
    let hotkeyDaemon = HotkeyDaemon()

    // MARK: Wire lazy references

    llamaManager.stateMachine = stateMachine
    hotkeyDaemon.stateMachine = stateMachine

    // MARK: Coordinator

    let coordinator = DictationCoordinator(
        stateMachine: stateMachine,
        speechRecognizer: speechRecognizer,
        overlay: overlay,
        llmClient: llmClient,
        pasteController: pasteController
    )
    stateMachine.delegate = coordinator

    // MARK: Speech recognizer callbacks
    // SpeechRecognizer dispatches all callbacks back to the main queue,
    // so these closures are effectively @MainActor.

    // Partial results: update the overlay text while recording.
    speechRecognizer.onPartialResult = { text in
        overlay.updatePartialText(text)
    }

    // Final transcript flow:
    //   1. Speech recognizer delivers final result (on endAudio / auto end-of-speech).
    //   2. setFinalTranscript stores the text in the state machine.
    //   3. toggleDictation() advances .recording → .correcting (non-empty) or .idle (empty).
    //   4. Coordinator delegate handles the new state.
    speechRecognizer.onFinalTranscript = { text in
        stateMachine.setFinalTranscript(text)
        stateMachine.toggleDictation()
    }

    // Amplitude levels: drive the waveform visualisation.
    speechRecognizer.onAmplitudeLevels = { levels in
        overlay.updateWaveform(levels)
    }

    // Recognition error: abort recording gracefully with no paste.
    speechRecognizer.onError = { error in
        print("[SpeechRecognizer] Error: \(error)")
        stateMachine.setFinalTranscript(nil)
        // .recording → .idle (nil transcript path)
        stateMachine.toggleDictation()
    }

    // MARK: Signal handlers
    // Signal handlers must be C function pointers (no context capture).
    // Store LlamaManager via an Unmanaged pointer in a global variable.
    gLlamaManagerPtr = Unmanaged.passRetained(llamaManager).toOpaque()

    signal(SIGTERM) { _ in
        if let ptr = gLlamaManagerPtr {
            Unmanaged<LlamaManager>.fromOpaque(ptr).takeUnretainedValue().stop()
        }
        exit(0)
    }
    signal(SIGINT) { _ in
        if let ptr = gLlamaManagerPtr {
            Unmanaged<LlamaManager>.fromOpaque(ptr).takeUnretainedValue().stop()
        }
        exit(0)
    }

    // MARK: Boot sequence task

    Task { @MainActor in
        // 1. Check permissions
        let ok = await permissionManager.checkAll()
        guard ok else {
            stateMachine.permissionDenied()
            // RunLoop keeps the daemon alive so the user can see the guidance message
            // in stderr and relaunch after granting permissions.
            return
        }

        // 2. Start LLM
        //    .booting → .llmStarting  (coordinator shows .warmingUp overlay)
        //    .llmStarting → .idle     (coordinator dismisses overlay)
        stateMachine.beginLLMStartup()
        await llamaManager.start()
        // llamaManager.start() calls stateMachine.llmStarted() or llmStartTimeout()

        // 3. Install global hotkey (requires Accessibility permission)
        let hotkeyOK = hotkeyDaemon.install()
        if !hotkeyOK {
            print("[HotkeyDaemon] Failed to install — Accessibility permission required")
            permissionManager.showDeniedGuidance(for: "Accessibility")
        }

        print("[SmartDictation] Ready. Press Cmd+D to start dictation.")
    }
}

// MARK: - Run loop

RunLoop.main.run()
