import Foundation
import LLMkit

enum TranscriptionFailureMapper {
    static func failure(for error: Error, networkReachable: Bool) -> TranscriptionFailure {
        if error is CancellationError {
            return .cancelled
        }

        guard networkReachable else {
            return .offline
        }

        if let error = error as? CloudTranscriptionError {
            switch error {
            case .missingAPIKey:
                return .keyMissing
            case .invalidAPIKey:
                return .keyRejected
            case .apiRequestFailed(let statusCode, _):
                return .http(status: statusCode)
            case .networkError(let underlying):
                return failureForNetworkOrLLMError(underlying)
            case .noTranscriptionReturned:
                // In dictation this nearly always means the clip held no speech; saying
                // "the API returned nothing" blames the service for a silent recording.
                return .noSpeech
            case .audioFileNotFound, .dataEncodingError:
                return .badAudio
            case .unsupportedModel, .unsupportedProvider:
                return .unsupportedModel
            }
        }

        if let error = error as? StreamingTranscriptionError {
            switch error {
            case .missingAPIKey:
                return .keyMissing
            case .connectionFailed, .notConnected:
                return .connectionFailed
            case .timeout:
                return .timeout
            case .serverError:
                return .serverError
            case .audioConversionFailed:
                return .badAudio
            }
        }

        return failureForNetworkOrLLMError(error)
    }

    private static func failureForNetworkOrLLMError(_ error: Error) -> TranscriptionFailure {
        if let error = error as? LLMKitError {
            switch error {
            case .timeout:
                return .timeout
            case .missingAPIKey:
                return .keyMissing
            case .httpError(let statusCode, _):
                return .http(status: statusCode)
            case .networkError:
                return .connectionFailed
            case .invalidURL, .decodingError, .noResultReturned, .encodingError, .unsupportedModel:
                return .unknown
            }
        }

        if let error = error as? URLError {
            return failure(for: error.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return failure(for: code)
        }

        if nsError.domain == "LLMkit" {
            return .connectionFailed
        }

        return .unknown
    }

    private static func failure(for code: URLError.Code) -> TranscriptionFailure {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .cannotFindHost,
             .dnsLookupFailed:
            return .offline

        case .timedOut:
            return .timeout

        case .cannotConnectToHost,
             .secureConnectionFailed:
            return .connectionFailed

        default:
            return .connectionFailed
        }
    }
}
