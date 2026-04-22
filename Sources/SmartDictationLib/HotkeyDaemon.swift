import AppKit
import Carbon.HIToolbox
import os.log

private let hdLogger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "HotkeyDaemon")

// MARK: - HotkeyDaemon

/// Registers a system-wide hotkey (Cmd+D) using the Carbon RegisterEventHotKey API.
///
/// Unlike CGEventTap and NSEvent.addGlobalMonitorForEvents, Carbon hotkeys do NOT
/// require Accessibility permission and work on macOS 26 with ad-hoc signed apps.
final class HotkeyDaemon {

    // MARK: - Public

    weak var stateMachine: DictationStateMachine?

    // MARK: - Private

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Install

    @discardableResult
    func install() -> Bool {
        guard hotKeyRef == nil else { return true }

        // Register a unique hotkey ID
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SMDT"), id: 1)

        // Register Cmd+D: kVK_ANSI_D = 2, cmdKey modifier
        let status = RegisterEventHotKey(
            UInt32(Config.hotkeyKeyCode),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            hdLogger.error("RegisterEventHotKey failed: \(status)")
            return false
        }

        // Install a Carbon event handler on the application event target
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Pass self as userData so the C callback can reach this instance
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            hdLogger.error("InstallEventHandler failed: \(installStatus)")
            UnregisterEventHotKey(hotKeyRef!)
            hotKeyRef = nil
            Unmanaged<HotkeyDaemon>.fromOpaque(selfPtr).release()
            return false
        }

        hdLogger.info("Carbon hotkey installed — listening for Cmd+D (no Accessibility required)")
        return true
    }

    // MARK: - Uninstall

    func uninstall() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}

// MARK: - Helpers

/// Convert a 4-character string literal into an OSType (FourCharCode).
private func fourCharCode(_ string: String) -> FourCharCode {
    assert(string.count == 4)
    var result: FourCharCode = 0
    for char in string.unicodeScalars {
        result = (result << 8) + FourCharCode(char.value)
    }
    return result
}

// MARK: - Carbon event handler callback (pure C function pointer)

private func carbonHotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    let daemon = Unmanaged<HotkeyDaemon>.fromOpaque(userData).takeUnretainedValue()
    hdLogger.info("Cmd+D detected via Carbon hotkey — toggling dictation")
    Task { @MainActor in
        daemon.stateMachine?.toggleDictation()
    }

    return noErr
}
