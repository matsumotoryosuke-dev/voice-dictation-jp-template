import Foundation
import Network

final class NetworkReachabilityMonitor {
    static let shared = NetworkReachabilityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "VoiceInk.NetworkReachabilityMonitor")
    private let lock = NSLock()

    private var started = false
    private var reachable = true

    var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    private init() {}

    func start() {
        lock.lock()
        let shouldStart = !started
        if shouldStart {
            started = true
        }
        lock.unlock()

        guard shouldStart else {
            return
        }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            self.lock.lock()
            self.reachable = path.status == .satisfied
            self.lock.unlock()
        }

        monitor.start(queue: queue)
    }
}
