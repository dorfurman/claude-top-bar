import AppKit

// MARK: - Updates
// Checks the repo's latest GitHub release, at most every 6h. The result lives in
// UserDefaults so the indicator survives relaunches; the repo must stay public for
// the unauthenticated API call to work.

struct Update {
    let version: String
    let url: URL        // release page — the fallback when an in-app install can't work
    let zip: URL?       // the release's CrabBar-x.y.z.zip asset
    func open() { NSWorkspace.shared.open(url) }
}

enum Updates {
    static let repo = "dorfurman/claude-top-bar"
    static let installed = URL(fileURLWithPath: "/Applications/CrabBar.app")

    /// Another copy of this app — matched by bundle id, not by name, since the whole problem
    /// is that the copies are named "CrabBar 2.app", "CrabBar 3.app", …
    static func isOurBundle(_ url: URL) -> Bool {
        url.pathExtension == "app"
            && Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// An update unzips to wherever the user downloaded it, and Finder refuses to overwrite a
    /// running app — so they end up with "CrabBar 2.app" beside the old one, both launched,
    /// two menu bar items, and "CrabBar 3.app" next time. Fix it at launch: quit any other
    /// copy of us, then make sure the copy that survives is /Applications/CrabBar.app.
    static func consolidate() {
        let me = Bundle.main.bundleURL
        let fm = FileManager.default

        // Same bundle id = another copy of us, holding its own status item.
        for app in NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") where app != .current {
            app.terminate()
            // The move below replaces its bundle, so let it actually go first.
            for _ in 0..<40 where !app.isTerminated { usleep(50_000) }
            if !app.isTerminated { app.forceTerminate() }
        }

        // Sweep the "CrabBar 2.app" copies Finder already left behind, so a stale login item
        // can't keep launching one and they stop accumulating a number per update.
        for name in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [] {
            let u = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
            if u != installed, u != me, isOurBundle(u) { try? fm.removeItem(at: u) }
        }

        // Already home, or running out of the source checkout (./build.sh && open CrabBar.app).
        guard me != installed,
              !fm.fileExists(atPath: me.deletingLastPathComponent()
                                       .appendingPathComponent("build.sh").path)
        else { return }

        do {
            if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
            // Launched straight from the download, Gatekeeper translocates us to a read-only
            // path, so the move fails and only a copy can get us into /Applications.
            do { try fm.moveItem(at: me, to: installed) }
            catch { try fm.copyItem(at: me, to: installed) }
        } catch {
            return   // no write access to /Applications — keep running where we are
        }
        // Relaunch from the new path: Bundle.main (and the login item it registers) still
        // points at the bundle we just moved out from under ourselves.
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-n", installed.path])
        exit(0)
    }

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The latest release seen on GitHub, if it's newer than what's running.
    static var available: Update? {
        let d = UserDefaults.standard
        guard let v = d.string(forKey: "latestVersion"), newer(v, than: current),
              let u = d.string(forKey: "latestURL").flatMap(URL.init(string:))
        else { return nil }
        return Update(version: v, url: u,
                      zip: d.string(forKey: "latestZip").flatMap(URL.init(string:)))
    }

    /// One-click update: download the release zip, verify it's our own signed build, then just
    /// launch it out of the temp dir — consolidate() in that copy moves it into /Applications
    /// and quits us. Anything unexpected falls back to opening the release page by hand.
    static func install(_ u: Update, status: @escaping (String) -> Void = { _ in }) {
        guard let zip = u.zip else { u.open(); return }
        status("Downloading v\(u.version)…")
        URLSession.shared.downloadTask(with: zip) { tmp, _, _ in
            let app = tmp.flatMap(unpack)
            DispatchQueue.main.async {
                guard let app else {
                    status("Update failed — opening the release page")
                    u.open()
                    return
                }
                status("Restarting…")
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"),
                                     arguments: ["-n", app.path])
            }
        }.resume()
    }

    /// Unzip into a fresh temp dir and hand back the .app only if it's the notarized build from
    /// the personal team in build.sh — this is downloaded code, so nothing else gets launched.
    /// (A locally ad-hoc-signed build fails this, which is why install() keeps the fallback.)
    static func unpack(_ zip: URL) -> URL? {
        let team = "23F3TUG54Q"   // must match TEAM in build.sh
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CrabBarUpdate-\(UUID().uuidString)")
        guard let _ = try? FileManager.default.createDirectory(at: dir,
                                                              withIntermediateDirectories: true),
              sh("/usr/bin/ditto", ["-xk", zip.path, dir.path]).ok
        else { return nil }
        let app = dir.appendingPathComponent("CrabBar.app")
        let signature = sh("/usr/bin/codesign", ["--verify", "--strict", "-dvv", app.path])
        guard signature.ok, signature.out.contains("TeamIdentifier=\(team)"),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { return nil }
        return app
    }

    private static func sh(_ tool: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        (p.standardOutput, p.standardError) = (pipe, pipe)
        guard let _ = try? p.run() else { return (false, "") }
        // drain before waiting: a full pipe would deadlock the child
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: out, as: UTF8.self))
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
            let zip = (j["assets"] as? [[String: Any]] ?? []).lazy
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
            DispatchQueue.main.async {
                d.set(zip, forKey: "latestZip")
                let seen = d.string(forKey: "latestVersion")
                d.set(v, forKey: "latestVersion")
                d.set(url.absoluteString, forKey: "latestURL")
                if v != seen, let u = available { onNew(u) }
            }
        }.resume()
    }
}
