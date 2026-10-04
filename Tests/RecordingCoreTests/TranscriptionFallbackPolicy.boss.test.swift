import Testing
@testable import RecordingCore

private func cloud(_ failure: TranscriptionFailure, localReady: Bool = true) -> FallbackDecision {
    TranscriptionFallbackPolicy.decide(failure, usedCloudModel: true, localModelReady: localReady)
}

@Test func networkProblemsFallBackToLocal() {
    #expect(cloud(.offline) == .fallBackToLocal(.offline))
    #expect(cloud(.timeout) == .fallBackToLocal(.timeout))
    #expect(cloud(.connectionFailed) == .fallBackToLocal(.providerUnavailable))
    #expect(cloud(.serverError) == .fallBackToLocal(.providerUnavailable))
}

@Test func httpStatusesThatAreTheProvidersProblemFallBack() {
    #expect(cloud(.http(status: 500)) == .fallBackToLocal(.providerUnavailable))
    #expect(cloud(.http(status: 503)) == .fallBackToLocal(.providerUnavailable))
    #expect(cloud(.http(status: 599)) == .fallBackToLocal(.providerUnavailable))
    #expect(cloud(.http(status: 429)) == .fallBackToLocal(.providerUnavailable))
    #expect(cloud(.http(status: 408)) == .fallBackToLocal(.timeout))
}

@Test func keyProblemsFallBackAndAreNamed() {
    #expect(cloud(.http(status: 401)) == .fallBackToLocal(.keyRejected))
    #expect(cloud(.http(status: 403)) == .fallBackToLocal(.keyRejected))
    #expect(cloud(.keyRejected) == .fallBackToLocal(.keyRejected))
    #expect(cloud(.keyMissing) == .fallBackToLocal(.keyMissing))
}

@Test func otherClientErrorsStayLoud() {
    #expect(cloud(.http(status: 400)) == .reportError)
    #expect(cloud(.http(status: 404)) == .reportError)
    #expect(cloud(.http(status: 413)) == .reportError)
    #expect(cloud(.http(status: 600)) == .reportError)
    #expect(cloud(.unsupportedModel) == .reportError)
    #expect(cloud(.badAudio) == .reportError)
    #expect(cloud(.unknown) == .reportError)
}

@Test func noSpeechAndCancelAreNeverFailures() {
    #expect(cloud(.noSpeech) == .reportNoSpeech)
    #expect(cloud(.noSpeech, localReady: false) == .reportNoSpeech)
    #expect(cloud(.cancelled) == .cancel)
    #expect(TranscriptionFallbackPolicy.decide(.noSpeech, usedCloudModel: false, localModelReady: true) == .reportNoSpeech)
}

@Test func missingLocalModelReportsBothProblems() {
    #expect(cloud(.offline, localReady: false) == .fallbackUnavailable(.offline))
    #expect(cloud(.http(status: 401), localReady: false) == .fallbackUnavailable(.keyRejected))
    #expect(cloud(.http(status: 400), localReady: false) == .reportError)
}

@Test func aLocalModelFailureHasNothingToFallBackTo() {
    #expect(TranscriptionFallbackPolicy.decide(.timeout, usedCloudModel: false, localModelReady: true) == .reportError)
    #expect(TranscriptionFallbackPolicy.decide(.offline, usedCloudModel: false, localModelReady: true) == .reportError)
}

@Test func knownOfflineSkipsCloudOnlyWhenLocalIsReady() {
    #expect(TranscriptionFallbackPolicy.shouldSkipCloud(networkReachable: false, localModelReady: true))
    #expect(!TranscriptionFallbackPolicy.shouldSkipCloud(networkReachable: false, localModelReady: false))
    #expect(!TranscriptionFallbackPolicy.shouldSkipCloud(networkReachable: true, localModelReady: true))
}
