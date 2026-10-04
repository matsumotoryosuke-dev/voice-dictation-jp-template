import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    /// Local model to use when a cloud model fails, or nil when none is downloaded.
    private let fallbackModel: () -> (any TranscriptionModel)?
    private let isNetworkReachable: () -> Bool
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?,
        fallbackModel: @escaping () -> (any TranscriptionModel)? = { nil },
        isNetworkReachable: @escaping () -> Bool = { true }
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.fallbackModel = fallbackModel
        self.isNetworkReachable = isNetworkReachable
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        sendAfterPaste: Bool = false,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            let usesCloud = Self.isCloudModel(model)
            let outcome = try await FallbackTranscriber.transcribe(
                primary: model,
                primaryIsCloud: usesCloud,
                local: usesCloud ? fallbackModel() : nil,
                networkReachable: isNetworkReachable(),
                transcribe: { candidate in
                    if candidate.id == model.id {
                        if let session {
                            return try await session.transcribe(audioURL: audioURL)
                        }
                        return try await self.serviceRegistry.transcribe(
                            audioURL: audioURL,
                            model: model,
                            context: transcriptionConfiguration.requestContext
                        )
                    }
                    // Falling back: the cloud session is finished with, whatever state it is in.
                    session?.cancel()
                    return try await self.serviceRegistry.transcribe(
                        audioURL: audioURL,
                        model: candidate,
                        context: transcriptionConfiguration.requestContext.scoped(to: candidate)
                    )
                },
                classify: { error in
                    TranscriptionFailureMapper.failure(for: error, networkReachable: self.isNetworkReachable())
                },
                willFallBack: { reason, localModel in
                    NotificationManager.shared.showNotification(
                        title: Self.fallbackNotice(reason, localModel: localModel),
                        type: .warning,
                        duration: 6.0
                    )
                }
            )
            let modelUsed = outcome.modelUsed
            var text = TranscriptionOutputFilter.filter(outcome.text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                // Distinguishable from a failed request, so a dead microphone is recognisable.
                // Nothing is delivered either: pasting an empty string wipes whatever the
                // paste path had in the clipboard and looks like the key did nothing.
                NotificationManager.shared.showNotification(
                    title: String(localized: "No speech detected"),
                    type: .warning,
                    duration: 4.0
                )
                transcription.text = ""
                transcription.duration = await AudioFileMetadata.duration(for: audioURL)
                transcription.transcriptionModelName = modelUsed.displayName
                transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
                DictationJournal.append(DictationJournalEntry(
                    clipSeconds: transcription.duration,
                    levelDecibels: AudioFileMetadata.meanLevelDecibels(for: audioURL),
                    apiSeconds: transcriptionDuration,
                    model: modelUsed.displayName,
                    characters: 0,
                    fallbackReason: outcome.fallbackReason.map { String(describing: $0) },
                    error: "empty transcript"))
                do {
                    try modelContext.save()
                } catch {
                    logger.error("Failed to save empty transcription: \(error, privacy: .public)")
                }
                await onDismiss()
                return
            }

            if !assistant.isFollowUp,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = modelUsed.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            DictationJournal.append(DictationJournalEntry(
                clipSeconds: actualDuration,
                levelDecibels: AudioFileMetadata.meanLevelDecibels(for: audioURL),
                apiSeconds: transcriptionDuration,
                model: modelUsed.displayName,
                characters: cleanedText.count,
                fallbackReason: outcome.fallbackReason.map { String(describing: $0) },
                error: nil))

            if !assistant.isFollowUp {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement =
                    !shouldRespondInRecorder && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let contextSnapshot = await recordingContextSnapshot()
                        transcription.aiEnhancementModelName =
                            resolvedEnhancementConfiguration.modelName
                            ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = resolvedEnhancementConfiguration.prompt?.title
                        let enhancementResult = try await enhancementService.enhance(
                            textForAI,
                            configuration: resolvedEnhancementConfiguration,
                            contextSnapshot: contextSnapshot
                        )
                        transcription.enhancedText = enhancementResult.text
                        transcription.promptName =
                            enhancementResult.promptName ?? resolvedEnhancementConfiguration.prompt?.title
                        transcription.enhancementDuration = enhancementResult.duration
                        transcription.aiRequestSystemMessage = enhancementResult.systemMessage
                        transcription.aiRequestUserMessage = enhancementResult.userMessage
                        finalText = enhancementResult.text
                    } catch {
                        let errorDescription = EnhancementFailureFormatter.description(for: error)
                        let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
                        transcription.enhancedText = failureMessage
                        responseError = errorDescription
                        // One toast at a time: keep the fallback notice visible if there was one.
                        let title = outcome.fallbackReason.map {
                            Self.fallbackNotice($0, localModel: modelUsed) + "\n" + failureMessage
                        } ?? failureMessage
                        await MainActor.run {
                            NotificationManager.shared.showNotification(
                                title: title,
                                type: .warning,
                                duration: outcome.fallbackReason == nil ? 3.0 : 6.0
                            )
                        }
                        if shouldCancel() {
                            await finishCanceledTranscription()
                            return
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            if error is CancellationError || shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            let errorDescription = Self.failureDescription(for: error)

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError {
                if nativeAppleError.shouldShowNotification {
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: errorDescription,
                            type: .error,
                            duration: 5.0
                        )
                    }
                }
            } else {
                // Failures used to be silent here; a dictation key that quietly does nothing
                // is worse than one that errors.
                let isNoSpeech: Bool
                if case FallbackTranscriptionError.noSpeech = error { isNoSpeech = true } else { isNoSpeech = false }
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: isNoSpeech ? .warning : .error,
                        duration: 6.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue

            DictationJournal.append(DictationJournalEntry(
                clipSeconds: await AudioFileMetadata.duration(for: audioURL),
                levelDecibels: AudioFileMetadata.meanLevelDecibels(for: audioURL),
                apiSeconds: nil,
                model: model.displayName,
                characters: 0,
                fallbackReason: nil,
                error: errorDescription))
        }

        func saveTranscriptionAndPostCompletion() {
            var didInsertSessionMetric = false

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp,
                sendAfterPaste: sendAfterPaste
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        saveTranscriptionAndPostCompletion()
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}

