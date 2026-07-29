import AppKit

// MARK: - Updates
// Checks the repo's latest GitHub release, at most every 6h. The result lives in
// UserDefaults so the indicator survives relaunches; the repo must stay public for
// the unauthenticated API call to work.

struct Update {
    let version: String
    let url: URL
    func open() { NSWorkspace.shared.open(url) }
}

enum Updates {
    static let repo = "dorfurman/claude-top-bar"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The latest release seen on GitHub, if it's newer than what's running.
    static var available: Update? {
        let d = UserDefaults.standard
        guard let v = d.string(forKey: "latestVersion"), newer(v, than: current),
              let u = d.string(forKey: "latestURL").flatMap(URL.init(string:))
        else { return nil }
        return Update(version: v, url: u)
    }

    /// a > b, numeric per dotted component, missing components read as 0.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    /// `onNew` fires on the main queue the first time a given version shows up —
    /// that's the hook for the one-shot notification.
    static func check(onNew: @escaping (Update) -> Void) {
        let d = UserDefaults.standard
        if let last = d.object(forKey: "updateCheckedAt") as? Date,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        d.set(Date(), forKey: "updateCheckedAt")

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String,
                  let url = (j["html_url"] as? String).flatMap(URL.init(string:))
            else { return }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                let seen = d.string(forKey: "latestVersion")
                d.set(v, forKey: "latestVersion")
                d.set(url.absoluteString, forKey: "latestURL")
                if v != seen, let u = available { onNew(u) }
            }
        }.resume()
    }
}
