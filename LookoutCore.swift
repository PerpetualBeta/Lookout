import Foundation
import AppKit
import Observation

enum LookoutState: Equatable {
    case unconfigured
    case idle
    case polling
    case ok(items: [LookoutItem], lastUpdated: Date)
    // tokenRejected distinguishes "GitHub refused the credential" from every other
    // failure (outage, rate limit, network). The panel offers token re-entry only
    // when the token is actually the suspect — a 503 is GitHub's fault, not the
    // token's, and offering "Re-enter Token…" there invites revoking a perfectly
    // good credential while chasing an outage.
    case error(message: String, tokenRejected: Bool)

    static func == (lhs: LookoutState, rhs: LookoutState) -> Bool {
        switch (lhs, rhs) {
        case (.unconfigured, .unconfigured), (.idle, .idle), (.polling, .polling): return true
        case (.ok(let a, let da), .ok(let b, let db)): return a == b && da == db
        case (.error(let a, let ta), .error(let b, let tb)): return a == b && ta == tb
        default: return false
        }
    }
}

/// How long Lookout waits between automatic checks, in whole minutes. The user sets it in
/// Settings; the Refresh button checks at once whatever it says.
///
/// One minute by default, which is what Lookout always did. Each check is a burst of
/// concurrent requests (four searches, one GraphQL search, and a follow-up per candidate), and
/// on 2026-10-08 a burst a minute drew GitHub's *secondary* rate limit. A longer interval is the
/// cure the user can apply; the six-hour ceiling keeps "automatic" meaning something.
enum LookoutRefresh {
    static let defaultsKey = "Lookout.refreshMinutes"
    static let minutes = 1...360
    static let defaultMinutes = 1

    /// Absent key → the default; present → clamped into range.
    static var storedMinutes: Int {
        let d = UserDefaults.standard
        let raw = d.object(forKey: defaultsKey) == nil ? defaultMinutes : d.integer(forKey: defaultsKey)
        return min(minutes.upperBound, max(minutes.lowerBound, raw))
    }
}

@Observable
final class LookoutCore {
    private(set) var state: LookoutState = .unconfigured
    private(set) var items: [LookoutItem] = []
    private(set) var lastUpdated: Date?

    /// When the next poll is due. Nil while one is in flight, or when the loop is not running.
    ///
    /// The user's interval sets the cadence, GitHub's poll interval and rate limits can only
    /// lengthen it, and a change in Settings moves it, so this cannot be derived from a constant in
    /// the UI. It has to come from the loop that actually schedules the wait.
    private(set) var nextPollAt: Date?

    var unreadCount: Int { items.count }

    private let client = LookoutGitHubClient()
    private var pollTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isAsleep = false

