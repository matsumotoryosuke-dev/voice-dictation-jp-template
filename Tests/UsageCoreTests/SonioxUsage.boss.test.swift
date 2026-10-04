import Foundation
import Testing
@testable import UsageCore

// Boss-written. The response shape is Soniox's GET /v1/usage/summary as documented and as
// it answers; the figures are made up.

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private let response = """
{"total": {"model": null,
  "days": ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"],
  "total_cost_usd": "0.3",
  "cost_usd": ["0.0500000000", "0.0628000000", "0.1000000000", "0.0000000000", "0.0857000000"],
  "input_audio_duration_ms": [1500000, 1800000, 3000000, 0, 960000],
  "num_requests": [20, 25, 40, 0, 11],
  "duration_ms": [1500000, 1800000, 3000000, 0, 960000]},
 "models": []}
"""

@Test func thisMonthAndLastMonthAreSummedFromTheDailyFigures() throws {
    let summary = try SonioxUsage.summary(from: Data(response.utf8), now: date("2026-10-03T20:00:00Z"))
    #expect(summary.thisMonth.month == "2026-10")
    #expect(summary.thisMonth.costUSD == Decimal(string: "0.1857"))
    #expect(summary.thisMonth.requests == 51)
    #expect(abs(summary.thisMonth.audioMinutes - 66.0) < 0.001)
    #expect(summary.lastMonth.month == "2026-09")
    #expect(summary.lastMonth.costUSD == Decimal(string: "0.1128"))
    #expect(abs(summary.lastMonth.audioMinutes - 55.0) < 0.001)
}

@Test func aMonthWithNoUseIsZeroNotMissing() throws {
    let summary = try SonioxUsage.summary(from: Data(response.utf8), now: date("2026-12-05T00:00:00Z"))
    #expect(summary.thisMonth == SonioxUsage.Month(month: "2026-12", costUSD: 0, audioMinutes: 0, requests: 0))
    #expect(summary.lastMonth.costUSD == 0)
}

@Test func theRequestCoversLastMonthThroughToday() {
    let url = SonioxUsage.requestURL(now: date("2026-10-03T20:00:00Z"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(url.host == "api.soniox.com")
    #expect(url.path == "/v1/usage/summary")
    #expect(items.first { $0.name == "start_time" }?.value == "2026-09-01T00:00:00Z")
    #expect(items.first { $0.name == "end_time" }?.value == "2026-10-04T00:00:00Z")
}

@Test func januaryLooksBackToDecember() {
    let url = SonioxUsage.requestURL(now: date("2027-01-15T08:00:00Z"))
    let start = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        .first { $0.name == "start_time" }?.value
    #expect(start == "2026-12-01T00:00:00Z")
}

@Test func aBrokenAnswerThrowsRatherThanShowingZero() {
    #expect(throws: (any Error).self) {
        _ = try SonioxUsage.summary(from: Data(#"{"error": "unauthorized"}"#.utf8), now: Date())
    }
}
