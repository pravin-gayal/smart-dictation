import AppKit
import os.log

private let adLogger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "AppDelegate")

// MARK: - AppDelegate

/// Handles URL scheme calls: smartdictation://toggle
/// Uses NSAppleEventManager for reliable URL routing in LSUIElement apps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var stateMachine: DictationStateMachine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        adLogger.info("URL scheme handler registered via NSAppleEventManager")
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }

        adLogger.info("URL received: \(urlString)")

        guard url.scheme == "smartdictation" else { return }

        if url.host == "toggle" {
            adLogger.info("Toggle dictation via URL scheme")
            stateMachine?.toggleDictation()
        }
    }

    // Also handle the NSApplicationDelegate method as fallback
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "smartdictation", url.host == "toggle" else { continue }
            adLogger.info("Toggle dictation via application:open:urls:")
            stateMachine?.toggleDictation()
        }
    }
}
