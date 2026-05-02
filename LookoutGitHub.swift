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
    // Returned verbatim on 304 Not Modified so that the user-visible
    // "needs attention" state persists across polls until either the
    // user resolves the thread (mark-as-read on github.com or via our
    // markAllNotificationsRead) or GitHub emits a 200 with a different
    // (possibly empty) list.
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

        let (notif, review, failing) = try await (notifications, reviewRequested, failingPRs)

        var seen = Set<String>()
        var combined: [LookoutItem] = []
        for item in notif.items + review + failing {
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
        if let lm = notificationsLastModified {
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
        return try await fetchSearchIssues(token: token, query: q, kind: .ciFailure)
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

    private func parseISODate(_ s: String) -> Date? {
        Self.isoFormatter.date(from: s)
    }
}
