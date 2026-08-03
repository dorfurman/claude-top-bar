import AppKit
import Foundation

/// One runnable check per piece of non-trivial logic: the price table's tiers, cache-write
/// tiers, dedup, fixed-block gap detection, bucketing, and burn rate.
///
/// Uses its own `check` rather than assert/precondition: `assert` is stripped by -O, and
/// `precondition` traps without printing its message under -O, so a failure would be
/// invisible. This reports every failure and exits non-zero.
func selfTest() {
    var failures = 0
    func check(_ ok: Bool, _ msg: String) {
        if !ok { print("FAIL: \(msg)"); failures += 1 }
    }
    defer {
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("crabbar-test-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date()

    func row(id: String, model: String, ago: TimeInterval,
             input: Int = 0, output: Int = 0, cacheRead: Int = 0,
             write5m: Int = 0, write1h: Int = 0, speed: String = "standard",
             session: String = "s1") -> String {
        let ts = isoString(now.addingTimeInterval(-ago))
        return """
        {"type":"assistant","timestamp":"\(ts)","requestId":"r\(id)","sessionId":"\(session)",\
        "message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"speed":"\(speed)",\
        "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)}}}}
        """
    }

    // ---- update-check version comparison
    check(Updates.newer("2.1.0", than: "2.0.9"), "minor must beat patch")
    check(Updates.newer("10.0", than: "9.9.9"), "must compare numerically, not lexically")
    check(!Updates.newer("2.0", than: "2.0.0"), "equal versions of mixed length are not newer")
    check(!Updates.newer("1.9.9", than: "2.0"), "older must not read as newer")

    // ---- the intro-pricing cutoff is an exclusive upper bound at end of 2026-08-31
    check(isoString(AUG_31_2026).hasPrefix("2026-09-01T00:00:00"),
          "intro cutoff drifted: \(isoString(AUG_31_2026))")

    // ---- price tiers
    let opus = cost(of: ["input_tokens": 1000, "output_tokens": 100,
                  "cache_read_input_tokens": 10000,
                  "cache_creation": ["ephemeral_5m_input_tokens": 200,
                                     "ephemeral_1h_input_tokens": 400]],
             model: "claude-opus-5", ts: now, fast: false)
    // 1000*5 + 100*25 + 10000*0.5 + 200*6.25 + 400*10 = 17,750 per 1M
    check(abs(opus.0 - 0.01775) < 1e-9, "opus cost \(opus.0) != 0.01775")
    check(opus.1, "opus should be a known model")

    let fast = cost(of: ["input_tokens": 1000, "output_tokens": 100],
             model: "claude-opus-5", ts: now, fast: true)
    // fast mode on Opus 5 bills at $10/$50: 1000*10 + 100*50 = 15,000 per 1M
    check(abs(fast.0 - 0.015) < 1e-9, "fast-mode cost \(fast.0) != 0.015")

    let intro = cost(of: ["input_tokens": 1000, "output_tokens": 100],
              model: "claude-sonnet-5", ts: now, fast: false)
    check(abs(intro.0 - 0.003) < 1e-9, "sonnet intro cost \(intro.0) != 0.003")
    let post = cost(of: ["input_tokens": 1000, "output_tokens": 100],
             model: "claude-sonnet-5",
             ts: AUG_31_2026.addingTimeInterval(86400), fast: false)
    check(abs(post.0 - 0.0045) < 1e-9, "sonnet list cost \(post.0) != 0.0045")

    let unknown = cost(of: ["input_tokens": 1000], model: "claude-zzz-9", ts: now, fast: false)
    check(!unknown.1, "unknown model must be flagged")
    check(abs(unknown.0 - 0.005) < 1e-9, "fallback cost \(unknown.0)")

    // legacy shape: no cache_creation breakdown -> treated as a 5-minute write
    let legacy = cost(of: ["cache_creation_input_tokens": 1000],
               model: "claude-opus-5", ts: now, fast: false)
    check(abs(legacy.0 - 0.00625) < 1e-9, "legacy cache write \(legacy.0)")

    check(normalizeModel("claude-opus-5[1m]") == "claude-opus-5", "model normalize")

    // ---- session state from a transcript tail
    func tail(_ lines: String...) -> [Substring] { lines.map { Substring($0) } }
    let waiting = classifySession(tail(
        #"{"type":"ai-title","aiTitle":"Fix the build"}"#,
        #"{"type":"user","cwd":"/Users/x/proj","message":{"role":"user","content":"go"}}"#,
        #"{"type":"assistant","cwd":"/Users/x/proj","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
        #"{"type":"system","cwd":"/Users/x/proj"}"#))
    check(!waiting.working, "trailing assistant text must read as idle")
    check(waiting.title == "Fix the build" && waiting.cwd == "/Users/x/proj", "tail title/cwd")
    check(classifySession(tail(
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}"#)).working,
        "trailing tool_use must read as working")
    check(classifySession(tail(
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"#,
        #"{"type":"permission-mode","permissionMode":"auto"}"#)).working,
        "trailing tool_result must read as working past meta entries")
    check(!classifySession(tail("not json at all")).working, "garbage tail defaults to idle")

    // ---- scan: dedup, window cutoff, synthetic skip
    let lines = [
        row(id: "old", model: "claude-opus-5", ago: 9 * 3600, output: 1000),   // previous block
        row(id: "a", model: "claude-opus-5", ago: 3 * 3600, output: 1000),     // opens the block
        row(id: "a", model: "claude-opus-5", ago: 3 * 3600, output: 1000),     // duplicate
        row(id: "b", model: "claude-sonnet-5", ago: 600, output: 1000, session: "s2"),
        row(id: "c", model: "<synthetic>", ago: 300, output: 99999),
        #"{"type":"user","timestamp":"nope"}"#,
    ].joined(separator: "\n")
    try! lines.write(to: dir.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)

    let entries = scan(root: dir, since: now.addingTimeInterval(-2 * FIVE_HOURS))
    check(entries.count == 3, "expected 3 entries (dedup + synthetic skip), got \(entries.count)")

    let s = summarize(all: entries, now: now)

    // ---- fixed-block detection: the 9h-ago entry is a previous block and must be excluded
    guard let start = s.blockStart, let end = s.blockEnd else {
        check(false, "no active block detected")
        return
    }
    check(abs(start.timeIntervalSince(now.addingTimeInterval(-3 * 3600))) < 1,
          "block should open at the exact time of the -3h entry, not the hour boundary")
    check(end == start.addingTimeInterval(FIVE_HOURS), "block is 5h wide")
    check(s.requests == 2, "block should hold 2 requests, got \(s.requests)")
    check(s.sessions == 2, "block spans 2 sessions, got \(s.sessions)")

    // opus 1000 out = 0.025 weight ; sonnet-5 intro 1000 out = 0.010
    check(abs(s.cost - 0.035) < 1e-9, "block weight \(s.cost) != 0.035")
    check(s.models.first?.model == "claude-opus-5", "models must sort by weight")
    check(s.models.count == 2, "two models in block")

    // ---- bucketing: entries land in distinct 10-minute buckets, summing to block cost
    check(s.buckets.count == BUCKETS, "bucket count \(s.buckets.count)")
    check(abs(s.buckets.reduce(0, +) - s.cost) < 1e-9, "buckets must sum to cost")
    check(s.buckets.filter { $0 > 0 }.count == 2, "expected 2 non-empty buckets")

    // ---- burn rate: only the -10min entry falls in the last hour -> 0.010 weight/h
    check(abs(s.burnPerHour - 0.010) < 1e-6, "burn \(s.burnPerHour) != 0.010/h")

    // ---- pace: the API's utilization is scaled by the *local* recent burn, so the answer
    // is in percentage points per hour of the real window, not in weight units.
    // burn 0.010/h over a block whose 0.035 of weight is reported as 35% used
    //   -> 0.010 * (35 / 0.035) = 10 points/h, 2h of block left -> ~55% by reset.
    check(abs(s.pointsPerHour(utilization: 35) - 10) < 1e-6,
          "pointsPerHour \(s.pointsPerHour(utilization: 35)) != 10")
    check(abs(s.projected(utilization: 35) - 55) < 0.1,
          "projected \(s.projected(utilization: 35)) != 55")
    // 65 points to go at 10/h is 6.5h, well past the 2h remaining -> no alarm
    check(s.secondsToCap(utilization: 35) == nil, "a cap beyond the reset must not alarm")
    // at 90% the same weight maps to a steeper points-per-weight scale (0.010 * 90/0.035
    // = 25.7 points/h), so the remaining 10 points land in ~23 min — inside the 2h left,
    // so it must alarm.
    check((s.secondsToCap(utilization: 90).map { abs($0 - 1400) < 60 }) == true,
          "90% must project ~23m to cap, got \(s.secondsToCap(utilization: 90).map(shortDuration) ?? "nil")")
    check(s.secondsToCap(utilization: 100) == nil, "an exhausted window projects nothing")
    // idle block: no local weight to scale by, so it falls back to the flat average
    let flat = Snapshot(blockStart: now.addingTimeInterval(-2 * 3600),
                        blockEnd: now.addingTimeInterval(3 * 3600))
    check(abs(flat.pointsPerHour(utilization: 40) - 20) < 0.01,
          "flat fallback \(flat.pointsPerHour(utilization: 40)) != 20/h")

    // ---- tiling: blocks chain every 5h while activity continues, anchored to the hour
    // after the last real >= 5h gap. A stale anchor must roll forward to the same answer
    // a full-history walk gives — this is what a short scan window gets wrong.
    var chain = [row(id: "gap", model: "claude-opus-5", ago: 20 * 3600, output: 10)]
    for i in 0..<24 {   // every 30 min from -12h to now
        chain.append(row(id: "c\(i)", model: "claude-opus-5",
                         ago: 12 * 3600 - Double(i) * 1800, output: 10))
    }
    let chainDir = dir.appendingPathComponent("chain")
    try? FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)
    try! chain.joined(separator: "\n")
        .write(to: chainDir.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
    let chained = scan(root: chainDir, since: now.addingTimeInterval(-WEEK))

    let walked = summarize(all: chained, now: now)
    let expected = now.addingTimeInterval(-2 * 3600)
    check(abs((walked.blockStart ?? .distantPast).timeIntervalSince(expected)) < 1,
          "tiled anchor \(walked.blockStart.map(clockTime) ?? "nil") != \(clockTime(expected))")

    let rolled = summarize(all: chained,
                           anchor: now.addingTimeInterval(-12 * 3600), now: now)
    check(rolled.blockStart == walked.blockStart,
          "stale anchor must roll forward to the walked anchor, got "
          + "\(rolled.blockStart.map(clockTime) ?? "nil")")

    // ---- allBlocks segments the same history: the pre-gap entry is its own block, then
    // the -12h/-7h/-2h chain. Costs must sum to the whole history, losing nothing.
    let blocks = allBlocks(chained)
    check(blocks.count == 4, "expected 4 blocks (1 pre-gap + 3 tiled), got \(blocks.count)")
    check(abs((blocks.last?.start ?? .distantPast).timeIntervalSince(expected)) < 1,
          "last block must be the active one")
    check(abs(blocks.map(\.cost).reduce(0, +) - chained.reduce(0) { $0 + $1.cost }) < 1e-9,
          "block costs must sum to total history")
    check(allBlocks([]).isEmpty, "no history means no blocks")

    // an anchor whose block is still open is used as-is, not recomputed
    let openAnchor = now.addingTimeInterval(-3600)
    let fresh = summarize(all: chained, anchor: openAnchor, now: now)
    check(fresh.blockStart == openAnchor, "an anchor whose block is still open must be kept as-is")

    // ---- idle: no entries at all
    let idle = summarize(all: [], now: now)
    check(idle.blockStart == nil && idle.cost == 0, "idle snapshot must be empty")
    check(idle.pointsPerHour(utilization: 50) == 0, "no block means no rate to project from")

    // ---- the API's percentages are clamped before they reach a meter
    check(Window(utilization: 140, resetsAt: nil).fraction == 1, "fraction clamps above 100")
    check(Window(utilization: -3, resetsAt: nil).fraction == 0, "fraction clamps below 0")

    // ---- badge cache: survives a relaunch, but never outlives its window
    let saved = UserDefaults.standard.object(forKey: "lastUsage")
    defer { UserDefaults.standard.set(saved, forKey: "lastUsage") }

    Usage(fiveHour: Window(utilization: 44, resetsAt: now.addingTimeInterval(3600)),
          sevenDay: Window(utilization: 12, resetsAt: now.addingTimeInterval(WEEK))).cache()
    let back = Usage.cached
    check(back?.fiveHour?.utilization == 44 && back?.sevenDay?.utilization == 12,
          "cached usage must round-trip both badge windows")
    check(abs((back?.fetchedAt ?? .distantPast).timeIntervalSince(now)) < 1,
          "cached usage must keep its real fetch time, not the load time")

    Usage(fiveHour: Window(utilization: 44, resetsAt: now.addingTimeInterval(-60))).cache()
    check(Usage.cached == nil, "a window that has already reset must not be restored")

    // ---- badge geometry: fixed slots, so the menu bar doesn't shuffle on every digit
    func badge(_ util: Double, _ mins: Double) -> NSImage {
        badgeImage(Usage(fiveHour: Window(utilization: util,
                                          resetsAt: now.addingTimeInterval(mins * 60))),
                   mode: .percentAndTime)
    }
    // the percent slot hugs its text, so width may grow with digit count — but must not
    // shuffle while the digit count stays put
    check(badge(4, 254).size.width == badge(9, 254).size.width,
          "badge width must not change within the same digit count")
    check(badge(44, 254).size.width == badge(44, 65).size.width,
          "badge width must not change as the time left shrinks")
    check(badgeImage(nil, mode: .percentAndTime, frame: 0).tiffRepresentation
          != badgeImage(nil, mode: .percentAndTime, frame: Clawd.frames / 2).tiffRepresentation,
          "Clawd's frames must actually differ")
    // the bake is generated code — a bad grid or a mask wider than the cycle would draw
    // silently wrong rather than fail to compile
    check(Clawd.groups.allSatisfy { _, mask, quads in
        mask >> UInt64(Clawd.frames) == 0 && quads.count % 4 == 0
            && stride(from: 0, to: quads.count, by: 4).allSatisfy {
                quads[$0] + quads[$0 + 2] <= Clawd.cellsWide
                    && quads[$0 + 1] + quads[$0 + 3] <= Clawd.cellsHigh
            }
    }, "baked Clawd rects must stay inside the cell grid")
    check((0..<Clawd.frames).allSatisfy { f in
        Clawd.groups.contains { $0.1 & (1 << UInt64(f)) != 0 }
    }, "no frame of Clawd may be blank")

    // ---- game: hand-typed pose rects must stay inside their cell grid
    for (name, a) in [("walk", GameCrab.walk), ("shoot", GameCrab.shoot), ("idle", GameCrab.idle)] {
        check(a.seq.allSatisfy { $0 < a.uniq.count } && a.uniq.allSatisfy { runs in
            stride(from: 0, to: runs.count, by: 5).allSatisfy {
                runs[$0 + 1] + runs[$0 + 3] <= GameCrab.cellsWide
                    && runs[$0 + 2] + runs[$0 + 4] <= Clawd.cellsHigh
            }
        }, "GameCrab.\(name) rects must stay inside the cell grid")
    }
    for s in Skin.allCases {   // outfit rects: inside the grid, colors inside the palette
        check(stride(from: 0, to: s.outfit.count, by: 5).allSatisfy {
            s.outfit[$0] < s.colors.count
                && s.outfit[$0 + 1] + s.outfit[$0 + 3] <= GameCrab.cellsWide
                && s.outfit[$0 + 2] + s.outfit[$0 + 4] <= Clawd.cellsHigh
        }, "Skin.\(s.rawValue) outfit must stay inside the grid and palette")
    }

    // ---- game: the campaign table must be sane, in and past the hand-tuned rows
    check(GameModel.stages.count == 30 && (1...60).allSatisfy { n in
        let st = GameModel.stage(n)
        return !st.name.isEmpty && st.pace > 0 && st.speed >= 1 && st.elite < 1
            && !st.roster.isEmpty && st.roster.allSatisfy { $0.1 > 0 } && !st.boss.isEmpty
    } && GameModel.stage(30).pace < GameModel.stage(1).pace
      && GameModel.stage(30).speed > GameModel.stage(1).speed,
    "the 30-stage table and OVERTIME scaling must be sane and get harder")

    // game tests can bank random coin drops / kills / trophies into the real
    // persisted state — snapshot, restore after the last game block
    let wallet = (coins: UserDefaults.standard.integer(forKey: "gameCoins"),
                  owned: UserDefaults.standard.stringArray(forKey: "gameSkinsOwned"),
                  skin: UserDefaults.standard.string(forKey: "gameSkin"),
                  ach: UserDefaults.standard.stringArray(forKey: "gameAch"),
                  kills: UserDefaults.standard.integer(forKey: "gameKills"),
                  best: UserDefaults.standard.integer(forKey: "gameBestStage"))

    // ---- game: auto-fire downs a point-blank human; its bubble magnets in as xp
    let g = GameModel()
    g.sfx = false   // no sound effects out of the test run
    g.reset()
    g.nextSpawn = .infinity   // just the one hand-placed target, no random extras
    g.enemies = [GameModel.Enemy(pos: CGPoint(x: g.crabX, y: 330), vel: .init(),
                                 face: "🧑", shootAt: .infinity)]
    for _ in 0..<30 { g.step(1.0 / 60) }    // 0.5s: auto-aim fires, covers the gap
    check(g.enemies.isEmpty && g.score == 10, "auto-fire must down a human")
    for _ in 0..<240 { g.step(1.0 / 60) }   // 4s: the xp bubble falls into magnet range
    check(g.xp == 1, "a kill must drop one collectible xp bubble")

    // ---- game: a full xp bar advances the stage and drops the boss in
    g.reset()
    g.nextSpawn = .infinity
    g.xp = g.xpNext - 1
    g.enemies = [GameModel.Enemy(pos: CGPoint(x: g.crabX, y: 330), vel: .init(),
                                 face: "🧑", shootAt: .infinity)]
    for _ in 0..<300 { g.step(1.0 / 60) }   // kill + collect the last bubble
    check(g.level == 2 && g.scene == .playing
          && g.enemies.contains { $0.kind == .boss },
          "full xp bar must advance the stage and spawn the boss")

    // ---- game: catching a 💣 wipes the field and the incoming fire
    g.reset()
    g.nextSpawn = .infinity
    g.enemies = [CGPoint(x: 100, y: 100), CGPoint(x: 240, y: 120), CGPoint(x: 380, y: 100)]
        .map { GameModel.Enemy(pos: $0, vel: .init(), face: "🧑", shootAt: .infinity) }
    g.enemyShots = [GameModel.Shot(pos: CGPoint(x: 240, y: 200), vel: .init())]
    g.drops = [GameModel.Drop(pos: g.crabPos, power: .bomb)]
    g.step(1.0 / 60)
    check(g.enemies.isEmpty && g.enemyShots.isEmpty, "a bomb must clear the field")

    g.reset()
    g.shotCD = .infinity                    // no return fire: the office must win
    for _ in 0..<7200 { g.step(1.0 / 60) }  // 2min AFK: the swarm must finish Clawd
    check(g.over && g.lives <= 0, "unopposed humans must win")

    // ---- game: catching a BIG SHRIMP drop raises shot damage
    g.reset()
    g.nextSpawn = .infinity
    g.drops = [GameModel.Drop(pos: g.crabPos, upgrade: .power)]
    g.step(1.0 / 60)
    check(g.power == 2, "catching BIG SHRIMP must raise shot damage")

    // ---- game: a charged 🛡️ soaks a hit that would otherwise cost a life
    g.reset()
    g.nextSpawn = .infinity
    g.shotCD = .infinity   // no auto-fire: the hit must land, the shell must soak
    g.shell = true
    g.enemies = [GameModel.Enemy(pos: g.crabPos, vel: .init(), face: "🧑",
                                 shootAt: .infinity)]
    g.step(1.0 / 60)
    check(g.lives == 3 && g.shellAt >= 0, "a charged shell must soak the hit")

    // ---- game: downing a stage boss pays the score bonus and a coin purse
    g.reset()
    g.nextSpawn = .infinity
    let purse = g.coins
    g.enemies = [GameModel.Enemy(pos: CGPoint(x: g.crabX, y: 300), vel: .init(),
                                 kind: .boss, face: "🕴️", hp: 1, maxHp: 1,
                                 shootAt: .infinity)]
    for _ in 0..<40 { g.step(1.0 / 60) }
    check(g.enemies.isEmpty && g.score == 12 * 10 + 250
          && g.coinDrops.count + g.coins - purse == 3,
          "a boss kill must pay the stage bonus and 3 coins")

    // ---- game: a crab-coin magnets in and banks; the shop charges once and equips
    g.reset()
    g.nextSpawn = .infinity
    let bank = g.coins
    g.coinDrops = [GameModel.Bubble(pos: CGPoint(x: g.crabX, y: g.crabPos.y - 40),
                                    vel: CGVector(dx: 0, dy: 45))]
    for _ in 0..<60 { g.step(1.0 / 60) }
    check(g.coinDrops.isEmpty && g.coins == bank + 1, "a crab-coin must magnet in and bank")
    g.owned = []              // don't inherit the real wallet's purchases
    g.coins = Skin.ocean.price
    g.selectSkin(.ocean)
    check(g.coins == 0 && g.skin == .ocean && g.owned.contains(Skin.ocean.rawValue),
          "the shop must charge and equip")
    g.selectSkin(.ocean)
    check(g.coins == 0 && g.skin == .ocean, "re-equipping an owned skin must be free")
    UserDefaults.standard.set(wallet.coins, forKey: "gameCoins")
    UserDefaults.standard.set(wallet.owned, forKey: "gameSkinsOwned")
    UserDefaults.standard.set(wallet.skin, forKey: "gameSkin")
    UserDefaults.standard.set(wallet.ach, forKey: "gameAch")
    UserDefaults.standard.set(wallet.kills, forKey: "gameKills")
    UserDefaults.standard.set(wallet.best, forKey: "gameBestStage")

    // ---- duplicate-copy detection (the "CrabBar 2.app" sweep deletes what this matches)
    check(Updates.isOurBundle(Bundle.main.bundleURL)
          && !Updates.isOurBundle(URL(fileURLWithPath: "/System/Applications/Music.app"))
          && !Updates.isOurBundle(URL(fileURLWithPath: "/Applications")),
          "isOurBundle() must match only our own bundle id")

    // an update that isn't our signed zip must never come back as launchable
    check(Updates.unpack(URL(fileURLWithPath: "/etc/hosts")) == nil,
          "unpack() must reject anything that isn't our signed CrabBar.app")

    // ---- formatting
    check(pct(27.4) == "27%" && pct(99.6) == "100%", "pct()")
    check(compact(1_500_000) == "1.5M" && compact(2400) == "2K", "compact()")
    check(shortDuration(3900) == "1h05m" && shortDuration(600) == "10m", "shortDuration()")

    print("ok — \(entries.count) entries, \(s.requests) reqs, \(s.models.count) models, "
          + "buckets sum \(s.buckets.reduce(0, +) == s.cost ? "exact" : "off")")
}
