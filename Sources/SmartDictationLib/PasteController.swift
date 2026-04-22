import AppKit
import CoreGraphics

@MainActor
class PasteController {

    func paste(_ text: String) async {
        appLog("[PasteController] pasting: \(text)")
        // 1. Save existing pasteboard string
        let savedString = NSPasteboard.general.string(forType: .string)

        // 2. Write new text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 3. Simulate Cmd+V via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // kVK_ANSI_V = 0x09
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        cmdDown?.flags = .maskCommand
        cmdUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // 4. Wait pasteRestoreDelayMs before restoring
        try? await Task.sleep(nanoseconds: UInt64(Config.pasteRestoreDelayMs) * 1_000_000)

        // 5. Restore previous pasteboard contents (only if something was saved)
        if let saved = savedString {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(saved, forType: .string)
        }
        // If nothing was saved, leave the pasted text on the pasteboard — do not clear it
    }
}
