import Foundation

struct FallbackOutcome<Model> {
    let text: String
    let modelUsed: Model
    let fallbackReason: FallbackReason?
}

enum FallbackTranscriptionError: Error {
    case noSpeech
    case noLocalModel(reason: FallbackReason, underlying: Error)
    case localFailedAfterCloud(reason: FallbackReason, underlying: Error)
}

enum FallbackTranscriber {
    static func transcribe<Model>(
        primary: Model,
        primaryIsCloud: Bool,
        local: Model?,
        networkReachable: Bool,
        transcribe: (Model) async throws -> String,
        classify: (Error) -> TranscriptionFailure,
        willFallBack: (FallbackReason, Model) async -> Void
    ) async throws -> FallbackOutcome<Model> {
        if primaryIsCloud,
           let local,
           TranscriptionFallbackPolicy.shouldSkipCloud(
               networkReachable: networkReachable,
               localModelReady: true
           ) {
            await willFallBack(.offline, local)
            do {
                let text = try await transcribe(local)
                return FallbackOutcome(text: text, modelUsed: local, fallbackReason: .offline)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw FallbackTranscriptionError.localFailedAfterCloud(
                    reason: .offline,
                    underlying: error
                )
            }
        }

        do {
            let text = try await transcribe(primary)
            // A cloud model that answers with nothing has not transcribed the speech: the
            // local model gets a turn before the user is told there was no speech.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                primaryIsCloud, let local
            {
                if Task.isCancelled { throw CancellationError() }
                await willFallBack(.emptyResult, local)
                do {
                    let localText = try await transcribe(local)
                    return FallbackOutcome(text: localText, modelUsed: local, fallbackReason: .emptyResult)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw FallbackTranscriptionError.localFailedAfterCloud(reason: .emptyResult,
                                                                          underlying: error)
                }
            }
            return FallbackOutcome(text: text, modelUsed: primary, fallbackReason: nil)
        } catch let error as CancellationError {
            throw error
        } catch {
            let originalError = error
            let failure = classify(originalError)
            let decision = TranscriptionFallbackPolicy.decide(
                failure,
                usedCloudModel: primaryIsCloud,
                localModelReady: local != nil
            )

            switch decision {
            case .cancel:
                throw originalError

            case .reportNoSpeech:
                throw FallbackTranscriptionError.noSpeech

            case .reportError:
                throw originalError

            case .fallbackUnavailable(let reason):
                throw FallbackTranscriptionError.noLocalModel(
                    reason: reason,
                    underlying: originalError
                )

            case .fallBackToLocal(let reason):
                guard let local else {
                    throw FallbackTranscriptionError.noLocalModel(
                        reason: reason,
                        underlying: originalError
                    )
                }

                if Task.isCancelled {
                    throw CancellationError()
                }

                await willFallBack(reason, local)

                do {
                    let text = try await transcribe(local)
                    return FallbackOutcome(text: text, modelUsed: local, fallbackReason: reason)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw FallbackTranscriptionError.localFailedAfterCloud(
                        reason: reason,
                        underlying: error
                    )
                }
            }
        }
    }
}
