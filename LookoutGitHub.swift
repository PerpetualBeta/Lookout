import Foundation

enum LookoutItemKind: String {
    case mention
    case reviewRequested
    case assigned
    case comment
    case stateChange
    case ciFailure
    case prThread
    case issueThread
    case other

    var symbolName: String {
        switch self {
        case .mention:         "at"
        case .reviewRequested: "eye"
        case .assigned:        "person.crop.circle.badge.checkmark"
        case .comment:         "bubble.left"
        case .stateChange:     "arrow.triangle.branch"
        case .ciFailure:       "xmark.octagon"
        case .prThread:        "arrow.triangle.pull"
        case .issueThread:     "smallcircle.filled.circle"
        case .other:           "bell"
        }
    }
}

struct LookoutItem: Identifiable, Hashable {
    let id: String
    let kind: LookoutItemKind
    let title: String
    let repo: String
    let url: URL
    let updatedAt: Date

    static let dedupeKey: (LookoutItem) -> String = { $0.url.absoluteString }
}

enum LookoutGitHubError: Error, LocalizedError {
    case unauthorized(detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, detail: String)
    case transport(Error)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):     "GitHub rejected the token: \(detail)"
        case .rateLimited:                  "GitHub rate limit reached. Will retry shortly."
        case .http(let code, let detail):   "GitHub HTTP \(code): \(detail)"
        case .transport(let err):           err.localizedDescription
        case .decode(let msg):              "Could not parse GitHub response: \(msg)"
        }
    }
}

struct LookoutPollResult {
    let items: [LookoutItem]
    let nextPollAfter: TimeInterval
    let notificationsLastModified: String?
}

