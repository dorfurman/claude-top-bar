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
            working: working && now.timeIntervalSince(mtime) < WORKING_TTL,
            modified: mtime))
    }
    return out.sorted { ($0.working ? 1 : 0, $0.modified) > ($1.working ? 1 : 0, $1.modified) }
}
