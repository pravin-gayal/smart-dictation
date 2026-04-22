import Foundation
import os.log

private let ptLogger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "PipeTrigger")

// MARK: - PipeTrigger

/// Watches a named pipe (FIFO) at ~/Library/Application Support/smart-dictation/trigger.pipe
/// Any write to the pipe triggers toggleDictation().
///
/// Raycast / BetterTouchTool can trigger this with:
///   echo toggle > ~/Library/Application\ Support/smart-dictation/trigger.pipe
///
/// No Accessibility, no URL schemes, no code signing requirements.
@MainActor
final class PipeTrigger {

    static let pipePath: String = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/smart-dictation")
            .path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("trigger.pipe")
    }()

    weak var stateMachine: DictationStateMachine?
    weak var speechRecognizer: SpeechRecognizer?
    private var task: Task<Void, Never>?

    func start() {
        let path = PipeTrigger.pipePath

        // Remove existing file/pipe and create a fresh FIFO
        try? FileManager.default.removeItem(atPath: path)
        guard mkfifo(path, 0o600) == 0 else {
            ptLogger.error("mkfifo failed: \(String(cString: strerror(errno)))")
            return
        }

        ptLogger.info("Pipe trigger ready at: \(path)")
        ptLogger.info("Trigger with: echo toggle > \"\(path)\"")

        task = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                // open() blocks until a writer connects — perfect for a trigger pipe.
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                defer { close(fd) }

                var buf = [UInt8](repeating: 0, count: 64)
                let n = read(fd, &buf, buf.count - 1)
                if n > 0 {
                    let msg = String(bytes: buf.prefix(n), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    ptLogger.info("Pipe received: \"\(msg)\"")
                    // Switch to MainActor to safely read state and call @MainActor methods
                    await MainActor.run {
                        guard let self else { return }
                        let currentState = self.stateMachine?.state
                        ptLogger.info("On main — state: \(String(describing: currentState), privacy: .public)")
                        if currentState == .recording {
                            ptLogger.info("State is recording — calling stopRecording() only")
                            self.speechRecognizer?.stopRecording()
                        } else {
                            ptLogger.info("State is not recording — calling toggleDictation()")
                            self.stateMachine?.toggleDictation()
                        }
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(atPath: PipeTrigger.pipePath)
    }
}
