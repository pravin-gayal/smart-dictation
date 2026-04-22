import CoreGraphics
import Foundation

enum Config {
    // Hotkey: Cmd+D (kVK_ANSI_D = 2)
    static let hotkeyKeyCode: CGKeyCode = 2
    static let hotkeyModifiers: CGEventFlags = .maskCommand

    // LLM — read from env vars with fallback defaults
    static var llmBaseURL: String {
        ProcessInfo.processInfo.environment["LLM_BASE_URL"] ?? "http://localhost:8080"
    }
    static var llmModel: String {
        ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "qwen3.5-4b"
    }
    static let llmTimeoutSeconds: Double = 30.0

    // llama-server
    static let llamaServerPort: Int = 8080
    static let llamaHealthTimeoutSeconds: Double = 60.0

    // Paste
    static let pasteRestoreDelayMs: Int = 150

    // Overlay
    static let overlayDismissDelayMs: Int = 600
}