// MARK: - Cloud → local fallback

extension TranscriptionPipeline {
    static func isCloudModel(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .whisper, .fluidAudio, .transcribeCpp, .nativeApple:
            return false
        default:
            return true
        }
    }

    /// The downloaded local model used when the cloud fails: a multilingual Whisper model,
    /// largest first, because the speech this fork is for mixes Japanese and English.
    static func preferredLocalFallback(from usableModels: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        let candidates = usableModels.filter { $0.provider == .whisper && $0.isMultilingualModel }
        let preference = ["large-v3-turbo", "large-v3", "large", "medium", "small", "base", "tiny"]
        for fragment in preference {
            if let model = candidates.first(where: { $0.name.contains(fragment) }) {
                return model
            }
        }
        return candidates.first
    }

    static func fallbackNotice(_ reason: FallbackReason, localModel: any TranscriptionModel) -> String {
        String(format: String(localized: "%@. Transcribed locally with %@, which is less accurate."),
               reasonText(reason), localModel.displayName)
    }

    static func failureDescription(for error: Error) -> String {
        switch error {
        case FallbackTranscriptionError.noSpeech:
            return String(localized: "No speech detected — nothing was recorded")
        case FallbackTranscriptionError.noLocalModel(let reason, _):
            return String(format: String(localized: "%@, and no local model is downloaded to fall back to."),
                          reasonText(reason))
        case FallbackTranscriptionError.localFailedAfterCloud(let reason, let underlying):
            return String(format: String(localized: "%@, and the local model also failed: %@"),
                          reasonText(reason), describe(underlying))
        default:
            return describe(error)
        }
    }

    private static func reasonText(_ reason: FallbackReason) -> String {
        switch reason {
        case .emptyResult: return String(localized: "The cloud returned no text")
        case .offline: return String(localized: "You are offline")
        case .timeout: return String(localized: "The cloud transcription timed out")
        case .providerUnavailable: return String(localized: "The cloud transcription service is unavailable")
        case .keyRejected: return String(localized: "The cloud API key was rejected")
        case .keyMissing: return String(localized: "No cloud API key is set")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