actor LookoutGitHubClient {
    private let session: URLSession
    private var notificationsLastModified: String?
    // Items parsed from the most recent 200 OK on /notifications.
    // Returned verbatim on 304 Not Modified. A 304 is only trusted while
    // this cache is EMPTY — Last-Modified moves on new notifications but
    // not on read-state changes, so it can prove nothing has arrived, but
    // never that nothing has departed (see fetchNotifications).
    private var notificationsCache: [LookoutItem] = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func setNotificationsLastModified(_ value: String?) {
        self.notificationsLastModified = value
    }

    func poll(token: String) async throws -> LookoutPollResult {
        async let notifications = fetchNotifications(token: token)
        async let reviewRequested = fetchReviewRequested(token: token)
        async let failingPRs = fetchFailingPRs(token: token)
        async let ownedThreads = fetchOwnedRepoThreads(token: token)

        let (notif, review, failing, owned) = try await (notifications, reviewRequested, failingPRs, ownedThreads)

        var seen = Set<String>()
        var combined: [LookoutItem] = []
        // Owned-repo threads last so that if the same one also arrived via a
        // notification (when the repo *is* watched), the richer notification
        // entry wins the dedupe.
        for item in notif.items + review + failing + owned {
            let key = LookoutItem.dedupeKey(item)
            if seen.insert(key).inserted {
                combined.append(item)
            }
        }
        combined.sort { $0.updatedAt > $1.updatedAt }

        return LookoutPollResult(
            items: combined,
            nextPollAfter: notif.pollInterval,
            notificationsLastModified: notif.lastModified
        )
    }

    func markAllNotificationsRead(token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/notifications")!)
        request.httpMethod = "PUT"
        applyAuth(&request, token: token)
        let body = try JSONSerialization.data(withJSONObject: [
            "last_read_at": ISO8601DateFormatter().string(from: Date()),
            "read": true,
        ])
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        // GitHub-side state just changed; clear the cache and the
        // If-Modified-Since marker so the next poll forces a 200 with a
        // fresh list (rather than risking a 304 that revives the items
        // the user just dismissed).
        notificationsCache = []
        notificationsLastModified = nil
    }

    private func applyAuth(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lookout/1.0", forHTTPHeaderField: "User-Agent")
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 304: return
        case 401, 403:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
                let wait = reset.map { max(0, $0 - Date().timeIntervalSince1970) }
                throw LookoutGitHubError.rateLimited(retryAfter: wait)
            }
            throw LookoutGitHubError.unauthorized(detail: Self.detail(http: http, data: data))
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw LookoutGitHubError.rateLimited(retryAfter: retry)
        default:
            throw LookoutGitHubError.http(http.statusCode, detail: Self.detail(http: http, data: data))
        }
    }

    private static func detail(http: HTTPURLResponse, data: Data) -> String {
        var pieces: [String] = []
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = body["message"] as? String { pieces.append(msg) }
            if let url = body["documentation_url"] as? String, !url.isEmpty { pieces.append("(\(url))") }
        }
        let path = http.url?.path ?? "?"
        if let scopes = http.value(forHTTPHeaderField: "X-Accepted-OAuth-Scopes"), !scopes.isEmpty {
            pieces.append("needs scopes: \(scopes)")
        }
        if let have = http.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            pieces.append("token has: \(have.isEmpty ? "(none)" : have)")
        }
        if let sso = http.value(forHTTPHeaderField: "X-GitHub-SSO"), !sso.isEmpty {
            pieces.append("SSO: \(sso)")
        }
        pieces.append("[\(path)]")
        return pieces.joined(separator: " ")
    }

    // MARK: Notifications

    private struct NotificationsResult {
        let items: [LookoutItem]
        let pollInterval: TimeInterval
        let lastModified: String?
    }

    private func fetchNotifications(token: String) async throws -> NotificationsResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/notifications")!)
        applyAuth(&request, token: token)
        // If-Modified-Since can only signal ARRIVALS. GitHub's Last-Modified
        // on /notifications does not move when a thread is read elsewhere —
        // resolve everything on github.com and this endpoint 304s for ever,
        // so a non-empty cache would keep a ghost on screen indefinitely
        // (it did: twelve hours, one read thread). Use the conditional
        // request only while we're showing nothing; while items are on
        // screen, poll unconditionally so departures are seen too.
        if notificationsCache.isEmpty, let lm = notificationsLastModified {
            request.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        let http = response as? HTTPURLResponse
        let pollInterval = http?.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init) ?? 60
        let newLastModified = http?.value(forHTTPHeaderField: "Last-Modified") ?? notificationsLastModified

        if http?.statusCode == 304 {
            return NotificationsResult(items: notificationsCache, pollInterval: pollInterval, lastModified: newLastModified)
        }

        let raw = try parseJSONArray(data)
        var items: [LookoutItem] = []
        for entry in raw {
            guard let id = entry["id"] as? String,
                  let reason = entry["reason"] as? String,
                  let subject = entry["subject"] as? [String: Any],
                  let title = subject["title"] as? String,
                  let typeStr = subject["type"] as? String,
                  let repository = entry["repository"] as? [String: Any],
                  let repoName = repository["full_name"] as? String,
                  let updatedAtStr = entry["updated_at"] as? String,
                  let updatedAt = parseISODate(updatedAtStr)
            else { continue }

            let url = browserURLForNotification(subject: subject, repoName: repoName)
            let kind = mapNotificationReason(reason, type: typeStr)
            items.append(LookoutItem(
                id: "notif-\(id)",
                kind: kind,
                title: title,
                repo: repoName,
                url: url,
                updatedAt: updatedAt
            ))
        }

        notificationsCache = items
        return NotificationsResult(items: items, pollInterval: pollInterval, lastModified: newLastModified)
    }

    private func mapNotificationReason(_ reason: String, type: String) -> LookoutItemKind {
        switch reason {
        case "mention", "team_mention":      return .mention
        case "review_requested":             return .reviewRequested
        case "assign":                       return .assigned
        case "comment":                      return .comment
        case "state_change", "ci_activity":  return reason == "ci_activity" ? .ciFailure : .stateChange
        case "author", "subscribed", "manual":
            return type == "PullRequest" ? .prThread : .issueThread
        default:
            return .other
        }
    }

    private func browserURLForNotification(subject: [String: Any], repoName: String) -> URL {
        if let apiURL = subject["url"] as? String,
           let url = URL(string: apiURL) {
            // Convert API URL → web URL.
            // Examples:
            //   api.github.com/repos/foo/bar/issues/12  → github.com/foo/bar/issues/12
            //   api.github.com/repos/foo/bar/pulls/12   → github.com/foo/bar/pull/12
            let path = url.path
                .replacingOccurrences(of: "/repos/", with: "/")
                .replacingOccurrences(of: "/pulls/", with: "/pull/")
            return URL(string: "https://github.com\(path)") ?? URL(string: "https://github.com/\(repoName)")!
        }
        return URL(string: "https://github.com/\(repoName)")!
    }

    // MARK: Search — review requested

    private func fetchReviewRequested(token: String) async throws -> [LookoutItem] {
        let q = "is:open is:pr review-requested:@me archived:false"
        return try await fetchSearchIssues(token: token, query: q, kind: .reviewRequested)
    }

    private func fetchFailingPRs(token: String) async throws -> [LookoutItem] {
        let q = "is:open is:pr author:@me status:failure archived:false"
        let candidates = try await fetchSearchIssues(token: token, query: q, kind: .ciFailure)

        // `status:failure` aggregates every check run on the head commit, so a
        // failed suite keeps matching after a later suite passes on the SAME
        // commit. That happens whenever a run is retriggered by reopening the
        // pull request instead of re-running the job: GitHub attaches a second
        // suite and the first one never goes away. The search then reports a
        // failure for ever, `gh pr checks` reports a pass, and nothing the
        // author does clears the row — not merging, and certainly not "Mark all
        // read", which only touches /notifications.
        //
        // Observed on RememberMyWindow#22 on 2026-09-04: one commit, two
        // suites, one failure and one success, and the row would have stayed
        // until the branch got a new head commit.
        //
        // So treat the search as a shortlist and keep an item only when the
        // NEWEST run of some check name really did fail.
        var confirmed: [LookoutItem] = []
        for item in candidates {
            do {
                if try await prIsStillFailing(token: token, item: item) {
                    confirmed.append(item)
                }
            } catch {
                // A check that could not be made is not evidence of success.
                // Keep the item rather than hide a real failure.
                confirmed.append(item)
            }
        }
        return confirmed
    }

    /// True when the most recent run of at least one check name ended badly.
    ///
    /// Grouping by name matters: a commit can carry several runs of one check,
    /// and only the last of them describes the state now.
    private func prIsStillFailing(token: String, item: LookoutItem) async throws -> Bool {
        guard let number = Int(item.url.lastPathComponent) else { return true }

        var prRequest = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(item.repo)/pulls/\(number)")!)
        applyAuth(&prRequest, token: token)
        let (prData, prResponse) = try await session.data(for: prRequest)
        try validate(prResponse, data: prData)
        guard let pr = try JSONSerialization.jsonObject(with: prData) as? [String: Any],
              let head = pr["head"] as? [String: Any],
              let sha = head["sha"] as? String
        else { return true }

        var runsRequest = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(item.repo)/commits/\(sha)/check-runs?per_page=100")!)
        applyAuth(&runsRequest, token: token)
        let (runsData, runsResponse) = try await session.data(for: runsRequest)
        try validate(runsResponse, data: runsData)
        guard let body = try JSONSerialization.jsonObject(with: runsData) as? [String: Any],
              let runs = body["check_runs"] as? [[String: Any]]
        else { return true }

        var newest: [String: (when: Date, conclusion: String)] = [:]
        for run in runs {
            guard let name = run["name"] as? String else { continue }
            let when = (run["completed_at"] as? String).flatMap(parseISODate)
                ?? (run["started_at"] as? String).flatMap(parseISODate)
                ?? Date.distantPast
            let conclusion = (run["conclusion"] as? String) ?? ""
            if let seen = newest[name], seen.when >= when { continue }
            newest[name] = (when, conclusion)
        }

        let bad: Set<String> = ["failure", "timed_out", "action_required"]
        return newest.values.contains { bad.contains($0.conclusion) }
    }

    // MARK: Search — open issues AND pull requests on your own repos
    //
    // The notifications inbox only surfaces threads on repos you're *watching*
    // (subscribed) — one opened by someone else on a repo you own but aren't
    // watching never generates a notification, so it was invisible to Lookout.
    // These queries catch them directly, independent of watch state.
    //
    // PULL REQUESTS WERE MISSING UNTIL 2026-08-09. This search was written for
    // issues and used `is:issue`, which in GitHub search *excludes* PRs. The
    // other two PR queries are `review-requested:@me` and `author:@me`, so a PR
    // opened by someone else on your own repo matched nothing anywhere: no
    // review requested, not authored by you, excluded from the owned-repo
    // search, and no notification because you don't watch your own repo. Three
    // open PRs on QuitProtect sat unseen for three days. Same gap, same fix.
    //
    // `user:<login>` (GitHub search has no @me form for it, so we resolve the
    // login) scopes to repos you own.
    //
    // Finally, each candidate is kept only if it *needs your attention* — i.e.
    // the last person to act on it wasn't you. A fresh thread qualifies; once
    // you reply it drops off until the other party responds again (which also
    // re-arrives via the notifications path once you're a participant).
    private func fetchOwnedRepoThreads(token: String) async throws -> [LookoutItem] {
        // One /user call, both searches concurrent.
        let login = try await authenticatedLogin(token: token)
        async let issues = ownedRepoSearch(token: token, login: login, kind: .issueThread)
        async let prs    = ownedRepoSearch(token: token, login: login, kind: .prThread)
        return try await issues + prs
    }

    private func ownedRepoSearch(token: String, login: String, kind: LookoutItemKind) async throws -> [LookoutItem] {
        let q: String
        if kind == .prThread {
            // No recency window, deliberately. The window on issues exists to keep a repo seeded with
            // hundreds of years-old imported tickets out of the list. Nobody bulk-imports pull requests,
            // and an open PR is a request for your action that does not expire — a two-year-old one you
            // never answered still needs answering.
            q = "is:open is:pr user:\(login) archived:false"
        } else {
            // NO WINDOW BY DEFAULT. This used to default to 365 days, which meant an issue still open on
            // its first birthday silently stopped being reported — precisely the failure this search
            // exists to prevent, just on a delay. An open issue is a request for your action, and it does
            // not expire; the same reasoning as pull requests above.
            //
            // The escape hatch survives for the case it was written for — a repo seeded with hundreds of
            // bulk-imported legacy tickets. Set `Lookout.issueLookbackDays` and only issues created inside
            // that window are considered. Unset, nothing is filtered by age.
            let stored = UserDefaults.standard.integer(forKey: "Lookout.issueLookbackDays")
            if stored > 0 {
                let cutoff = Date().addingTimeInterval(-Double(stored) * 86_400)
                q = "is:open is:issue user:\(login) archived:false created:>=\(Self.ymdFormatter.string(from: cutoff))"
            } else {
                q = "is:open is:issue user:\(login) archived:false"
            }
        }

        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "sort", value: "updated"),
        ]
        var request = URLRequest(url: components.url!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = dict["items"] as? [[String: Any]] else {
            throw LookoutGitHubError.decode("search.items missing")
        }

        // Resolve each candidate's "needs attention" status concurrently.
        return await withTaskGroup(of: LookoutItem?.self) { group in
            for entry in entries {
                group.addTask { await self.ownedThreadNeedingAttention(entry, login: login, token: token, kind: kind) }
            }
            var results: [LookoutItem] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }
    }

    /// Returns a LookoutItem for an owned-repo issue or pull request only if it
    /// currently needs the user's attention — the last actor on the thread
    /// wasn't them. Returns nil if they spoke last. If the last actor can't be
    /// determined, errs toward attention (returns the item) so nothing is
    /// silently dropped.
    ///
    /// Works unchanged for PRs: search returns them in the issue shape, and
    /// `/issues/<n>/comments` is the PR's conversation thread.
    private func ownedThreadNeedingAttention(_ entry: [String: Any], login: String, token: String,
                                             kind: LookoutItemKind) async -> LookoutItem? {
        guard let number = entry["number"] as? Int,
              let title = entry["title"] as? String,
              let htmlURLStr = entry["html_url"] as? String,
              let htmlURL = URL(string: htmlURLStr),
              let updatedAtStr = entry["updated_at"] as? String,
              let updatedAt = parseISODate(updatedAtStr),
              let repoURLStr = entry["repository_url"] as? String
        else { return nil }

        let repoName = String(repoURLStr.split(separator: "/").suffix(2).joined(separator: "/"))
        let author = (entry["user"] as? [String: Any])?["login"] as? String
        let commentCount = entry["comments"] as? Int ?? 0

        // Who acted last? With comments, it's the latest comment's author;
        // with none, it's whoever opened the issue. nil = couldn't tell.
        let lastActor: String?
        var latest: LastComment?
        if commentCount > 0 {
            latest = try? await lastComment(repoFullName: repoName, number: number, commentCount: commentCount, token: token)
            lastActor = latest?.author
        } else {
            lastActor = author
        }

        // Drop it only if we *positively* know the user acted last.
        if let lastActor, lastActor == login { return nil }

        // Speaking is not the only way to act. Reacting to the last comment is
        // how you acknowledge something you have nothing further to add to, and
        // a thread you have thumbed-up is not one waiting on you. Without this,
        // an answered report kept reporting itself: the other party's "thanks,
        // will do" is the last comment for ever, so the thread never clears
        // until it is closed.
        //
        // It corrects itself, which is what makes it safe: the moment they
        // comment again, the last comment is a new one carrying no reaction of
        // yours, and the thread comes straight back.
        if let latest, latest.reactionCount > 0, let commentID = latest.id,
           (try? await hasReacted(login: login, repoFullName: repoName, commentID: commentID, token: token)) == true {
            return nil
        }

        return LookoutItem(
            id: "owned-\(kind.rawValue)-\(repoName)#\(number)",
            kind: kind,
            title: title,
            repo: repoName,
            url: htmlURL,
            updatedAt: updatedAt
        )
    }

    /// The most recent comment on an issue: who wrote it, its id, and how many
    /// reactions it carries. Uses the known comment count to jump straight to
    /// the last page rather than walking every comment.
    private struct LastComment {
        let author: String?
        let id: Int?
        let reactionCount: Int
    }

    private func lastComment(repoFullName: String, number: Int, commentCount: Int, token: String) async throws -> LastComment? {
        guard commentCount > 0 else { return nil }
        let perPage = 100
        let lastPage = max(1, (commentCount + perPage - 1) / perPage)
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/issues/\(number)/comments")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(perPage)"),
            URLQueryItem(name: "page", value: "\(lastPage)"),
        ]
        var request = URLRequest(url: components.url!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let arr = try parseJSONArray(data)
        guard let last = arr.last else { return nil }
        return LastComment(
            author: (last["user"] as? [String: Any])?["login"] as? String,
            id: last["id"] as? Int,
            reactionCount: (last["reactions"] as? [String: Any])?["total_count"] as? Int ?? 0
        )
    }

    /// Whether `login` has reacted to a comment — any reaction, not just a
    /// thumbs-up. Reacting is how you acknowledge something you have no more to
    /// say about, and a 👀 means "seen" as surely as a 👍 does.
    ///
    /// Only called when the comment carries at least one reaction, so a thread
    /// nobody has reacted to costs no extra request.
    private func hasReacted(login: String, repoFullName: String, commentID: Int, token: String) async throws -> Bool {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/issues/comments/\(commentID)/reactions")!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var request = URLRequest(url: components.url!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let arr = try parseJSONArray(data)
        return arr.contains { ($0["user"] as? [String: Any])?["login"] as? String == login }
    }

    /// The token's account login (e.g. "PerpetualBeta"). Resolved per poll
    /// rather than cached, so swapping the token to a different account can't
    /// leave a stale login scoping the search to the wrong repos. `/user` is a
    /// cheap call against a 5000/hr budget.
    private func authenticatedLogin(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = dict["login"] as? String else {
            throw LookoutGitHubError.decode("user.login missing")
        }
        return login
    }

    private func fetchSearchIssues(token: String, query: String, kind: LookoutItemKind) async throws -> [LookoutItem] {
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "sort", value: "updated"),
        ]
        var request = URLRequest(url: components.url!)
        applyAuth(&request, token: token)

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any],
              let items = dict["items"] as? [[String: Any]]
        else {
            throw LookoutGitHubError.decode("search.items missing")
        }

        var results: [LookoutItem] = []
        for entry in items {
            guard let number = entry["number"] as? Int,
                  let title = entry["title"] as? String,
                  let htmlURLStr = entry["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLStr),
                  let updatedAtStr = entry["updated_at"] as? String,
                  let updatedAt = parseISODate(updatedAtStr),
                  let repoURLStr = entry["repository_url"] as? String
            else { continue }

            let repoName = String(repoURLStr.split(separator: "/").suffix(2).joined(separator: "/"))
            results.append(LookoutItem(
                id: "search-\(kind.rawValue)-\(repoName)#\(number)",
                kind: kind,
                title: title,
                repo: repoName,
                url: htmlURL,
                updatedAt: updatedAt
            ))
        }
        return results
    }

    // MARK: Helpers

    private func parseJSONArray(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [[String: Any]] else {
            throw LookoutGitHubError.decode("expected JSON array")
        }
        return array
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// UTC `yyyy-MM-dd` for GitHub search date qualifiers.
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func parseISODate(_ s: String) -> Date? {
        Self.isoFormatter.date(from: s)
    }
}
