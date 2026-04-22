import Foundation

@MainActor
class LlamaManager {

    // MARK: - Public state

    var isReady: Bool = false
    weak var stateMachine: DictationStateMachine?

    // MARK: - Private state

    private var process: Process?
    private var lastCrashTime: Date?

    // MARK: - Paths (resolved once at start())

    private func resolvePaths() -> (binary: String, model: String)? {
        // SMART_DICTATION_RESOURCES is set by the LaunchAgent to the absolute
        // path of the project's Resources/ directory, decoupling path resolution
        // from wherever the binary happens to live (.app bundle, build dir, etc.)
        let resourcesDir: URL
        if let envPath = ProcessInfo.processInfo.environment["SMART_DICTATION_RESOURCES"] {
            // Set by LaunchAgent or launch script
            resourcesDir = URL(fileURLWithPath: envPath)
        } else if let bundleRes = Bundle.main.resourceURL,
                  FileManager.default.fileExists(atPath: bundleRes.appendingPathComponent("bin/llama-server").path) {
            // Bundled inside .app/Contents/Resources/
            resourcesDir = bundleRes
        } else {
            // Dev fallback: Resources/ is sibling of .build/ in project root
            resourcesDir = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent() // MacOS/
                .deletingLastPathComponent() // Contents/
                .deletingLastPathComponent() // SmartDictation.app/
                .appendingPathComponent("Resources")  // project Resources/
                .standardized
        }

        let binaryURL = resourcesDir
            .appendingPathComponent("bin/llama-server")
            .standardized
        let modelURL = resourcesDir
            .appendingPathComponent("models/Qwen3.5-4B.Q4_K_M.gguf")
            .standardized

        let binaryPath = binaryURL.path
        let modelPath  = modelURL.path

        let fm = FileManager.default
        guard fm.fileExists(atPath: binaryPath) else {
            fputs("[LlamaManager] ERROR: llama-server binary not found at \(binaryPath)\n", stderr)
            return nil
        }
        guard fm.fileExists(atPath: modelPath) else {
            fputs("[LlamaManager] ERROR: model file not found at \(modelPath)\n", stderr)
            return nil
        }
        return (binaryPath, modelPath)
    }

    // MARK: - Public API

    /// Spawn llama-server, poll /health every 500ms up to 60s, then notify stateMachine.
    func start() async {
        guard let paths = resolvePaths() else {
            isReady = false
            stateMachine?.llmStartTimeout()
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: paths.binary)
        proc.arguments = [
            "--model",      paths.model,
            "--host",       "127.0.0.1",     // loopback only — never 0.0.0.0
            "--port",       "\(Config.llamaServerPort)",
            "--ctx-size",   "4096",
            "--n-gpu-layers", "99",
            "--flash-attn", "on",
            "--parallel",   "1"
        ]

        // Redirect child stdout/stderr to /dev/null so they don't pollute our log.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice

        // Auto-respawn on unexpected exit.
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.respawn()
            }
        }

        do {
            try proc.run()
        } catch {
            fputs("[LlamaManager] ERROR: failed to launch llama-server — \(error)\n", stderr)
            isReady = false
            stateMachine?.llmStartTimeout()
            return
        }

        self.process = proc

        // Poll /health every 500ms up to Config.llamaHealthTimeoutSeconds (60s).
        let healthURL = URL(string: "http://127.0.0.1:\(Config.llamaServerPort)/health")!
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.0
        let session = URLSession(configuration: sessionConfig)

        let deadline = Date().addingTimeInterval(Config.llamaHealthTimeoutSeconds)

        while Date() < deadline {
            if await checkHealth(using: session, url: healthURL) {
                isReady = true
                stateMachine?.llmStarted()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        // Timed out.
        fputs("[LlamaManager] WARNING: llama-server did not become healthy within \(Int(Config.llamaHealthTimeoutSeconds))s\n", stderr)
        isReady = false
        stateMachine?.llmStartTimeout()
    }

    /// Terminate the child process cleanly. Idempotent.
    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isReady = false
    }

    // MARK: - Private helpers

    /// Returns true if GET /health responds with HTTP 200.
    private func checkHealth(using session: URLSession, url: URL) async -> Bool {
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
        } catch {
            // Connection refused / timeout — server not ready yet.
        }
        return false
    }

    /// Called on the main thread when the child process exits.
    /// Restarts once automatically; skips restart if the previous crash was < 30s ago.
    private func respawn() {
        // If stop() was called deliberately, process is nil — don't respawn.
        guard process != nil else { return }

        let now = Date()

        if let lastCrash = lastCrashTime, now.timeIntervalSince(lastCrash) < 30 {
            fputs("[LlamaManager] ERROR: llama-server crashed twice within 30s — not restarting\n", stderr)
            isReady = false
            process = nil
            return
        }

        lastCrashTime = now
        process = nil
        isReady = false

        fputs("[LlamaManager] INFO: llama-server exited unexpectedly — restarting once\n", stderr)

        Task { @MainActor in
            await self.start()
        }
    }
}
