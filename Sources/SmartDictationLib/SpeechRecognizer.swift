import AVFoundation
import Speech

@MainActor
class SpeechRecognizer {

    // MARK: - Callbacks (all called on MainActor)

    /// Called with each partial recognition string while recording.
    var onPartialResult: ((String) -> Void)?

    /// Called once when recording stops: nil if transcript is empty/whitespace.
    var onFinalTranscript: ((String?) -> Void)?

    /// Called ~10fps with 5 Float amplitude values in 0.0–1.0 range.
    var onAmplitudeLevels: (([Float]) -> Void)?

    /// Called on recognition error (cancellation errors are suppressed).
    var onError: ((Error) -> Void)?

    // MARK: - Private state

    private var isRecording = false
    private var engine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // Accumulates all partial segments. SFSpeechRecognizer resets its text on natural pauses,
    // so we keep a running prefix of confirmed segments plus the current live segment.
    private var confirmedText: String = ""
    private var lastPartialText: String = ""

    // MARK: - Public interface

    /// Start microphone capture and speech recognition.
    /// Throws if the audio engine cannot start or the recognizer is unavailable.
    func startRecording() throws {
        guard !isRecording else { return }
        confirmedText = ""
        lastPartialText = ""

        // Create recognizer for en-US locale
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer = recognizer, recognizer.isAvailable else {
            struct RecognizerUnavailable: Error {}
            throw RecognizerUnavailable()
        }

        // Build recognition request fed from audio buffers
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // CRITICAL — no network speech
        request.shouldReportPartialResults = true
        recognitionRequest = request

        // Set up audio engine
        let audioEngine = AVAudioEngine()
        engine = audioEngine
        let inputNode = audioEngine.inputNode

        // Install tap on the input node
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            // Append audio to the recognition request
            request.append(buffer)

            // Compute amplitude levels off-main and dispatch to main
            let rms = Self.computeRMS(from: buffer)
            let normalized = min(max(rms * 20.0, 0.0), 1.0)
            let levels: [Float] = [
                normalized,
                normalized * 0.8,
                normalized * 1.0,
                normalized * 0.9,
                normalized * 0.7
            ]
            DispatchQueue.main.async { [weak self] in
                self?.onAmplitudeLevels?(levels)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal { appLog("[SpeechRecognizer] result isFinal=true text=\(text.prefix(60))") }
                    if result.isFinal {
                        self.recognitionTask = nil
                        // isFinal text may be empty if endAudio() interrupted mid-recognition.
                        // Build full transcript: confirmed segments + current final segment.
                        let finalSegment = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let full: String
                        if finalSegment.isEmpty {
                            // Use lastPartial as current segment fallback
                            let lastTrimmed = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
                            full = self.confirmedText.isEmpty ? lastTrimmed
                                 : lastTrimmed.isEmpty ? self.confirmedText
                                 : self.confirmedText + " " + lastTrimmed
                        } else {
                            full = self.confirmedText.isEmpty ? finalSegment
                                 : self.confirmedText + " " + finalSegment
                        }
                        self.confirmedText = ""
                        self.lastPartialText = ""
                        appLog("[SpeechRecognizer] onFinalTranscript: \(full.isEmpty ? "<empty>" : full)")
                        self.onFinalTranscript?(full.isEmpty ? nil : full)
                    } else {
                        // Detect recognizer reset: new partial is shorter than last partial
                        // and doesn't start with the same prefix → new segment started.
                        if !self.lastPartialText.isEmpty && !text.hasPrefix(self.lastPartialText.prefix(10)) {
                            // Previous partial was a completed segment — commit it
                            let committed = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !committed.isEmpty {
                                self.confirmedText = self.confirmedText.isEmpty ? committed
                                    : self.confirmedText + " " + committed
                                appLog("[SpeechRecognizer] segment committed: \(committed.prefix(40))")
                            }
                        }
                        self.lastPartialText = text
                        // Show full accumulated text in overlay
                        let display = self.confirmedText.isEmpty ? text
                            : self.confirmedText + " " + text
                        self.onPartialResult?(display)
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    appLog("[SpeechRecognizer] error code=\(nsError.code) \(nsError.localizedDescription)")
                    // Suppress cancellation errors (code 301) — these are expected on stopRecording()
                    if nsError.code != 301 {
                        self.onError?(error)
                    }
                }
            }
        }
    }

    /// Stop microphone capture. Triggers isFinal delivery via endAudio().
    /// Calling this when not recording is a no-op.
    func stopRecording() {
        guard isRecording else {
            appLog("[SpeechRecognizer] stopRecording() called but not recording — ignoring")
            return
        }

        appLog("[SpeechRecognizer] stopRecording() — calling endAudio, keeping recognitionTask alive for isFinal")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false

        // endAudio() signals end of input — the recognizer will deliver isFinal naturally.
        // Keep recognitionTask alive so the final result callback fires.
        // Both are cleaned up inside the recognition callback when isFinal arrives.
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    // MARK: - Amplitude helpers

    /// Compute RMS amplitude from a single-channel PCM buffer.
    /// Runs on the audio tap thread (off main).
    private static func computeRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameCount { sum += channelData[i] * channelData[i] }
        return sqrt(sum / Float(frameCount))
    }
}
