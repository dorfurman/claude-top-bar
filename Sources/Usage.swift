import Foundation

let FIVE_HOURS: TimeInterval = 5 * 3600
let WEEK: TimeInterval = 7 * 24 * 3600
let BUCKET: TimeInterval = 600          // 10-minute sparkline buckets
let BUCKETS = Int(FIVE_HOURS / BUCKET)  // 30

// MARK: - Weighting
//
// Nothing here is shown as money. The real limits are percentages and they come from
// claude.ai (see API.swift) — but the API reports one number per window, with no
// breakdown. To split that number across models, over time, and across days, we need a
// per-request weight, and published per-token rates are the best available proxy for
// how much of a window a request consumes. So `cost` below is a relative weight; it is
// only ever rendered as a share or a bar height, never as a dollar figure.

/// Per-million-token rates from the Anthropic pricing reference. Cache reads bill at
/// 0.1x input, 5-minute cache writes at 1.25x, 1-hour writes at 2x.
struct Price {
    let input: Double
    let output: Double
    var fast: (input: Double, output: Double)? = nil
    var intro: (input: Double, output: Double, until: Date)? = nil
}

let AUG_31_2026 = Date(timeIntervalSince1970: 1_788_220_800)  // 2026-08-31T00:00:00Z

let PRICES: [String: Price] = [
    "claude-fable-5": Price(input: 10, output: 50),
    "claude-mythos-5": Price(input: 10, output: 50),
    "claude-opus-5": Price(input: 5, output: 25, fast: (10, 50)),
    "claude-opus-4-8": Price(input: 5, output: 25, fast: (10, 50)),
    "claude-opus-4-7": Price(input: 5, output: 25),
    "claude-opus-4-6": Price(input: 5, output: 25),
    "claude-sonnet-5": Price(input: 3, output: 15, intro: (2, 10, AUG_31_2026)),
    "claude-sonnet-4-6": Price(input: 3, output: 15),
    "claude-haiku-4-5": Price(input: 1, output: 5),
]

/// ponytail: unknown model → Opus rates, and the name is surfaced in the popover
/// so a wrong guess is visible rather than silently folded into the total.
let FALLBACK_PRICE = Price(input: 5, output: 25)

func normalizeModel(_ raw: String) -> String {
    // transcripts carry variants like "claude-opus-5[1m]"
    String(raw.split(separator: "[").first ?? "")
}

func rate(model: String, at ts: Date, fast: Bool) -> (Price, known: Bool) {
    guard let p = PRICES[model] else { return (FALLBACK_PRICE, false) }
    if fast, let f = p.fast { return (Price(input: f.input, output: f.output), true) }
    if let i = p.intro, ts < i.until { return (Price(input: i.input, output: i.output), true) }
    return (p, true)
}

// MARK: - Entries

struct Entry {
    let ts: Date
    let model: String
    let cost: Double
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
    let session: String
    let knownPrice: Bool
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let iso = ISO8601DateFormatter()

func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
func isoString(_ d: Date) -> String { isoFrac.string(from: d) }

private func num(_ d: [String: Any]?, _ k: String) -> Double {
    (d?[k] as? NSNumber)?.doubleValue ?? 0
}

func cost(of u: [String: Any], model: String, ts: Date, fast: Bool) -> (Double, Bool) {
    let (p, known) = rate(model: model, at: ts, fast: fast)
    let creation = u["cache_creation"] as? [String: Any]
    var write1h = num(creation, "ephemeral_1h_input_tokens")
    var write5m = num(creation, "ephemeral_5m_input_tokens")
    if creation == nil { write5m = num(u, "cache_creation_input_tokens") }
    let total = num(u, "input_tokens") * p.input
        + num(u, "output_tokens") * p.output
        + num(u, "cache_read_input_tokens") * p.input * 0.1
        + write5m * p.input * 1.25
        + write1h * p.input * 2.0
    if write1h.isNaN { write1h = 0 }
    return (total / 1_000_000, known)
}

/// Reads assistant turns newer than `since`. Only files whose mtime is in range are
/// opened, which is what keeps this cheap enough to poll (15 MB / ~0.4 s for a 5h window).
func scan(root: URL, since: Date) -> [Entry] {
    var out: [Entry] = []
    var seen = Set<String>()
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }

