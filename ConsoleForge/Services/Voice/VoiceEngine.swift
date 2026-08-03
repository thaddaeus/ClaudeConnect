import AVFoundation
import Foundation
import Speech

/// Continuous on-device transcription of the microphone.
///
/// Built on macOS 26's `SpeechAnalyzer` rather than `SFSpeechRecognizer`: it runs
/// entirely on-device, has no per-request duration cap, and streams volatile results
/// (a live caption) alongside finalized ones. Nothing leaves the machine.
///
/// **Echo.** The whole point of always-on listening is that the mic is open while
/// `SpeechOutput` is speaking — so without acoustic echo cancellation the synthesizer
/// dictates Claude's own replies back into the transcriber, and the wake phrase can
/// trigger on speech the app itself produced. `setVoiceProcessingEnabled(true)` on the
/// input node turns on the same AEC the system uses for calls, which is why it is set
/// before the engine starts and why failure to enable it is surfaced rather than
/// swallowed.
///
/// **Endpointing.** `SpeechDetector` says whether speech is present right now.
/// Utterances are cut on a silence window rather than on a fixed timer, so a pause
/// mid-sentence doesn't truncate a command.
@available(macOS 26.0, *)
@MainActor
final class VoiceEngine {

    /// Finalized utterance, cut at a silence boundary. The router decides what it means.
    var onUtterance: ((String) -> Void)?
    /// Live (volatile) transcription, for the panel caption.
    var onCaption: ((String) -> Void)?
    /// Coarse input level 0…1, for the meter.
    var onLevel: ((Float) -> Void)?
    /// State changes worth showing the user (downloading a model, mic denied, running).
    var onStatus: ((VoiceMicStatus) -> Void)?

    private(set) var isRunning = false

    /// How long speech must be absent before the accumulated text is treated as a
    /// finished utterance.
    private let silenceWindow: TimeInterval = 1.1

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private var resultsTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    /// Finalized text accumulated since the last utterance boundary.
    private var pendingUtterance = ""

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        onStatus?(.preparing)

        guard await requestAuthorization() else {
            onStatus?(.denied)
            return
        }

        let locale = Locale.current
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let detector = SpeechDetector()
        self.transcriber = transcriber
        self.detector = detector

        // The locale's model may not be on disk yet — this is a real download on first run.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber, detector]) {
                onStatus?(.downloadingModel(0))
                let progress = request.progress
                let watcher = Task { [weak self] in
                    while !Task.isCancelled && !progress.isFinished {
                        try? await Task.sleep(for: .milliseconds(400))
                        await MainActor.run { self?.onStatus?(.downloadingModel(progress.fractionCompleted)) }
                    }
                }
                try await request.downloadAndInstall()
                watcher.cancel()
            }
        } catch {
            onStatus?(.failed("Speech model unavailable: \(error.localizedDescription)"))
            return
        }

        // The analyzer picks the format it wants; the mic gives us whatever the device
        // runs at, so a converter sits between them.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector]) else {
            onStatus?(.failed("No compatible audio format for on-device transcription."))
            return
        }
        self.analyzerFormat = analyzerFormat

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
        self.analyzer = analyzer

        consumeResults(from: transcriber)
        consumeSpeechActivity(from: detector)

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            onStatus?(.failed("Could not start transcription: \(error.localizedDescription)"))
            return
        }

        do {
            try startAudioCapture(convertingTo: analyzerFormat)
        } catch {
            onStatus?(.failed(error.localizedDescription))
            await stopAnalyzer()
            return
        }

        isRunning = true
        onStatus?(.listening)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        silenceTask?.cancel(); silenceTask = nil
        resultsTask?.cancel(); resultsTask = nil
        detectorTask?.cancel(); detectorTask = nil

        inputContinuation?.finish()
        inputContinuation = nil
        pendingUtterance = ""

        Task { await stopAnalyzer() }
        onStatus?(.off)
    }

    private func stopAnalyzer() async {
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        detector = nil
        converter = nil
    }

    // MARK: - Audio capture

    private func startAudioCapture(convertingTo analyzerFormat: AVAudioFormat) throws {
        let input = audioEngine.inputNode

        // AEC — see the note on this type. Must be set before the engine starts.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Not fatal, but the user should know: without it, always-on listening will
            // hear the app's own speech.
            onStatus?(.echoCancellationUnavailable)
        }

        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw VoiceEngineError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw VoiceEngineError.incompatibleFormat
        }
        self.converter = converter

        // The tap runs on a real-time audio thread: no main-actor hops, no allocation-
        // heavy work, just convert and yield.
        let continuation = inputContinuation
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
            let level = Self.peakLevel(of: buffer)
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[i]))
        }
        return min(1, peak * 2.2)
    }

    // MARK: - Results

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.appendFinalized(text)
                    } else {
                        self.onCaption?(text)
                    }
                }
            } catch {
                guard let self, self.isRunning else { return }
                self.onStatus?(.failed("Transcription stopped: \(error.localizedDescription)"))
            }
        }
    }

    /// Speech present/absent drives the utterance boundary.
    private func consumeSpeechActivity(from detector: SpeechDetector) {
        detectorTask = Task { [weak self] in
            do {
                for try await result in detector.results {
                    guard let self else { return }
                    if result.speechDetected {
                        self.silenceTask?.cancel()
                        self.silenceTask = nil
                    } else {
                        self.scheduleUtteranceFlush()
                    }
                }
            } catch {
                // The detector failing only costs us endpointing; the silence timer
                // below still fires from the transcriber's own cadence.
            }
        }
    }

    private func appendFinalized(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingUtterance = pendingUtterance.isEmpty ? trimmed : pendingUtterance + " " + trimmed
        onCaption?(pendingUtterance)
        // Belt and braces: if the detector never reports silence (it can stay quiet on
        // some inputs), the utterance still closes on this timer.
        scheduleUtteranceFlush()
    }

    private func scheduleUtteranceFlush() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.silenceWindow ?? 1.1))
            guard !Task.isCancelled, let self else { return }
            self.flushUtterance()
        }
    }

    private func flushUtterance() {
        let utterance = pendingUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingUtterance = ""
        silenceTask = nil
        guard !utterance.isEmpty else { return }
        onCaption?("")
        onUtterance?(utterance)
    }

    // MARK: - Authorization

    private func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

enum VoiceEngineError: LocalizedError {
    case noInputDevice
    case incompatibleFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device is available."
        case .incompatibleFormat: return "The microphone format can't be converted for transcription."
        }
    }
}

/// Mic status, declared outside the macOS 26 gate so the panel and controller can hold
/// it on any OS version.
enum VoiceMicStatus: Equatable {
    case off
    case preparing
    case downloadingModel(Double)
    case listening
    case denied
    case echoCancellationUnavailable
    case failed(String)
    /// The OS is too old for `SpeechAnalyzer`.
    case unsupported

    var isListening: Bool { self == .listening }

    var summary: String {
        switch self {
        case .off: return "mic off"
        case .preparing: return "starting…"
        case .downloadingModel(let p): return "downloading model \(Int(p * 100))%"
        case .listening: return "listening"
        case .denied: return "mic access denied"
        case .echoCancellationUnavailable: return "listening (no echo cancellation)"
        case .failed(let message): return message
        case .unsupported: return "requires macOS 26"
        }
    }
}
