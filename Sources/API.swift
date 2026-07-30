import Foundation

// MARK: - Usage

/// One rate-limit window as claude.ai reports it. `utilization` is a percentage 0–100 of
/// the real cap — the number the site itself shows — so nothing here is estimated.
struct Window {
    let utilization: Double
    let resetsAt: Date?

    var fraction: Double { min(1, max(0, utilization / 100)) }
}

struct Usage {
    var fiveHour: Window?
    var sevenDay: Window?
    /// Per-model weekly windows ("Opus", "Fable", …), one per seven_day_<model> key in the
    /// response — no hard-coded model list, so new models show up without a code change.
    var models: [(name: String, window: Window)] = []
    var fetchedAt = Date()
}

/// Persisted so the badge can draw at its final width the moment the app launches, instead
/// of stepping empty → "🦀 —" → "🦀 44% 2h05m" as the scan and the API land — three widths
/// in two seconds reads as a flicker in the menu bar.
///
/// Only the two windows the badge can show are kept, and only while their reset is still in
/// the future: an expired window's percentage is wrong, not merely old. `fetchedAt` is
/// stored too, so the popover's "updated N ago" line stays honest.
extension Usage {
    private static let key = "lastUsage"

    private static func flatten(_ w: Window?) -> [String: Any]? {
        guard let w, let r = w.resetsAt else { return nil }
        return ["u": w.utilization, "r": isoString(r)]
    }

    private static func window(_ any: Any?) -> Window? {
        guard let d = any as? [String: Any], let u = d["u"] as? Double,
              let r = (d["r"] as? String).flatMap(parseDate), r > Date()
        else { return nil }
        return Window(utilization: u, resetsAt: r)
    }

    func cache() {
        var d: [String: Any] = ["at": isoString(fetchedAt)]
        if let f = Usage.flatten(fiveHour) { d["five"] = f }
        if let s = Usage.flatten(sevenDay) { d["seven"] = s }
        UserDefaults.standard.set(d, forKey: Usage.key)
    }

    /// Dropped on sign-out: the figures belong to the account that just left.
    static func clearCache() { UserDefaults.standard.removeObject(forKey: key) }

    static var cached: Usage? {
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        let five = window(d["five"]), seven = window(d["seven"])
        guard five != nil || seven != nil else { return nil }
        return Usage(fiveHour: five, sevenDay: seven,
                     fetchedAt: (d["at"] as? String).flatMap(parseDate) ?? .distantPast)
    }
}

enum UsageError: Error, CustomStringConvertible {
    case noCredentials
    case rateLimited
    case unauthorized
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .noCredentials: return "Not signed in — click the crab and sign in with Claude."
        case .rateLimited: return "claude.ai is rate-limiting usage checks; backing off."
        case .unauthorized: return "Session expired — sign in with Claude again."
        case .http(let c): return "claude.ai returned HTTP \(c)."
        case .transport(let m): return m
        }
    }
}

private let USAGE_URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

/// The endpoint hands out 429s aggressively to clients that don't identify as Claude Code.
private let USER_AGENT = "claude-code/2.0.0 (external, cli)"

private func window(_ any: Any?) -> Window? {
    guard let d = any as? [String: Any], let u = d["utilization"] as? NSNumber else { return nil }
    return Window(utilization: u.doubleValue,
                  resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
}

/// Calls back on an arbitrary queue. Auth.token() can block on a token refresh, so the
/// whole thing is pushed off the caller's thread.
func fetchUsage(_ done: @escaping (Result<Usage, UsageError>) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        guard let token = Auth.token() else { return done(.failure(.noCredentials)) }
        send(token: token, done)
    }
}

private func send(token: String, _ done: @escaping (Result<Usage, UsageError>) -> Void) {
    var r = URLRequest(url: USAGE_URL)
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    r.setValue(USER_AGENT, forHTTPHeaderField: "User-Agent")
    r.timeoutInterval = 15

    URLSession.shared.dataTask(with: r) { data, resp, err in
        if let err { return done(.failure(.transport(err.localizedDescription))) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403: return done(.failure(.unauthorized))
        case 429: return done(.failure(.rateLimited))
        default: return done(.failure(.http(code)))
        }
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return done(.failure(.transport("unreadable response"))) }
        if CommandLine.arguments.contains("--raw") {
            print(String(data: data, encoding: .utf8) ?? "")
        }
        // claude.ai's own UI reads the `limits` array; scoped entries carry the display
        // name ("Fable", …). Older responses only have flat seven_day_<model> keys.
        var models = (o["limits"] as? [[String: Any]] ?? []).compactMap { l -> (String, Window)? in
            guard let scope = l["scope"] as? [String: Any],
                  let name = ((scope["model"] as? [String: Any])?["display_name"] as? String)
                      ?? ((scope["surface"] as? [String: Any])?["display_name"] as? String),
                  let p = l["percent"] as? NSNumber else { return nil }
            return (name, Window(utilization: p.doubleValue,
                                 resetsAt: (l["resets_at"] as? String).flatMap(parseDate)))
        }
        if models.isEmpty {
            let prefix = "seven_day_"
            models = o.keys.filter { $0.hasPrefix(prefix) }.sorted().compactMap { key in
                window(o[key]).map {
                    (String(key.dropFirst(prefix.count))
                        .replacingOccurrences(of: "_", with: " ").capitalized, $0)
                }
            }
        }
        done(.success(Usage(
            fiveHour: window(o["five_hour"]),
            sevenDay: window(o["seven_day"]),
            models: models)))
    }.resume()
}
