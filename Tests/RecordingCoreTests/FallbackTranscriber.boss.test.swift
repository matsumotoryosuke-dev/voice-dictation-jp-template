import Testing
@testable import RecordingCore

private struct E: Error, Equatable { let id: Int }

private final class Probe {
    var events: [String] = []
    var classifyCount = 0
}

private typealias Outcome = Result<FallbackOutcome<String>, Error>

private func run(
    _ primary: String = "cloud",
    cloud: Bool = true,
    local: String? = "local",
    reachable: Bool = true,
    results: [String: Result<String, Error>],
    classifyAs: TranscriptionFailure = .unknown,
    cancelDuringPrimary: Bool = false,
    probe: Probe
) async -> Outcome {
    let task = Task { () -> Outcome in
        do {
            return .success(try await FallbackTranscriber.transcribe(
                primary: primary, primaryIsCloud: cloud, local: local, networkReachable: reachable,
                transcribe: { (model: String) async throws -> String in
                    probe.events.append("call:\(model)")
                    if cancelDuringPrimary && model == primary { withUnsafeCurrentTask { $0?.cancel() } }
                    guard let result = results[model] else { throw E(id: -1) }
                    return try result.get()
                },
                classify: { _ in probe.classifyCount += 1; return classifyAs },
                willFallBack: { reason, model in probe.events.append("notice:\(reason):\(model)") }
            ))
        } catch {
            return .failure(error)
        }
    }
    return await task.value
}

private func outcome(_ r: Outcome) -> (String, String, FallbackReason?)? {
    guard case .success(let o) = r else { return nil }
    return (o.text, o.modelUsed, o.fallbackReason)
}

private func errorID(_ r: Outcome) -> Int? {
    guard case .failure(let e) = r else { return nil }
    return (e as? E)?.id
}

private func isCancellation(_ r: Outcome) -> Bool {
    guard case .failure(let e) = r else { return false }
    return e is CancellationError
}

@Test func cloudSuccessUsesOnlyTheCloud() async {
    let p = Probe()
    let r = await run(results: ["cloud": .success("hello")], probe: p)
    #expect(outcome(r)! == ("hello", "cloud", nil))
    #expect(p.events == ["call:cloud"])
    #expect(p.classifyCount == 0)
}

@Test func anEmptyCloudAnswerGetsTheLocalModelRatherThanPastingNothing() async {
    let p = Probe()
    let r = await run(results: ["cloud": .success("   "), "local": .success("ローカルが拾った")], probe: p)
    #expect(outcome(r)! == ("ローカルが拾った", "local", .emptyResult))
    #expect(p.events == ["call:cloud", "notice:emptyResult:local", "call:local"])
}

@Test func anEmptyLocalAnswerIsStillReturned() async {
    // Nothing left to try: the caller reports "no speech", it does not loop.
    let p = Probe()
    let r = await run("p", cloud: false, results: ["p": .success("")], probe: p)
    #expect(outcome(r)! == ("", "p", nil))

    let q = Probe()
    let s = await run(local: nil, results: ["cloud": .success("")], probe: q)
    #expect(outcome(s)! == ("", "cloud", nil))     // no local model to fall back to
}

@Test func cloudFailureFallsBackWithNoticeFirst() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 1)), "local": .success("ローカル")], classifyAs: .timeout, probe: p)
    #expect(outcome(r)! == ("ローカル", "local", .timeout))
    #expect(p.events == ["call:cloud", "notice:timeout:local", "call:local"])
    #expect(p.classifyCount == 1)
}

@Test func rejectedKeyFallsBack() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 5)), "local": .success("k")], classifyAs: .http(status: 401), probe: p)
    #expect(outcome(r)! == ("k", "local", .keyRejected))
}

@Test func knownOfflineSkipsTheCloud() async {
    let p = Probe()
    let r = await run(reachable: false, results: ["local": .success("x")], probe: p)
    #expect(outcome(r)! == ("x", "local", .offline))
    #expect(p.events == ["notice:offline:local", "call:local"])
    #expect(p.classifyCount == 0)
}

@Test func offlineWithoutLocalModelStillTriesCloudThenReportsBoth() async {
    let p = Probe()
    let r = await run(local: nil, reachable: false, results: ["cloud": .failure(E(id: 4))], classifyAs: .offline, probe: p)
    guard case .failure(FallbackTranscriptionError.noLocalModel(let reason, let underlying)) = r else {
        Issue.record("expected noLocalModel, got \(r)"); return
    }
    #expect(reason == .offline)
    #expect((underlying as? E)?.id == 4)
    #expect(p.events == ["call:cloud"])
}

@Test func clientErrorRethrowsTheOriginal() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 6))], classifyAs: .http(status: 400), probe: p)
    #expect(errorID(r) == 6)
    #expect(p.events == ["call:cloud"])
}

@Test func noSpeechIsItsOwnError() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 7))], classifyAs: .noSpeech, probe: p)
    guard case .failure(FallbackTranscriptionError.noSpeech) = r else {
        Issue.record("expected noSpeech, got \(r)"); return
    }
    #expect(p.events == ["call:cloud"])
}

@Test func cancelDecisionRethrowsTheOriginal() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 16))], classifyAs: .cancelled, probe: p)
    #expect(errorID(r) == 16)
    #expect(p.events == ["call:cloud"])
}

@Test func cancellationIsNeverClassified() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(CancellationError())], classifyAs: .offline, probe: p)
    #expect(isCancellation(r))
    #expect(p.classifyCount == 0)
    let q = Probe()
    let s = await run("p", cloud: false, results: ["p": .failure(CancellationError())], classifyAs: .timeout, probe: q)
    #expect(isCancellation(s))
    #expect(q.classifyCount == 0)
}

@Test func escapeRightAfterCloudFailureStartsNoLocalWork() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 13)), "local": .success("no")], classifyAs: .timeout,
                      cancelDuringPrimary: true, probe: p)
    #expect(isCancellation(r))
    #expect(p.events == ["call:cloud"])
}

@Test func cancellationDuringLocalIsRethrown() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 1)), "local": .failure(CancellationError())], classifyAs: .timeout, probe: p)
    #expect(isCancellation(r))
}

@Test func localFailureCarriesTheLocalError() async {
    let p = Probe()
    let r = await run(results: ["cloud": .failure(E(id: 1)), "local": .failure(E(id: 10))], classifyAs: .timeout, probe: p)
    guard case .failure(FallbackTranscriptionError.localFailedAfterCloud(let reason, let underlying)) = r else {
        Issue.record("expected localFailedAfterCloud, got \(r)"); return
    }
    #expect(reason == .timeout)
    #expect((underlying as? E)?.id == 10)
    #expect(p.events == ["call:cloud", "notice:timeout:local", "call:local"])

    let q = Probe()
    let s = await run(reachable: false, results: ["local": .failure(E(id: 15))], probe: q)
    guard case .failure(FallbackTranscriptionError.localFailedAfterCloud(let r2, let u2)) = s else {
        Issue.record("expected localFailedAfterCloud, got \(s)"); return
    }
    #expect(r2 == .offline)
    #expect((u2 as? E)?.id == 15)
}

@Test func aLocalPrimaryNeverFallsBack() async {
    let p = Probe()
    let r = await run("p", cloud: false, results: ["p": .failure(E(id: 9))], classifyAs: .timeout, probe: p)
    #expect(errorID(r) == 9)
    #expect(p.events == ["call:p"])

    let q = Probe()
    let s = await run("p", cloud: false, reachable: false, results: ["p": .success("q")], probe: q)
    #expect(outcome(s)! == ("q", "p", nil))
}
