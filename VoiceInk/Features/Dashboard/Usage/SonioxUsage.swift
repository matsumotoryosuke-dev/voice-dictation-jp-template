import Foundation

/// What Soniox has charged, read from its own usage API so the user does not have to
/// open the Soniox console. Soniox reports cost per UTC day; months here are
/// UTC months too, so the first hours of a month west of UTC count toward the previous
/// one. No prepaid balance is available from the API, so none is shown.
enum SonioxUsage {
    struct Month: Equatable {
        /// "2026-10"
        let month: String
        let costUSD: Decimal
        let audioMinutes: Double
        let requests: Int
    }

    struct Summary: Equatable {
        let thisMonth: Month
        let lastMonth: Month
    }

    static let endpoint = URL(string: "https://api.soniox.com/v1/usage/summary")!

    /// From the first day of last month to the end of today, both in UTC.
    static func requestURL(now: Date) -> URL {
        let calendar = utcCalendar
        let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: timestamp(lastMonthStart)),
            URLQueryItem(name: "end_time", value: timestamp(tomorrow)),
        ]
        return components.url!
    }

    static func summary(from data: Data, now: Date) throws -> Summary {
        let series = try JSONDecoder().decode(Response.self, from: data).total
        let calendar = utcCalendar
        let thisMonth = monthKey(now, calendar: calendar)
        let lastMonth = monthKey(calendar.date(byAdding: .month, value: -1, to: now)!, calendar: calendar)

        var cost: [String: Decimal] = [:]
        var milliseconds: [String: Int] = [:]
        var requests: [String: Int] = [:]
        for (index, day) in series.days.enumerated() {
            let key = String(day.prefix(7))
            if index < series.costUSD.count, let value = Decimal(string: series.costUSD[index]) {
                cost[key, default: 0] += value
            }
            if index < series.inputAudioDurationMs.count {
                milliseconds[key, default: 0] += series.inputAudioDurationMs[index]
            }
            if index < series.numRequests.count {
                requests[key, default: 0] += series.numRequests[index]
            }
        }

        func month(_ key: String) -> Month {
            Month(month: key, costUSD: cost[key] ?? 0,
                  audioMinutes: Double(milliseconds[key] ?? 0) / 60_000,
                  requests: requests[key] ?? 0)
        }
        return Summary(thisMonth: month(thisMonth), lastMonth: month(lastMonth))
    }

    // MARK: - Wire format

    private struct Response: Decodable {
        let total: Series
    }

    private struct Series: Decodable {
        let days: [String]
        let costUSD: [String]
        let inputAudioDurationMs: [Int]
        let numRequests: [Int]

        enum CodingKeys: String, CodingKey {
            case days
            case costUSD = "cost_usd"
            case inputAudioDurationMs = "input_audio_duration_ms"
            case numRequests = "num_requests"
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