    for case let url as URL in walker {
        guard url.pathExtension == "jsonl",
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              mtime > since,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { continue }

        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let ts = parseDate(obj["timestamp"] as? String ?? ""), ts > since,
                  let msg = obj["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any]
            else { continue }

            let raw = msg["model"] as? String ?? ""
            guard raw != "<synthetic>", !raw.isEmpty else { continue }

            // the same response is written to both the session file and sidechain copies
            let key = (msg["id"] as? String ?? "") + (obj["requestId"] as? String ?? "")
            guard seen.insert(key).inserted else { continue }

            let model = normalizeModel(raw)
            let fast = (u["speed"] as? String) == "fast"
            let (c, known) = cost(of: u, model: model, ts: ts, fast: fast)
            let creation = u["cache_creation"] as? [String: Any]
            out.append(Entry(
                ts: ts, model: model, cost: c,
                input: num(u, "input_tokens"),
                output: num(u, "output_tokens"),
                cacheRead: num(u, "cache_read_input_tokens"),
                cacheWrite: creation == nil
                    ? num(u, "cache_creation_input_tokens")
                    : num(creation, "ephemeral_5m_input_tokens") + num(creation, "ephemeral_1h_input_tokens"),
                session: obj["sessionId"] as? String ?? "",
                knownPrice: known))
        }
    }
    return out
}

// MARK: - Blocks

/// Anthropic's 5-hour limit opens on the first message after a >= 5h gap and runs exactly
/// 5h from *that message's timestamp* — not from the top of the hour. Verified against the
/// claude.ai usage tab: a session whose first message was 10:55:44 resets at 15:55, and
/// rounding the anchor down to 10:00 both reported the wrong reset time and expired the
/// window an hour early, spuriously opening a new one.
func activeBlock(_ entries: [Entry], now: Date) -> (start: Date, end: Date)? {
    let sorted = entries.sorted { $0.ts < $1.ts }
    guard let first = sorted.first else { return nil }
    var start = first.ts
    var last = first.ts
    for e in sorted.dropFirst() {
        if e.ts.timeIntervalSince(start) >= FIVE_HOURS || e.ts.timeIntervalSince(last) >= FIVE_HOURS {
            start = e.ts
        }
        last = e.ts
    }
    let end = start.addingTimeInterval(FIVE_HOURS)
    return end > now ? (start, end) : nil
}

/// Every 5-hour block in the given history, oldest first. Same tiling rule as
/// `activeBlock`, but it keeps all of them — used to measure the heaviest block the
/// user has actually sustained, which is a far better limit estimate than a guess.
func allBlocks(_ entries: [Entry]) -> [(start: Date, end: Date, cost: Double)] {
    let sorted = entries.sorted { $0.ts < $1.ts }
    guard let first = sorted.first else { return [] }
    var out: [(start: Date, end: Date, cost: Double)] = []
    var start = first.ts
    var last = first.ts
    var running = 0.0
    for e in sorted {
        if e.ts.timeIntervalSince(start) >= FIVE_HOURS || e.ts.timeIntervalSince(last) >= FIVE_HOURS {
            out.append((start, start.addingTimeInterval(FIVE_HOURS), running))
            start = e.ts
            running = 0
        }
        running += e.cost
        last = e.ts
    }
    out.append((start, start.addingTimeInterval(FIVE_HOURS), running))
    return out
}

// MARK: - Aggregate

struct DayBar: Identifiable {
    let id: Int
    let label: String
    let cost: Double
}

/// Spend per calendar day for the trailing week, oldest first.
func dailySpend(_ entries: [Entry], now: Date = Date()) -> [DayBar] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let f = DateFormatter()
    f.dateFormat = "EEEEE"   // narrow weekday initial
    return (0..<7).reversed().enumerated().map { i, back in
        let day = cal.date(byAdding: .day, value: -back, to: today) ?? today
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? today
        let c = entries.filter { $0.ts >= day && $0.ts < next }.reduce(0) { $0 + $1.cost }
        return DayBar(id: i, label: f.string(from: day), cost: c)
    }
}

struct ModelSlice: Identifiable {
    let model: String
    let cost: Double
    var id: String { model }
    var short: String { model.replacingOccurrences(of: "claude-", with: "") }
}

struct Snapshot {
    var cost = 0.0
    var requests = 0
    var sessions = 0
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0
    var models: [ModelSlice] = []
    var unknown: Set<String> = []
    var blockStart: Date?
    var blockEnd: Date?
    var buckets: [Double] = []
    var burnPerHour = 0.0
    var daily: [DayBar] = []
    var live: [LiveSession] = []
    var scannedAt = Date()

    var elapsedBuckets: Int {
        guard let s = blockStart else { return 0 }
        return min(BUCKETS, max(1, Int(Date().timeIntervalSince(s) / BUCKET) + 1))
    }

    /// Percentage points of the 5-hour window burned per hour at the current rate.
    ///
    /// The API gives the true utilization but only as a running total, so it can't say how
    /// fast you're going *right now*. The local scan can, in weight units — so scale the
    /// recent burn by the window's own points-per-weight. Falls back to the flat average
    /// across the block when there's no local weight to scale by.
    func pointsPerHour(utilization: Double) -> Double {
        if cost > 0, burnPerHour > 0 { return burnPerHour * (utilization / cost) }
        guard let s = blockStart else { return 0 }
        let hours = max(1.0 / 60, Date().timeIntervalSince(s) / 3600)
        return utilization / hours
    }

