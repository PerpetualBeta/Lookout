import Foundation
import AppKit
import Observation

enum LookoutState: Equatable {
    case unconfigured
    case idle
    case polling
    case ok(items: [LookoutItem], lastUpdated: Date)
    case error(String)

    static func == (lhs: LookoutState, rhs: LookoutState) -> Bool {
        switch (lhs, rhs) {
        case (.unconfigured, .unconfigured), (.idle, .idle), (.polling, .polling): return true
        case (.ok(let a, let da), .ok(let b, let db)): return a == b && da == db
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

@Observable
final class LookoutCore {
    private(set) var state: LookoutState = .unconfigured
    private(set) var items: [LookoutItem] = []
    private(set) var lastUpdated: Date?

    var unreadCount: Int { items.count }

    private let client = LookoutGitHubClient()
    private var pollTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isAsleep = false

    var onStateChange: (() -> Void)?

    init() {
        observeSleepWake()
    }

    deinit {
        if let s = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(s) }
        if let w = wakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(w) }
    }

    func start() {
        guard pollTask == nil else { return }
        if LookoutKeychain.loadToken() == nil {
            state = .unconfigured
            onStateChange?()
            return
        }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        stop()
        start()
    }

    func tokenWasUpdated() {
        refreshNow()
    }

    func markAllRead() {
        guard let token = LookoutKeychain.loadToken() else { return }
        Task {
            try? await client.markAllNotificationsRead(token: token)
            self.refreshNow()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if isAsleep {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            guard let token = LookoutKeychain.loadToken() else {
                state = .unconfigured
                onStateChange?()
                return
            }

            state = .polling
            onStateChange?()

            do {
                let result = try await client.poll(token: token)
                await client.setNotificationsLastModified(result.notificationsLastModified)
                self.items = result.items
                self.lastUpdated = Date()
                self.state = .ok(items: result.items, lastUpdated: self.lastUpdated!)
                onStateChange?()

                let interval = max(60, result.nextPollAfter)
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch is CancellationError {
                return
            } catch let LookoutGitHubError.unauthorized(detail) {
                self.state = .error("GitHub rejected the token.\n\(detail)")
                onStateChange?()
                return
            } catch let LookoutGitHubError.rateLimited(retryAfter) {
                let wait = max(60, retryAfter ?? 120)
                self.state = .error("Rate limited; retrying in \(Int(wait))s")
                onStateChange?()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                self.state = .error(error.localizedDescription)
                onStateChange?()
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            }
        }
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = true
        }
        wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = false
            self?.refreshNow()
        }
    }
}