    /// When the last check began. The next one is due one interval after this.
    private var lastPollStartedAt: Date?
    /// The shortest wait GitHub asks for, from `X-Poll-Interval` (60 s in practice).
    private var serverMinimum: TimeInterval = 60
    /// No check before this, whatever the interval says. Set by a rate limit or a failed check.
    private var retryNotBefore: Date?
    /// Rate limits in a row, for the backoff. Reset by any check that succeeds.
    private var consecutiveRateLimits = 0
    /// The wait in progress, so that a new interval can cut it short.
    private var sleeper: Task<Void, Never>?

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
        nextPollAt = nil
    }

    func refreshNow() {
        stop()
        start()
    }

    func tokenWasUpdated() {
        refreshNow()
    }

    /// The user changed the interval in Settings. Move the next check to one new interval after
    /// the last one began, instead of checking now: a stepper click must not send a request.
    /// A rate-limit wait still holds, and a time already past means the check is due now.
    func refreshIntervalChanged() {
        guard pollTask != nil, let started = lastPollStartedAt, nextPollAt != nil else { return }
        nextPollAt = scheduledPoll(after: started)
        lkLog("interval now \(LookoutRefresh.storedMinutes) min; next check \(nextPollAt.map(Self.clock) ?? "-")")
        sleeper?.cancel()
        onStateChange?()
    }

    private var interval: TimeInterval {
        max(serverMinimum, TimeInterval(LookoutRefresh.storedMinutes * 60))
    }

    private func scheduledPoll(after started: Date) -> Date {
        let due = started.addingTimeInterval(interval)
        guard let floor = retryNotBefore else { return due }
        return max(due, floor)
    }

    /// Waits until `due`, or until `refreshIntervalChanged` cuts the wait short, or until the poll
    /// loop is cancelled. The caller re-reads `nextPollAt` afterwards, so an early wake is harmless.
    private func wait(until due: Date) async {
        let delay = max(0, due.timeIntervalSinceNow)
        let s = Task { _ = try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        sleeper = s
        await withTaskCancellationHandler { await s.value } onCancel: { s.cancel() }
        sleeper = nil
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

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

            // Every outcome below sets `nextPollAt`, and a new interval can move it, so the wait
            // happens here, re-reading the deadline each time it ends.
            if let due = nextPollAt, due > Date() {
                await wait(until: due)
                continue
            }

            guard let token = LookoutKeychain.loadToken() else {
                state = .unconfigured
                onStateChange?()
                return
            }

            let started = Date()
            lastPollStartedAt = started
            state = .polling
            nextPollAt = nil                    // a check is happening right now
            onStateChange?()
            lkLog("check started (interval \(LookoutRefresh.storedMinutes) min)")

            do {
                let result = try await client.poll(token: token)
                await client.setNotificationsLastModified(result.notificationsLastModified)
                serverMinimum = max(60, result.nextPollAfter)
                consecutiveRateLimits = 0
                retryNotBefore = nil
                self.items = result.items
                self.lastUpdated = Date()
                // Published before the state change, so the panel never renders an .ok with a stale
                // countdown from the previous cycle.
                self.nextPollAt = scheduledPoll(after: started)
                self.state = .ok(items: result.items, lastUpdated: self.lastUpdated!)
                onStateChange?()
                lkLog("check ok: \(result.items.count) item(s); next \(Self.clock(self.nextPollAt!))")
            } catch is CancellationError {
                return
            } catch let LookoutGitHubError.unauthorized(detail) {
                self.state = .error(message: "GitHub rejected the token.\n\(detail)", tokenRejected: true)
                onStateChange?()
                lkLog("token rejected: \(detail)")
                return
            } catch let LookoutGitHubError.rateLimited(retryAfter) {
                // GitHub's advice for a secondary limit: wait at least a minute, longer each time it
                // repeats. Its own Retry-After or reset time wins when it sends one. The user's
                // interval still applies on top, so a long interval is never shortened by a retry.
                consecutiveRateLimits += 1
                let backoff = min(3600, 120 * pow(2, Double(consecutiveRateLimits - 1)))
                let wait = max(60, retryAfter ?? backoff)
                retryNotBefore = Date().addingTimeInterval(wait)
                self.nextPollAt = scheduledPoll(after: started)
                // A clock time, not "in 5 min": the message is rendered once and would go stale.
                let at = self.nextPollAt!.formatted(date: .omitted, time: .shortened)
                self.state = .error(
                    message: "GitHub is limiting requests. Lookout will try again at \(at).",
                    tokenRejected: false)
                onStateChange?()
                lkLog("rate limited (#\(consecutiveRateLimits) in a row, Retry-After \(retryAfter.map { "\(Int($0))s" } ?? "none")); next \(Self.clock(self.nextPollAt!))")
            } catch {
                retryNotBefore = Date().addingTimeInterval(120)
                self.nextPollAt = retryNotBefore
                self.state = .error(message: error.localizedDescription, tokenRejected: false)
                onStateChange?()
                lkLog("check failed: \(error.localizedDescription); retry \(Self.clock(self.nextPollAt!))")
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