    /// Seconds until the window hits 100% at the current rate — nil if that lands after
    /// the reset, which is the normal, unalarming case.
    func secondsToCap(utilization: Double) -> TimeInterval? {
        let rate = pointsPerHour(utilization: utilization)
        guard rate > 0, utilization < 100 else { return nil }
        let secs = (100 - utilization) / rate * 3600
        guard let end = blockEnd, Date().addingTimeInterval(secs) < end else { return nil }
        return secs
    }

    /// Where the window lands by reset if the current rate holds.
    func projected(utilization: Double) -> Double {
        guard let end = blockEnd else { return utilization }
        let hoursLeft = max(0, end.timeIntervalSinceNow / 3600)
        return min(100, utilization + pointsPerHour(utilization: utilization) * hoursLeft)
    }
}

/// Blocks tile while activity continues, so the anchor traces back to the last real
/// >= 5h gap — which can be days ago. A short scan window cannot find it and would
/// invent a boundary, so the authoritative anchor comes from the 7-day scan and is
/// passed in here; this rolls it forward across any whole blocks that have since
/// elapsed, and falls back to a full walk of `all` when there is nothing usable.
func summarize(all: [Entry], anchor: Date? = nil, now: Date = Date()) -> Snapshot {
    var s = Snapshot(scannedAt: now)
    var start = anchor
    while let cur = start, now >= cur.addingTimeInterval(FIVE_HOURS) {
        // 1s of slack: the anchor round-trips through an ISO string, so it can land a
        // fraction of a millisecond below the very message that opened the next block —
        // and skipping that message rolls the whole chain onto the wrong boundary.
        let ended = cur.addingTimeInterval(FIVE_HOURS - 1)
        // the next block opens at the first message at or after this one ended
        guard let next = all.filter({ $0.ts >= ended }).map(\.ts).min() else { start = nil; break }
        start = next
    }
    guard let blockStart = start ?? activeBlock(all, now: now)?.start,
          blockStart.addingTimeInterval(FIVE_HOURS) > now
    else { return s }
    s.blockStart = blockStart
    s.blockEnd = blockStart.addingTimeInterval(FIVE_HOURS)
    let block = (start: blockStart, end: s.blockEnd!)

    let inBlock = all.filter { $0.ts >= block.start && $0.ts < block.end }
    s.requests = inBlock.count
    s.sessions = Set(inBlock.map(\.session)).count
    var byModel: [String: Double] = [:]
    var buckets = [Double](repeating: 0, count: BUCKETS)
    for e in inBlock {
        s.cost += e.cost
        s.input += e.input; s.output += e.output
        s.cacheRead += e.cacheRead; s.cacheWrite += e.cacheWrite
        byModel[e.model, default: 0] += e.cost
        if !e.knownPrice { s.unknown.insert(e.model) }
        let i = Int(e.ts.timeIntervalSince(block.start) / BUCKET)
        if i >= 0 && i < BUCKETS { buckets[i] += e.cost }
    }
    s.buckets = buckets
    s.models = byModel.map { ModelSlice(model: $0.key, cost: $0.value) }
        .sorted { $0.cost > $1.cost }

    // burn rate over the last hour of the block (or since it opened, if shorter)
    let lookback = min(3600, max(600, now.timeIntervalSince(block.start)))
    let windowCost = inBlock.filter { $0.ts > now.addingTimeInterval(-lookback) }.reduce(0) { $0 + $1.cost }
    s.burnPerHour = windowCost / lookback * 3600
    return s
}

/// The block anchor is persisted so it survives relaunch and never depends on how far
/// back the current scan happened to look.
enum Anchor {
    static var start: Date? {
        get { UserDefaults.standard.string(forKey: "blockAnchor").flatMap(parseDate) }
        set { UserDefaults.standard.set(newValue.map(isoString), forKey: "blockAnchor") }
    }
}

enum Prefs {
    static func int(_ k: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: k) == nil ? fallback : UserDefaults.standard.integer(forKey: k)
    }
    static func bool(_ k: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: k) == nil ? fallback : UserDefaults.standard.bool(forKey: k)
    }
}

// MARK: - Formatting

func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

func compact(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}

func shortDuration(_ secs: TimeInterval) -> String {
    let m = max(0, Int(secs / 60))
    return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(m)m"
}

func clockTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    return f.string(from: d)
}

/// Weekly resets can be days out, so the weekday only appears when it isn't today.
func dayTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    if !Calendar.current.isDateInToday(d) { f.setLocalizedDateFormatFromTemplate("EEE j:mm") }
    return f.string(from: d)
}
