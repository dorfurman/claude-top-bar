import AppKit
import CryptoKit
import Foundation

// MARK: - Sign in with Claude
//
// CrabBar authenticates on its own instead of reading Claude Code's keychain item:
// that item's ACL resets every time Claude Code rewrites it, which meant recurring
// permission dialogs. Our own item is owned by our signature, so reads are silent.
//
// The flow is Anthropic's standard PKCE flow: open claude.ai/oauth/authorize in the
// browser, the user approves and pastes back the code shown, we exchange it for an
// access + refresh token pair and refresh on our own from then on.
// ponytail: this uses Claude Code's public OAuth client id; a shipped product should
// register its own client with Anthropic.

enum Auth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    struct Creds: Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
    }

    // MARK: Storage — CrabBar's own keychain item; never triggers an access dialog.

    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.furmanlabs.crabbar",
        kSecAttrAccount as String: "oauth",
    ]

    private static let lock = NSLock()
    /// nil = not read yet, .some(nil) = known absent. Keychain is only hit once per change.
    private static var cache: Creds??

    private static func load() -> Creds? {
        if let c = cache { return c }
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let c = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
            ? (out as? Data).flatMap { try? JSONDecoder().decode(Creds.self, from: $0) } : nil
        cache = .some(c)
        return c
    }

    private static func store(_ c: Creds?) {
        cache = .some(c)
        SecItemDelete(base as CFDictionary)
        guard let c, let d = try? JSONEncoder().encode(c) else { return }
        var q = base
        q[kSecValueData as String] = d
        SecItemAdd(q as CFDictionary, nil)
    }

    static var isSignedIn: Bool { lock.withLock { load() != nil } }

    static func signOut() { lock.withLock { store(nil) } }

    /// A valid access token, refreshed when within a minute of expiry. Blocks on the
    /// network during a refresh, so never call on the main thread (fetchUsage doesn't).
    /// If the refresh can't be completed the stale token is returned and the resulting
    /// 401 surfaces as "sign in again" in the UI.
    static func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let c = load() else { return nil }
        if c.expiresAt > Date().addingTimeInterval(60) { return c.access }
        guard let fresh = post(["grant_type": "refresh_token",
                                "refresh_token": c.refresh,
                                "client_id": clientID]) else { return c.access }
        store(fresh)
        return fresh.access
    }

    // MARK: Browser flow

    /// PKCE verifier for the sign-in currently in flight. Static so the pasted code can
    /// still be exchanged after the popover has closed and reopened.
    private static var verifier = ""

    /// Starts a fresh sign-in: rolls a new verifier and returns the URL to open.
    static func signInURL() -> URL {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var u = URLComponents(string: "https://claude.ai/oauth/authorize")!
        u.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        return u.url!
    }

    /// Exchanges the pasted approval code ("code#state") for tokens. Calls back on main.
    static func exchange(_ pasted: String, done: @escaping (Bool) -> Void) {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#")
        let v = verifier
        DispatchQueue.global(qos: .userInitiated).async {
            let c = post(["grant_type": "authorization_code",
                          "code": String(parts.first ?? ""),
                          "state": parts.count > 1 ? String(parts[1]) : v,
                          "client_id": clientID,
                          "redirect_uri": redirectURI,
                          "code_verifier": v])
            if let c { lock.withLock { store(c) } }
            DispatchQueue.main.async { done(c != nil) }
        }
    }

    /// Blocking POST to the token endpoint; nil on any failure.
    private static func post(_ body: [String: String]) -> Creds? {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        var creds: Creds?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = o["access_token"] as? String else { return }
            creds = Creds(
                access: access,
                refresh: o["refresh_token"] as? String ?? body["refresh_token"] ?? "",
                expiresAt: Date().addingTimeInterval((o["expires_in"] as? Double) ?? 3600))
        }.resume()
        sem.wait()
        return creds
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
