import Foundation

/// What went wrong with a transcription attempt, reduced to the facts the fallback
/// decision needs. The app maps concrete errors (CloudTranscriptionError,
/// StreamingTranscriptionError, URLError …) onto this; the policy itself has no app or
/// provider dependencies so it can be unit tested with `swift test` (see Package.swift).
enum TranscriptionFailure: Equatable {
    case offline
    case timeout
    case connectionFailed
    /// HTTP status when known. 5xx, 408 and 429 are the provider's problem, not ours.
    case http(status: Int)
    case serverError
    case keyRejected
    case keyMissing
    case noSpeech
    case cancelled
    case unsupportedModel
    case badAudio
    case unknown
}

enum FallbackReason: Equatable {
    /// The cloud answered, but with nothing in it. Seen when the websocket errors mid-way:
    /// the speech is real, so the local model gets a turn rather than pasting nothing.
    case emptyResult
    case offline
    case timeout
    case providerUnavailable
    case keyRejected
    case keyMissing
}

enum FallbackDecision: Equatable {
    /// Transcribe the same audio with the local model and say so on screen.
    case fallBackToLocal(FallbackReason)
    /// Fallback was warranted but no local model is ready: show both problems.
    case fallbackUnavailable(FallbackReason)
    /// Say "No speech detected", distinct from a failure, so a dead mic is recognisable.
    case reportNoSpeech
    /// A real failure that a different model would not fix. Keep it loud.
    case reportError
    case cancel
}

enum TranscriptionFallbackPolicy {
    static func decide(
        _ failure: TranscriptionFailure,
        usedCloudModel: Bool,
        localModelReady: Bool
    ) -> FallbackDecision {
        switch failure {
        case .cancelled:
            return .cancel
        case .noSpeech:
            return .reportNoSpeech
        default:
            break
        }

        guard usedCloudModel, let reason = fallbackReason(for: failure) else {
            return .reportError
        }

        return localModelReady ? .fallBackToLocal(reason) : .fallbackUnavailable(reason)
    }

    /// Checked when recording stops: known-offline skips the cloud attempt entirely instead
    /// of waiting out its timeout.
    static func shouldSkipCloud(networkReachable: Bool, localModelReady: Bool) -> Bool {
        !networkReachable && localModelReady
    }

    static func fallbackReason(for failure: TranscriptionFailure) -> FallbackReason? {
        switch failure {
        case .offline:
            return .offline
        case .timeout:
            return .timeout
        case .connectionFailed, .serverError:
            return .providerUnavailable
        case .http(let status):
            switch status {
            case 401, 403:
                return .keyRejected
            case 408:
                return .timeout
            case 429, 500...599:
                return .providerUnavailable
            default:
                return nil
            }
        case .keyRejected:
            return .keyRejected
        case .keyMissing:
            return .keyMissing
        case .noSpeech, .cancelled, .unsupportedModel, .badAudio, .unknown:
            return nil
        }
    }
}
