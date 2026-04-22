import AppKit
import CoreGraphics

@MainActor
class PasteController {

    func paste(_ text: String, into targetApp: NSRunningApplication?) async {
        appLog("[PasteController] pasting: \(text)")

        // 1. Activate the target app so Cmd+V lands in the right window
        if let app = targetApp {
            appLog("[PasteController] activating target app: \(app.localizedName ?? "unknown")")
            app.activate(options: .activateIgnoringOtherApps)
            // Poll until the app is actually frontmost (up to 500ms)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms per tick
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    appLog("[PasteController] target app is now frontmost")
                    break
                }
            }
        }

        // 2. Save existing pasteboard string
        let savedString = NSPasteboard.general.string(forType: .string)

        // 3. Write new text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 4. Simulate Cmd+V via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // kVK_ANSI_V = 0x09
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        cmdDown?.flags = .maskCommand
        cmdUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cgSessionEventTap)
        cmdUp?.post(tap: .cgSessionEventTap)

        // 5. Wait pasteRestoreDelayMs before restoring
        try? await Task.sleep(nanoseconds: UInt64(Config.pasteRestoreDelayMs) * 1_000_000)

        // 6. Restore previous pasteboard contents (only if something was saved)
        if let saved = savedString {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(saved, forType: .string)
        }
        // If nothing was saved, leave the pasted text on the pasteboard — do not clear it
    }
}
