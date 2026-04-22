import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "main")

// MARK: - File logging (stdout goes to /dev/null when launched via open)

private var gLogFile: FileHandle?

func appLog(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        gLogFile?.write(data)
    }
    // Also try stdout in case it's connected
    print(message)
}

private func setupFileLogging() {
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/smart-dictation")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logPath = logDir.appendingPathComponent("app.log").path
    FileManager.default.createFile(atPath: logPath, contents: nil)
    gLogFile = FileHandle(forWritingAtPath: logPath)
    gLogFile?.seekToEndOfFile()
}

setupFileLogging()
appLog("=== SmartDictation starting ===")

// MARK: - Global strong references
// These must be globals to outlive the MainActor.assumeIsolated boot block.
// Without this, local lets get deallocated and weak delegates become nil.

private var gCoordinator: DictationCoordinator?
private var gAppDelegate: AppDelegate?
private var gPipeTrigger: PipeTrigger?
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
            logger.info("Coordinator: showing recording overlay")
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
                    appLog("[Coordinator] sending to LLM: \(rawTranscript)")
                    let corrected = try await self.llmClient.correct(rawTranscript: rawTranscript)
                    sm.correctionReceived(corrected)
                } catch LLMError.offline {
                    appLog("[LLMClient] error: offline — pasting raw")
                    self.overlay.show(state: .llmOffline)
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch LLMError.timeout {
                    appLog("[LLMClient] error: timeout — pasting raw")
                    self.overlay.show(state: .llmOffline)
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch LLMError.badResponse(let code) {
                    appLog("[LLMClient] error: bad response \(code) — pasting raw")
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch LLMError.decodingFailed(let desc) {
                    appLog("[LLMClient] error: decoding failed \(desc) — pasting raw")
                    sm.correctionFailed(rawTranscript: rawTranscript)
                } catch {
                    appLog("[LLMClient] error: \(error) — pasting raw")
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
    let appDelegate = AppDelegate()
    let pipeTrigger = PipeTrigger()

    // MARK: Wire lazy references

    llamaManager.stateMachine = stateMachine
    hotkeyDaemon.stateMachine = stateMachine
    appDelegate.stateMachine = stateMachine
    pipeTrigger.stateMachine = stateMachine
    pipeTrigger.speechRecognizer = speechRecognizer

    // Register AppDelegate to receive URL scheme calls (smartdictation://toggle)
    NSApp.delegate = appDelegate

    // Register Apple Event handler immediately — don't wait for applicationDidFinishLaunching
    // since we set the delegate after NSApp is already running.
    NSAppleEventManager.shared().setEventHandler(
        appDelegate,
        andSelector: #selector(AppDelegate.handleURL(_:withReplyEvent:)),
        forEventClass: AEEventClass(kInternetEventClass),
        andEventID: AEEventID(kAEGetURL)
    )
    logger.info("URL scheme handler registered: smartdictation://toggle")

    // MARK: Coordinator

    let coordinator = DictationCoordinator(
        stateMachine: stateMachine,
        speechRecognizer: speechRecognizer,
        overlay: overlay,
        llmClient: llmClient,
        pasteController: pasteController
    )
    stateMachine.delegate = coordinator
    gCoordinator = coordinator
    gAppDelegate = appDelegate
    gPipeTrigger = pipeTrigger

    // MARK: Speech recognizer callbacks
    // SpeechRecognizer dispatches all callbacks back to the main queue,
    // so these closures are effectively @MainActor.

    // Partial results: update the overlay text while recording.
    speechRecognizer.onPartialResult = { text in
        overlay.updatePartialText(text)
    }

    // Final transcript flow:
    //   1. Manual stop or auto end-of-speech triggers stopRecording() → endAudio().
    //   2. SFSpeechRecognizer delivers isFinal result → onFinalTranscript fires.
    //   3. setFinalTranscript stores the text, toggleDictation advances state.
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
        logger.info("Boot sequence starting")

        // 1. Check permissions
        let ok = await permissionManager.checkAll()
        logger.info("Permissions check result: \(ok)")
        guard ok else {
            stateMachine.permissionDenied()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            exit(1)
        }

        // 2. Start LLM
        stateMachine.beginLLMStartup()
        await llamaManager.start()

        // 3. Install global hotkey via Carbon (no Accessibility permission required)
        let hotkeyOK = hotkeyDaemon.install()
        logger.info("Hotkey install result: \(hotkeyOK)")

        // 4. Start pipe trigger — works without any permissions
        pipeTrigger.start()

        print("[SmartDictation] Ready.")
        print("[SmartDictation] Trigger: echo toggle > \"\(PipeTrigger.pipePath)\"")
        logger.info("Ready — pipe trigger active at \(PipeTrigger.pipePath)")
    }
}

// MARK: - Run loop

RunLoop.main.run()
