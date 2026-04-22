import AppKit
import AVFoundation
import Speech

@MainActor
class PermissionManager {

    // MARK: - Public API

    /// Check Microphone and Speech Recognition permissions.
    /// Accessibility is NOT required — hotkey is handled via Carbon RegisterEventHotKey.
    func checkAll() async -> Bool {
        // 1. Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .notDetermined:
            let granted = await requestMicrophone()
            if !granted {
                showDeniedGuidance(for: "Microphone")
                return false
            }
        case .denied, .restricted:
            showDeniedGuidance(for: "Microphone")
            return false
        case .authorized:
            break
        @unknown default:
            showDeniedGuidance(for: "Microphone")
            return false
        }

        // 3. Speech Recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .notDetermined:
            let granted = await requestSpeechRecognition()
            if !granted {
                showDeniedGuidance(for: "Speech Recognition")
                return false
            }
        case .denied, .restricted:
            showDeniedGuidance(for: "Speech Recognition")
            return false
        case .authorized:
            break
        @unknown default:
            showDeniedGuidance(for: "Speech Recognition")
            return false
        }

        return true
    }

    // MARK: - Individual permission requests

    /// Request microphone access using AVCaptureDevice.
    /// Returns true if granted.
    func requestMicrophone() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Request speech recognition access using SFSpeechRecognizer.
    /// Returns true if authorized.
    func requestSpeechRecognition() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - User guidance

    /// Print denial guidance to stderr so the daemon log captures it clearly.
    func showDeniedGuidance(for permission: String) {
        fputs(
            "[SMART-DICTATION] \(permission) permission denied. " +
            "Enable in System Settings → Privacy & Security → \(permission) and relaunch.\n",
            stderr
        )
    }
}
