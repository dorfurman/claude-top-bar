import AppKit
import Foundation

// MARK: - Live session tracker
//
// A session is one .jsonl file. Whether the agent is working or waiting is written in the
// file's own tail: after the user sends a prompt or a tool returns, the last message entry
// is a `user` one until the assistant finishes replying; a trailing assistant `tool_use`
// means a tool is still executing. A trailing assistant text turn means the agent is done
// and the chat is waiting on the human.

struct LiveSession: Identifiable {
    let id: String       // file path
    let title: String
    let project: String
    let cwd: String?     // the chat's working directory, for routing back to its terminal
    let working: Bool
    let modified: Date
}

let SESSION_HORIZON: TimeInterval = 30 * 60
/// ponytail: a session whose transcript stopped moving is no longer "working" no matter
/// what its last entry says (Esc-interrupted turns and crashed CLIs both strand a user
/// entry at the tail). 2 min of silence demotes to idle; shorten if it feels sticky.
let WORKING_TTL: TimeInterval = 120

/// Reads only the tail of each recently-modified file, walking lines from the end until it
/// has a verdict, a title and a cwd. Kept separate from scan() so it stays testable and
/// never parses more than it needs.
func classifySession(_ lines: [Substring]) -> (working: Bool, title: String?, cwd: String?) {
    var working: Bool?
    var title: String?
    var cwd: String?
    for line in lines.reversed() {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { continue }
        if cwd == nil, let c = o["cwd"] as? String { cwd = c }
        if title == nil, let t = o["aiTitle"] as? String, !t.isEmpty { title = t }
        if working == nil, let type = o["type"] as? String {
            if type == "user" {
                working = true
            } else if type == "assistant" {
                let content = (o["message"] as? [String: Any])?["content"]
                let last = (content as? [[String: Any]])?.last?["type"] as? String
                working = last == "tool_use"
            }
        }
        if working != nil, title != nil, cwd != nil { break }
    }
    return (working ?? false, title, cwd)
}

private func tailLines(of url: URL, bytes: Int = 128 * 1024) -> [Substring] {
    guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? h.seek(toOffset: start)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8)
    else { return [] }
    var lines = text.split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial first line
    return lines
}

func liveSessions(root: URL, now: Date = Date()) -> [LiveSession] {
    var out: [LiveSession] = []
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }
    for case let url as URL in walker {
        guard url.pathExtension == "jsonl",
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(mtime) < SESSION_HORIZON
        else { continue }
        let (working, title, cwd) = classifySession(tailLines(of: url))
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? url.deletingLastPathComponent().lastPathComponent
        out.append(LiveSession(
            id: url.path,
            title: title ?? project,
            project: project,
            cwd: cwd,
            working: working && now.timeIntervalSince(mtime) < WORKING_TTL,
            modified: mtime))
    }
    return out.sorted { ($0.working ? 1 : 0, $0.modified) > ($1.working ? 1 : 0, $1.modified) }
}

// MARK: - Routing back to a chat
//
// Nothing in ~/.claude records which terminal a chat runs in — no tty, no pid, not in the
// transcript either. The one thing both ends share is the working directory: find a running
// `claude` whose cwd is this chat's cwd, take its tty, and have the terminal app that owns
// that tty select the matching tab.
//
// ponytail: cwd is the only available key, so two chats in one directory can't be told
// apart — the first match wins. An unscriptable terminal (or a chat that has since exited)
// degrades to activating the terminal app, which is still where the user wants to be.

private func sh(_ tool: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The .app bundle a terminal process belongs to, by walking up the process tree until a
/// binary inside one shows up (claude → zsh → login → Terminal.app/…).
private func terminalBundle(of pid: String) -> URL? {
    var pid = pid
    for _ in 0..<12 {
        let fields = sh("/bin/ps", ["-o", "ppid=,comm=", "-p", pid])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
        guard fields.count == 2 else { return nil }
        let comm = fields[1].trimmingCharacters(in: .whitespaces)
        if let dot = comm.range(of: ".app/") {
            return URL(fileURLWithPath: comm[comm.startIndex..<dot.lowerBound] + ".app")
        }
        pid = String(fields[0])
        if pid == "1" || pid == "0" { return nil }
    }
    return nil
}

/// Terminal and iTerm2 can both select a tab by tty; anything else just gets activated.
private func selectTab(in bundle: URL, tty: String) {
    let script: String? = {
        guard !tty.isEmpty else { return nil }
        switch Bundle(url: bundle)?.bundleIdentifier {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default: return nil
        }
    }()
    // Automation permission is asked for on first use, and can be refused — a failed
    // script falls through to plain activation rather than doing nothing.
    if let script {
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err == nil { return }
    }
    NSWorkspace.shared.openApplication(at: bundle, configuration: .init())
}

func focusSession(cwd: String?) {
    let pids = sh("/usr/bin/pgrep", ["-x", "claude"])
        .split(separator: "\n").map(String.init)
    guard !pids.isEmpty else { return }

    // one lsof for all candidates: -Fpn prints "p<pid>" then "n<cwd>" per process
    var owner: String?
    var pid: String?
    for line in sh("/usr/sbin/lsof",
                   ["-a", "-d", "cwd", "-Fpn", "-p", pids.joined(separator: ",")])
        .split(separator: "\n") {
        if line.hasPrefix("p") { pid = String(line.dropFirst()) }
        else if line.hasPrefix("n"), String(line.dropFirst()) == cwd { owner = pid; break }
    }

    // no cwd match (chat exited, or cd'd away): any live chat's terminal is still the
    // right app to bring forward, just not the right tab
    let target = owner ?? pids[0]
    guard let bundle = terminalBundle(of: target) else { return }
    let tty = sh("/bin/ps", ["-o", "tty=", "-p", target])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    selectTab(in: bundle, tty: tty.isEmpty || owner == nil ? "" : "/dev/\(tty)")
}
