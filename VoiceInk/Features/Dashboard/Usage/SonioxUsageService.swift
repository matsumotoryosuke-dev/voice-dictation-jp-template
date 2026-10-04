import Foundation
import OSLog

/// Fetches Soniox's own record of what it has charged, with the key VoiceInk already
/// uses for transcription. Refreshes when the dashboard appears, at most every 10 minutes.
@MainActor
final class SonioxUsageService: ObservableObject {
    static let shared = SonioxUsageService()

    enum State: Equatable {
        case idle
        case loading
        case loaded(SonioxUsage.Summary, fetchedAt: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SonioxUsage")
    private static let freshness: TimeInterval = 10 * 60
    private var lastAttempt: Date?

    var hasKey: Bool {
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Soniox") else { return false }
        return !key.isEmpty
    }

    func refreshIfStale(force: Bool = false) async {
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.freshness { return }
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Soniox"), !key.isEmpty else {
            state = .failed(String(localized: "Add a Soniox API key to see its usage."))
            return
        }
        lastAttempt = Date()
        if case .loaded = state {} else { state = .loading }

        let now = Date()
        var request = URLRequest(url: SonioxUsage.requestURL(now: now), timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                logger.error("Soniox usage request failed status=\(status, privacy: .public)")
                state = .failed(
                    status == 401
                        ? String(localized: "Soniox rejected the API key.")
                        : String(format: String(localized: "Soniox usage is unavailable (HTTP %d)."), status))
                return
            }
            state = .loaded(try SonioxUsage.summary(from: data, now: now), fetchedAt: now)
        } catch {
            logger.error("Soniox usage request failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(localized: "Couldn't reach Soniox to read usage."))
        }
    }
}
