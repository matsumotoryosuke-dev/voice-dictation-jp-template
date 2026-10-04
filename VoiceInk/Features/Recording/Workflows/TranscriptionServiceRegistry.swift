import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()
    private var cachedTranscribeCppTranscriptionService: TranscribeCppTranscriptionService?

    /// True when a local model is downloaded and can take over from a failed stream.
    /// Set by the engine; without it the cloud's own upload path stays as the safety net.
    var hasLocalFallback: () -> Bool = { false }

    var transcribeCppTranscriptionService: TranscribeCppTranscriptionService {
        if let cachedTranscribeCppTranscriptionService {
            return cachedTranscribeCppTranscriptionService
        }
        let service = TranscribeCppTranscriptionService()
        cachedTranscribeCppTranscriptionService = service
        return service
    }

    init(modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .transcribeCpp:
            return transcribeCppTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        return try await service.transcribe(audioURL: audioURL, model: model, context: context.scoped(to: model))
    }

    /// Creates a streaming or file-based session for the resolved transcription configuration.
    func createSession(
        for configuration: TranscriptionRuntimeConfiguration, onPartialTranscript: ((String) -> Void)? = nil
    ) -> TranscriptionSession {
        let model = configuration.model

        if shouldUseRealtimeTranscription(for: configuration) {
            let streamingService = StreamingTranscriptionService(
                modelContext: modelContext,
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript
            )
            let fallback = service(for: model.provider)
            // When the websocket does not finalise, uploading the file to the same cloud
            // costs four round trips (3-8 s measured). With a local model downloaded we
            // would rather throw here and let the pipeline run Whisper on-device, which
            // also says on screen why the text came from the local model.
            return StreamingTranscriptionSession(
                streamingService: streamingService,
                fallbackService: fallback,
                isBatchFallbackEnabled: { [weak self] in self?.hasLocalFallback() != true })
        } else {
            return FileTranscriptionSession(service: service(for: model.provider))
        }
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled
    }

    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
        cachedTranscribeCppTranscriptionService?.cleanup()
    }
}
