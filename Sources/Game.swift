import SwiftUI

// MARK: - Crab Invaders
//
// The "play while Claude works" mini-game, survivors-style: Clawd auto-aims
// shrimp at the nearest human while the office swarms down from the top.
// ←/→ move, space dashes (brief i-frames), kills drop 💎 xp bubbles that
// magnet toward you, and rare upgrade drops fall from kills — rapid fire,
// spread, pierce, orbiting shrimp, magnet, turbo, hearts, quicker dash.
// Runs build differently every time.
//
// Progression is a 30-stage hand-tuned campaign (THE LOBBY → BOARD OF
// DIRECTORS, then endless OVERTIME): each stage sets its own enemy roster,
// spawn pace, speed, armor, and elite chance from a data table. The roster:
// wandering walkers (throw pencils), diving runners, tanks, splitters,
// weaving sales guys, consultants that park up top and snipe, 4-hp security
// guards, and deadline zombies that home in. Elites spawn ringed in orange
// with extra hp and speed for double xp. Each stage ends with its own boss:
// the middle manager (spread), HR (summons minis), the CTO (aimed bursts),
// and the CEO on tens (everything at once). Kills sometimes drop power-ups
// (💣 clears the field, 🧊 freezes it, ⭐ makes contact hurt *them*), a 📠
// fax machine crosses the top as a score piñata, and every half-minute an
// office event twists the rules: performance review (they sprint), coffee
// break (they stop), team meeting (a V formation), casual Friday (double xp).
// Achievements, best-stage and lifetime-kill stats persist in UserDefaults;
// system-sound sfx (toggle in pause) mark kills, hits, coins, and bosses.
//
// One file, no assets — enemies and shots are emoji, the player is the
// existing Clawd art. Chain kills within 2s for a combo score multiplier.
// A pause panel (⎋) doubles as settings, persisted in UserDefaults.
//
// All timing runs on accumulated game-time (`time`), not wall clock, so the
// self-test can step it deterministically fast.

/// Game-only poses, hand-drawn in ClawdAnims' run format — (color, x, y, w, h)
/// rects on the same grid and palette as the original art, rendered by the same
/// drawAnim(). The crab body here is the laptop-less rest pose from `scuttle`:
/// head y7–9, eyes y9–11, arm row y11–15, lower body y15–19, legs y19–23.
enum GameCrab {
    /// Sprite content spans x0–24 (vs Clawd's 34-cell canvas), so game frames
    /// render on a 24-cell-wide image and center cleanly on the crab's position.
    static let cellsWide = 24

    private static let head: [Int] = [
        1, 4, 7, 16, 2,
        1, 4, 9, 2, 2,  0, 6, 9, 2, 2,  1, 8, 9, 8, 2,  0, 16, 9, 2, 2,  1, 18, 9, 2, 2,
    ]
    private static let lower: [Int] = [1, 4, 15, 16, 4]
    private static let wideArms: [Int] = [1, 0, 11, 24, 4]      // claws folded at the sides
    private static let narrowBody: [Int] = [1, 4, 11, 16, 4]    // claws lifted off the row
    private static let legsPlanted: [Int] = [1, 4, 19, 2, 4,  1, 8, 19, 2, 4,
                                             1, 14, 19, 2, 4,  1, 18, 19, 2, 4]

    // body settled one cell lower, legs still planted — the exhale half of the breath
    private static let headDown: [Int] = [
        1, 4, 8, 16, 2,
        1, 4, 10, 2, 2,  0, 6, 10, 2, 2,  1, 8, 10, 8, 2,  0, 16, 10, 2, 2,  1, 18, 10, 2, 2,
    ]
    private static let headBlink: [Int] = [
        1, 4, 8, 16, 2,
        1, 4, 10, 2, 2,  1, 6, 10, 2, 1,  0, 6, 11, 2, 1,  1, 8, 10, 8, 2,
        1, 16, 10, 2, 1,  0, 16, 11, 2, 1,  1, 18, 10, 2, 2,
    ]
    private static let bodyDown: [Int] = [1, 0, 12, 24, 4,  1, 4, 16, 16, 3]

    /// Slow breath — body settles a cell and rises — with one blink per loop,
    /// timed into the settled phase.
    static let idle = ClawdAnims.Anim(uniq: [
        head + wideArms + lower + legsPlanted,
        headDown + bodyDown + legsPlanted,
        headBlink + bodyDown + legsPlanted,
    ], seq: [0, 0, 0, 0, 0, 0, 0, 0,  1, 1, 1, 1, 1, 1, 1, 1,
             0, 0, 0, 0, 0, 0, 0, 0,  1, 1, 1, 2, 2, 1, 1, 1])

    /// Alternating leg pairs; the lifted pair tucks short and shifts one cell in
    /// the walking direction, so the crab visibly reaches. Mirrored for left.
    static let walk = ClawdAnims.Anim(uniq: [
        head + wideArms + lower + [1, 4, 19, 2, 2,  1, 8, 19, 2, 4,
                                   1, 14, 19, 2, 4,  1, 19, 19, 2, 2],
        head + wideArms + lower + legsPlanted,
        head + wideArms + lower + [1, 4, 19, 2, 4,  1, 9, 19, 2, 2,
                                   1, 15, 19, 2, 2,  1, 18, 19, 2, 4],
        head + wideArms + lower + legsPlanted,
    ], seq: [0, 1, 2, 3])

    /// Windup (claws raised to head height), then thrust (claws overhead, darker
    /// pincer tips) — played across the recoil window after each shot.
    static let shoot = ClawdAnims.Anim(uniq: [
        head + narrowBody + lower + legsPlanted
            + [1, 0, 9, 4, 3,  1, 20, 9, 4, 3],
        head + narrowBody + lower + legsPlanted
            + [1, 1, 9, 2, 2,  1, 21, 9, 2, 2,
               1, 1, 5, 3, 4,  1, 20, 5, 3, 4,
               2, 1, 3, 3, 2,  2, 20, 3, 3, 2],
    ], seq: [0, 1])
}

/// Shop skins: palette swaps plus a pixel-art outfit over the same crab art.
/// classic is free and owned from the start; the rest cost crab-coins.
enum Skin: String, CaseIterable {
    case classic, ocean, toxic, gold, void

    var title: String { rawValue.uppercased() }
    var price: Int {
        switch self {
        case .classic: return 0; case .ocean, .toxic: return 25
        case .gold: return 60; case .void: return 100
        }
    }
    /// (body, shade) hex — nil keeps the original art untinted.
    private var tint: (UInt32, UInt32)? {
        switch self {
        case .classic: return nil
        case .ocean: return (0x56A8E8, 0x3A7FC2)
        case .toxic: return (0x7ED64A, 0x55A82E)
        case .gold: return (0xF5C542, 0xD09E1E)
        case .void: return (0x7A5FE8, 0x5340B5)
        }
    }
    /// Outfit-only colors, appended to the palette after the 4 body slots.
    private var accents: [UInt32] {
        switch self {
        case .classic: return []
        case .ocean: return [0xF2F2F2, 0x1F3A5F]   // cap white, navy band
        case .toxic: return [0xB6FF3C]             // mohawk green
        case .gold: return [0xE0334C]              // crown jewel
        case .void: return [0x2A2140, 0x9D7BFF]    // hat felt, violet band
        }
    }
    var colors: [NSColor] {
        let base = tint.map { [Clawd.colors[0], NSColor(hex: $0.0),
                               NSColor(hex: $0.1), Clawd.colors[3]] } ?? Clawd.colors
        return base + accents.map { NSColor(hex: $0) }
    }
    /// The clothing — extra (color, x, y, w, h) runs in GameCrab's format,
    /// drawn over every pose. Head top sits at y7 (x4–20), so hats live y0–7;
    /// they overlap the crown enough to survive the idle's 1-cell breath dip.
    var outfit: [Int] {
        switch self {
        case .classic:
            return []
        case .ocean:   // sailor cap: white crown, navy band
            return [4, 6, 3, 12, 3,  5, 5, 6, 14, 1]
        case .toxic:   // three-spike mohawk
            return [4, 7, 2, 2, 5,  4, 11, 1, 2, 6,  4, 15, 2, 2, 5]
        case .gold:    // crown: shaded band, three points, ruby jewel
            return [2, 6, 4, 12, 3,  2, 6, 2, 2, 2,  2, 11, 2, 2, 2,
                    2, 16, 2, 2, 2,  4, 11, 5, 2, 2]
        case .void:    // wizard hat: wide brim, cone, violet band
            return [4, 3, 6, 18, 1,  4, 9, 2, 6, 4,  4, 11, 0, 2, 2,  5, 9, 5, 6, 1]
        }
    }
}

final class GameModel: ObservableObject {
    static let W: CGFloat = 480, H: CGFloat = 420

    enum Scene { case menu, playing, paused, shop }

    enum Kind {
        case walker, runner, tank, splitter, sales, consultant, security, zombie,
             mini, boss, fax
        var size: CGFloat {
            switch self {
            case .walker: return 24
            case .runner: return 20
            case .tank: return 29
            case .splitter: return 24
            case .sales: return 22
            case .consultant: return 24
            case .security: return 27
            case .zombie: return 22
            case .mini: return 15
            case .boss: return 64
            case .fax: return 26
            }
        }
        var xp: Int {
            switch self {
            case .walker, .mini: return 1
            case .runner, .splitter, .sales, .zombie: return 2
            case .tank, .consultant, .security: return 3
            case .boss: return 12
            case .fax: return 6
            }
        }
    }

    /// One row of the campaign: who spawns (weighted), how fast and how often,
    /// bonus armor, elite odds, and which boss ends the stage. Hand-tuned for
    /// 30 stages; past the table it's endless OVERTIME on a scaling formula.
    struct Stage {
        let name: String
        let roster: [(Kind, Int)]
        let pace: CGFloat    // spawn-gap multiplier — lower is denser
        let speed: CGFloat   // enemy velocity multiplier
        let hp: Int          // bonus hp for armored kinds
        let elite: CGFloat   // chance a spawn comes in angry
        let boss: String     // face of the stage boss, keys its attack pattern
    }

    static let stages: [Stage] = [
        Stage(name: "THE LOBBY", roster: [(.walker, 10)],
              pace: 1.05, speed: 1.0, hp: 0, elite: 0, boss: "🕴️"),
        Stage(name: "THE MAILROOM", roster: [(.walker, 10), (.runner, 3)],
              pace: 1.0, speed: 1.0, hp: 0, elite: 0, boss: "🕴️"),
        Stage(name: "OPEN OFFICE", roster: [(.walker, 10), (.runner, 5)],
              pace: 0.95, speed: 1.05, hp: 0, elite: 0, boss: "🕴️"),
        Stage(name: "THE COPY ROOM", roster: [(.walker, 9), (.runner, 4), (.tank, 3)],
              pace: 0.92, speed: 1.05, hp: 0, elite: 0.03, boss: "🕴️"),
        Stage(name: "HR ONBOARDING",
              roster: [(.walker, 8), (.runner, 4), (.tank, 3), (.splitter, 2)],
              pace: 0.88, speed: 1.1, hp: 0, elite: 0.04, boss: "👩‍💼"),
        Stage(name: "SALES FLOOR",
              roster: [(.walker, 8), (.runner, 3), (.tank, 2), (.splitter, 2), (.sales, 5)],
              pace: 0.85, speed: 1.1, hp: 0, elite: 0.05, boss: "🕴️"),
        Stage(name: "THE BREAK ROOM",
              roster: [(.walker, 8), (.runner, 4), (.tank, 3), (.splitter, 3), (.sales, 3)],
              pace: 0.82, speed: 1.15, hp: 0, elite: 0.06, boss: "🕴️"),
        Stage(name: "IT DEPARTMENT",
              roster: [(.walker, 7), (.runner, 3), (.tank, 3), (.splitter, 2),
                       (.sales, 3), (.consultant, 3)],
              pace: 0.8, speed: 1.15, hp: 1, elite: 0.07, boss: "🧑‍💻"),
        Stage(name: "ACCOUNTING",
              roster: [(.walker, 6), (.runner, 3), (.tank, 6), (.splitter, 2), (.consultant, 2)],
              pace: 0.78, speed: 1.2, hp: 1, elite: 0.08, boss: "🕴️"),
        Stage(name: "THE BOARDROOM",
              roster: [(.walker, 6), (.runner, 4), (.tank, 4), (.splitter, 3),
                       (.sales, 3), (.consultant, 3)],
              pace: 0.75, speed: 1.2, hp: 1, elite: 0.1, boss: "🤵"),
        Stage(name: "SECURITY DESK",
              roster: [(.walker, 6), (.runner, 3), (.tank, 3), (.security, 5), (.consultant, 2)],
              pace: 0.73, speed: 1.25, hp: 1, elite: 0.1, boss: "🕴️"),
        Stage(name: "LEGAL",
              roster: [(.walker, 6), (.runner, 4), (.tank, 3), (.splitter, 3), (.consultant, 4)],
              pace: 0.7, speed: 1.25, hp: 1, elite: 0.12, boss: "👩‍💼"),
        Stage(name: "THE ARCHIVES",
              roster: [(.walker, 5), (.runner, 3), (.tank, 3), (.security, 3), (.zombie, 4)],
              pace: 0.68, speed: 1.3, hp: 1, elite: 0.12, boss: "🕴️"),
        Stage(name: "MARKETING",
              roster: [(.walker, 5), (.runner, 3), (.splitter, 3), (.sales, 7), (.consultant, 2)],
              pace: 0.66, speed: 1.3, hp: 2, elite: 0.14, boss: "🧑‍💻"),
        Stage(name: "MIDDLE MANAGEMENT",
              roster: [(.walker, 6), (.runner, 4), (.tank, 4), (.splitter, 3),
                       (.sales, 3), (.security, 3)],
              pace: 0.64, speed: 1.35, hp: 2, elite: 0.15, boss: "👩‍💼"),
        Stage(name: "THE MEZZANINE",
              roster: [(.walker, 5), (.runner, 5), (.tank, 3), (.sales, 4), (.zombie, 3)],
              pace: 0.62, speed: 1.35, hp: 2, elite: 0.16, boss: "🕴️"),
        Stage(name: "FACILITIES",
              roster: [(.walker, 5), (.runner, 3), (.tank, 5), (.security, 4), (.zombie, 3)],
              pace: 0.6, speed: 1.4, hp: 2, elite: 0.17, boss: "🕴️"),
        Stage(name: "COMPLIANCE",
              roster: [(.walker, 5), (.runner, 4), (.tank, 4), (.splitter, 4), (.consultant, 5)],
              pace: 0.58, speed: 1.4, hp: 2, elite: 0.18, boss: "🧑‍💻"),
        Stage(name: "EXECUTIVE FLOOR",
              roster: [(.walker, 4), (.runner, 4), (.tank, 4), (.sales, 4),
                       (.security, 4), (.consultant, 3)],
              pace: 0.56, speed: 1.45, hp: 2, elite: 0.2, boss: "👩‍💼"),
        Stage(name: "SHAREHOLDER MEETING",
              roster: [(.walker, 4), (.runner, 4), (.tank, 5), (.splitter, 4),
                       (.sales, 4), (.consultant, 4)],
              pace: 0.54, speed: 1.45, hp: 3, elite: 0.22, boss: "🤵"),
        Stage(name: "NIGHT SHIFT",
              roster: [(.walker, 4), (.runner, 5), (.security, 4), (.zombie, 6)],
              pace: 0.52, speed: 1.5, hp: 3, elite: 0.24, boss: "🕴️"),
        Stage(name: "THE SUB-BASEMENT",
              roster: [(.walker, 3), (.tank, 4), (.security, 4), (.zombie, 8)],
              pace: 0.5, speed: 1.5, hp: 3, elite: 0.26, boss: "🧑‍💻"),
        Stage(name: "OFFSITE RETREAT",
              roster: [(.walker, 4), (.runner, 5), (.splitter, 5), (.sales, 5), (.zombie, 3)],
              pace: 0.48, speed: 1.55, hp: 3, elite: 0.28, boss: "👩‍💼"),
        Stage(name: "THE MERGER",
              roster: [(.walker, 4), (.runner, 4), (.tank, 5), (.splitter, 5),
                       (.consultant, 4), (.security, 3)],
              pace: 0.46, speed: 1.55, hp: 3, elite: 0.3, boss: "🧑‍💻"),
        Stage(name: "RESTRUCTURING",
              roster: [(.walker, 3), (.runner, 5), (.tank, 4), (.splitter, 6),
                       (.sales, 4), (.zombie, 4)],
              pace: 0.45, speed: 1.6, hp: 3, elite: 0.32, boss: "👩‍💼"),
        Stage(name: "THE AUDIT",
              roster: [(.walker, 3), (.runner, 4), (.tank, 6), (.consultant, 6), (.security, 4)],
              pace: 0.43, speed: 1.6, hp: 4, elite: 0.34, boss: "🧑‍💻"),
        Stage(name: "HOSTILE TAKEOVER",
              roster: [(.walker, 3), (.runner, 6), (.tank, 4), (.sales, 5), (.zombie, 5)],
              pace: 0.42, speed: 1.65, hp: 4, elite: 0.36, boss: "🕴️"),
        Stage(name: "GOLDEN PARACHUTES",
              roster: [(.walker, 3), (.runner, 5), (.tank, 5), (.splitter, 5),
                       (.sales, 4), (.consultant, 4)],
              pace: 0.4, speed: 1.65, hp: 4, elite: 0.38, boss: "👩‍💼"),
        Stage(name: "THE PENTHOUSE",
              roster: [(.walker, 2), (.runner, 5), (.tank, 5), (.security, 5),
                       (.consultant, 5), (.zombie, 4)],
              pace: 0.38, speed: 1.7, hp: 4, elite: 0.4, boss: "🧑‍💻"),
        Stage(name: "BOARD OF DIRECTORS",
              roster: [(.walker, 3), (.runner, 4), (.tank, 4), (.splitter, 4),
                       (.sales, 4), (.consultant, 4), (.security, 4), (.zombie, 4)],
              pace: 0.36, speed: 1.75, hp: 5, elite: 0.45, boss: "🤵"),
    ]

    /// Stage for level `n` — the table, then OVERTIME scaling forever after.
    static func stage(_ n: Int) -> Stage {
        if n <= stages.count { return stages[n - 1] }
        let x = CGFloat(n - stages.count)
        let last = stages[stages.count - 1]
        return Stage(name: "OVERTIME \(n - stages.count)", roster: last.roster,
                     pace: max(0.2, last.pace - x * 0.004),
                     speed: last.speed + x * 0.02,
                     hp: last.hp + (n - stages.count) / 4,
                     elite: min(0.7, last.elite + x * 0.01),
                     boss: n % 10 == 0 ? "🤵" : ["🕴️", "👩‍💼", "🧑‍💻"][n % 3])
    }

    /// Falling pickups — instant effects, unlike the stat upgrades.
    enum Power: CaseIterable {
        case bomb, freeze, star
        var face: String {
            switch self { case .bomb: return "💣"; case .freeze: return "🧊"; case .star: return "⭐" }
        }
        var label: String {
            switch self {
            case .bomb: return "BOOM!"; case .freeze: return "FREEZE!"; case .star: return "INVINCIBLE!"
            }
        }
    }

    /// Random rule-twists announced by a banner every half-minute or so.
    enum OfficeEvent: CaseIterable {
        case review, coffee, meeting, friday
        var banner: String {
            switch self {
            case .review: return "📋 PERFORMANCE REVIEW — THEY'RE SPRINTING"
            case .coffee: return "☕ COFFEE BREAK — THEY STOPPED"
            case .meeting: return "👥 TEAM MEETING INBOUND"
            case .friday: return "🎉 CASUAL FRIDAY — DOUBLE XP"
            }
        }
    }

    /// The run-defining upgrades; rare falling drops from kills.
    enum Upgrade: CaseIterable {
        case rapid, spread, pierce, turbo, heart, orbit, magnet, blink, power, shell, lucky
        var icon: String {
            switch self {
            case .rapid: return "☕"; case .spread: return "🦐"
            case .pierce: return "🎯"; case .turbo: return "💨"
            case .heart: return "💗"; case .orbit: return "🌀"
            case .magnet: return "🧲"; case .blink: return "⚡"
            case .power: return "💥"; case .shell: return "🛡️"
            case .lucky: return "🍀"
            }
        }
        var title: String {
            switch self {
            case .rapid: return "RAPID FIRE"; case .spread: return "SPREAD SHOT"
            case .pierce: return "PIERCING"; case .turbo: return "TURBO LEGS"
            case .heart: return "EXTRA HEART"; case .orbit: return "ORBIT SHRIMP"
            case .magnet: return "MAGNET"; case .blink: return "QUICK DASH"
            case .power: return "BIG SHRIMP"; case .shell: return "SHELL"
            case .lucky: return "LUCKY"
            }
        }
    }

    /// One-time trophies, persisted across runs; award() toasts and banks them.
    static let achievements: [(id: String, title: String)] = [
        ("blood", "FIRST BLOOD"),
        ("combo5", "COMBO ×5"),
        ("stage5", "STAGE 5 — SURVIVOR"),
        ("stage10", "STAGE 10 — VETERAN"),
        ("stage20", "STAGE 20 — LEGEND"),
        ("rich", "CRAB CAPITALIST — 100🟡"),
        ("closet", "FULL CLOSET — ALL SKINS"),
    ]

    struct Enemy {
        var pos: CGPoint
        var vel: CGVector
        var kind: Kind = .walker
        let face: String
        var hp: Int = 1
        var maxHp: Int = 1
        var shootAt: CGFloat   // game-time of next pencil / boss volley
        var hitAt: CGFloat = -1   // last damage taken, for the white flash
        var orbAt: CGFloat = -1   // last orbit-shrimp tick, so orbits don't melt
        var elite = false         // angry variant: +hp, +speed, double xp, orange ring
    }
    struct Shot { var pos: CGPoint; var vel: CGVector; var pierce: Int = 0 }
    struct Bubble { var pos: CGPoint; var vel: CGVector }
    struct Spark { var pos: CGPoint; var vel: CGVector; var age: CGFloat = 0 }
    struct Drop { var pos: CGPoint; var power: Power? = nil; var upgrade: Upgrade? = nil }
    struct Pop { var pos: CGPoint; var text: String; var age: CGFloat = 0; var life: CGFloat = 0.9 }

    // One published tick drives the redraw; everything else is plain state.
    @Published var frame = 0
    var scene: Scene = .menu
    var time: CGFloat = 0
    var crabX: CGFloat = W / 2
    var crabY: CGFloat = H - 32
    var dir: CGFloat = 0          // -1 / 0 / 1 from key state
    var dirY: CGFloat = 0         // -1 (up) / 0 / 1 (down)
    var facing: CGFloat = 1       // last non-zero dir, for mirroring the walk
    var shots: [Shot] = []
    var enemyShots: [Shot] = []
    var enemies: [Enemy] = []
    var bubbles: [Bubble] = []
    var sparks: [Spark] = []
    // crab-coins: random kill drops, banked into a persistent wallet
    var coinDrops: [Bubble] = []
    var coins = UserDefaults.standard.integer(forKey: "gameCoins")
    var skin = Skin(rawValue: UserDefaults.standard.string(forKey: "gameSkin") ?? "") ?? .classic
    var owned = Set(UserDefaults.standard.stringArray(forKey: "gameSkinsOwned")
                    ?? [Skin.classic.rawValue])
    var drops: [Drop] = []
    var pops: [Pop] = []
    var score = 0
    var lives = 3
    var level = 1
    var xp = 0
    var xpNext = 10
    var levelUpAt: CGFloat = -10  // game-time of the last level-up, for the banner
    var hi = UserDefaults.standard.integer(forKey: "gameHi")
    var over = false
    var hurtUntil: CGFloat = -1   // brief invincibility after a hit (and after a dash)
    var nextSpawn: CGFloat = 0
    var lastShot: CGFloat = -1
    // combo: chained kills within 2s ramp a score multiplier
    var combo = 0
    var lastKill: CGFloat = -9
    // dash
    var dashUntil: CGFloat = -1
    var lastDash: CGFloat = -9
    var dashDir = CGVector(dx: 1, dy: 0)
    // power-ups and events
    var frozenUntil: CGFloat = -1   // 🧊 / coffee break: enemies hold still
    var starUntil: CGFloat = -1     // ⭐: untouchable, contact wrecks them
    var nextEvent: CGFloat = 30
    var eventUntil: CGFloat = -1
    var event: OfficeEvent?
    var nextFax: CGFloat = 20
    // screen shake on hits, bombs, boss deaths
    var shakeUntil: CGFloat = -1
    var shakeMag: CGFloat = 0
    // the build — mutated by upgrade picks
    var shotCD: CGFloat = 0.5
    var volley = 1
    var pierce = 0
    var speed: CGFloat = 260
    var orbits = 0
    var magnetR: CGFloat = 50
    var dashCD: CGFloat = 1.4
    var power = 1                 // damage per shrimp
    var shell = false             // 🛡️: soaks one hit per shellCD
    var shellAt: CGFloat = -100   // when the shell last fired
    let shellCD: CGFloat = 25
    var lucky = false             // 🍀: double coin/drop odds
    // lifetime stats + trophies, persisted
    var runKills = 0
    var kills = UserDefaults.standard.integer(forKey: "gameKills")
    var bestStage = UserDefaults.standard.integer(forKey: "gameBestStage")
    var ach = Set(UserDefaults.standard.stringArray(forKey: "gameAch") ?? [])
    var sfx = true                // instance mute — the self-test flips it off
    private var timer: Timer?

    static let faces = ["👨‍💼", "👩‍💻", "🧑‍⚖️", "👮", "🤵"]
    var crabPos: CGPoint { CGPoint(x: crabX, y: crabY) }
    var comboMult: Int { min(5, 1 + combo / 4) }
    var st: Stage { Self.stage(level) }
    /// Stage speed plus an in-run time creep, so an idle game still ends.
    var spd: CGFloat { st.speed * (1 + 0.4 * min(1, time / 240)) }

    /// System-sound sfx, gated by the pause-panel toggle and the instance mute.
    /// Cached so ARC doesn't deallocate the NSSound before it plays.
    private static var sounds: [String: NSSound] = [:]
    func play(_ name: String, _ vol: Float = 0.35) {
        guard sfx, Prefs.bool("gameSound", true) else { return }
        guard let s = Self.sounds[name] ?? NSSound(named: name) else { return }
        Self.sounds[name] = s
        s.volume = vol
        if s.isPlaying { s.stop() }
        s.play()
    }

    /// Banks a trophy once, with a toast and a jingle.
    func award(_ id: String) {
        guard !ach.contains(id),
              let t = Self.achievements.first(where: { $0.id == id })?.title else { return }
        ach.insert(id)
        UserDefaults.standard.set(Array(ach), forKey: "gameAch")
        pops.append(Pop(pos: CGPoint(x: Self.W / 2, y: 150), text: "🏆 \(t)", life: 2.2))
        play("Funk", 0.5)
    }

    /// Where orbit shrimp `i` is right now — also used by the renderer.
    func orbitPos(_ i: Int) -> CGPoint {
        let a = time * 3 + CGFloat(i) * 2 * .pi / CGFloat(max(1, orbits))
        return CGPoint(x: crabPos.x + cos(a) * 46, y: crabPos.y + sin(a) * 46)
    }

    /// Starts a fresh run — the menu's "press ⏎".
    func reset() {
        scene = .playing
        time = 0
        score = 0
        lives = 3
        level = 1
        xp = 0
        xpNext = 10
        levelUpAt = -10
        over = false
        crabX = Self.W / 2
        crabY = Self.H - 32
        shots = []
        enemyShots = []
        enemies = []
        bubbles = []
        sparks = []
        coinDrops = []   // the wallet itself persists across runs
        drops = []
        pops = []
        hurtUntil = -1
        nextSpawn = 0
        lastShot = -1
        facing = 1
        combo = 0
        lastKill = -9
        dashUntil = -1
        lastDash = -9
        dashDir = CGVector(dx: 1, dy: 0)
        frozenUntil = -1
        starUntil = -1
        nextEvent = .random(in: 25...40)
        eventUntil = -1
        event = nil
        nextFax = .random(in: 18...30)
        shakeUntil = -1
        shakeMag = 0
        shotCD = 0.5
        volley = 1
        pierce = 0
        speed = 260
        orbits = 0
        magnetR = 50
        dashCD = 1.4
        power = 1
        shell = false
        shellAt = -100
        lucky = false
        runKills = 0
        hi = UserDefaults.standard.integer(forKey: "gameHi")
    }

    /// Begins ticking. The first scene is the menu; reset() starts actual play.
    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step(1.0 / 60) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Space: a quick burst in the facing direction with brief invincibility.
    func dash() {
        guard scene == .playing, !over, time - lastDash >= dashCD else { return }
        lastDash = time
        dashUntil = time + 0.16
        if dir != 0 || dirY != 0 {
            let len = hypot(dir, dirY)
            dashDir = CGVector(dx: dir / len, dy: dirY / len)
        } else {
            dashDir = CGVector(dx: facing, dy: 0)
        }
        hurtUntil = max(hurtUntil, time + 0.35)
    }

    /// A caught upgrade drop lands immediately.
    func apply(_ u: Upgrade) {
        switch u {
        case .rapid: shotCD = max(0.12, shotCD * 0.78)
        case .spread: volley += 1
        case .pierce: pierce += 1
        case .turbo: speed *= 1.22
        case .heart: lives = min(5, lives + 1)
        case .orbit: orbits += 1
        case .magnet: magnetR += 45
        case .blink: dashCD = max(0.4, dashCD * 0.7)
        case .power: power += 1
        case .shell: shell = true
        case .lucky: lucky = true
        }
        pops.append(Pop(pos: CGPoint(x: crabX, y: crabPos.y - 44),
                        text: "\(u.icon) \(u.title)", life: 1.4))
        play("Glass", 0.5)
    }

    /// Upgrades still worth dropping — capped and one-shot ones fall out.
    var upgradePool: [Upgrade] {
        Upgrade.allCases.filter {
            switch $0 {
            case .heart: return lives < 5
            case .spread: return volley < 5
            case .orbit: return orbits < 4
            case .rapid: return shotCD > 0.15
            case .power: return power < 3
            case .shell: return !shell
            case .lucky: return !lucky
            default: return true
            }
        }
    }

    private func make(_ kind: Kind, at p: CGPoint) -> Enemy {
        switch kind {
        case .walker, .mini:
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -60...60),
                                       dy: .random(in: 25...45) * spd),
                         kind: kind, face: kind == .mini ? "🧍" : Self.faces.randomElement()!,
                         shootAt: kind == .mini ? .infinity : time + .random(in: 0.8...2.5))
        case .runner:
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -40...40),
                                       dy: .random(in: 70...95) * st.speed),
                         kind: kind, face: "🏃", shootAt: .infinity)
        case .tank:
            let hp = 3 + st.hp
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -20...20),
                                       dy: .random(in: 14...22) * st.speed),
                         kind: kind, face: "👷", hp: hp, maxHp: hp, shootAt: .infinity)
        case .splitter:
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -50...50),
                                       dy: .random(in: 30...45) * st.speed),
                         kind: kind, face: "🧑‍🤝‍🧑", shootAt: .infinity)
        case .sales:   // weaves — dx is driven by a sine in the brain pass
            return Enemy(pos: p,
                         vel: CGVector(dx: 0, dy: .random(in: 50...70) * st.speed),
                         kind: kind, face: "🕺", shootAt: .infinity)
        case .consultant:   // parks near the top and snipes
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -35...35) * st.speed, dy: 60),
                         kind: kind, face: "👨‍🏫", hp: 2, maxHp: 2,
                         shootAt: time + .random(in: 1.5...2.5))
        case .security:
            let hp = 4 + st.hp
            return Enemy(pos: p,
                         vel: CGVector(dx: .random(in: -15...15),
                                       dy: .random(in: 10...16) * st.speed),
                         kind: kind, face: "💂", hp: hp, maxHp: hp, shootAt: .infinity)
        case .zombie:   // homes in — acceleration handled in the brain pass
            return Enemy(pos: p, vel: CGVector(dx: 0, dy: 40),
                         kind: kind, face: "🧟", hp: 2, maxHp: 2, shootAt: .infinity)
        case .boss:
            let face = st.boss
            let hp = face == "🤵" ? 50 + 18 * level : 30 + 12 * level
            return Enemy(pos: p, vel: CGVector(dx: 0, dy: 60),
                         kind: kind, face: face, hp: hp, maxHp: hp, shootAt: time + 1.5)
        case .fax:
            let fromLeft = Bool.random()
            return Enemy(pos: CGPoint(x: fromLeft ? -20 : Self.W + 20, y: 58),
                         vel: CGVector(dx: fromLeft ? 110 : -110, dy: 0),
                         kind: kind, face: "📠", hp: 2, maxHp: 2, shootAt: .infinity)
        }
    }

    /// One spawn from the stage's weighted roster; some come in as elites.
    private func spawn() {
        let kinds = st.roster
        var r = Int.random(in: 0..<kinds.reduce(0) { $0 + $1.1 })
        var kind = Kind.walker
        for (k, w) in kinds {
            if r < w { kind = k; break }
            r -= w
        }
        var e = make(kind, at: CGPoint(x: .random(in: 30...(Self.W - 30)), y: -16))
        if CGFloat.random(in: 0..<1) < st.elite {
            e.elite = true
            e.hp += 2
            e.maxHp += 2
            e.vel.dx *= 1.3
            e.vel.dy *= 1.3
        }
        enemies.append(e)
    }

    private func hurt() {
        guard time > hurtUntil, time > starUntil else { return }
        if shell, time - shellAt >= shellCD {   // the 🛡️ soaks it instead
            shellAt = time
            hurtUntil = time + 1.2
            shake(3)
            pops.append(Pop(pos: CGPoint(x: crabX, y: crabPos.y - 44), text: "SHELL!"))
            play("Purr", 0.5)
            return
        }
        hurtUntil = time + 1.5
        lives -= 1
        shake(5)
        burst(at: crabPos)
        play("Basso", 0.5)
        if lives <= 0 {
            over = true
            if score > hi {
                hi = score
                UserDefaults.standard.set(score, forKey: "gameHi")
            }
            kills += runKills
            runKills = 0
            UserDefaults.standard.set(kills, forKey: "gameKills")
        }
    }

    private func burst(at p: CGPoint) {
        for _ in 0..<8 {
            sparks.append(Spark(pos: p, vel: CGVector(dx: .random(in: -120...120),
                                                      dy: .random(in: -120...120))))
        }
    }

    /// Enemy `i` dies: sparks, combo, score, xp bubbles — splitters split,
    /// tanks and bosses drop power-ups (others rarely do).
    private func kill(_ i: Int) {
        let e = enemies[i]
        burst(at: e.pos)
        combo = time - lastKill < 2 ? combo + 1 : 1
        lastKill = time
        runKills += 1
        award("blood")
        if comboMult >= 5 { award("combo5") }
        let xpGain = e.kind.xp * (e.elite ? 2 : 1)
        let pts = xpGain * 10 * level * comboMult
        score += pts
        pops.append(Pop(pos: e.pos, text: "+\(pts)"))
        for _ in 0..<xpGain {
            bubbles.append(Bubble(
                pos: CGPoint(x: e.pos.x + .random(in: -14...14), y: e.pos.y + .random(in: -10...10)),
                vel: CGVector(dx: .random(in: -15...15), dy: 45)))
        }
        if e.kind == .splitter {
            for dx in [-70.0, 70.0] {
                enemies.append(Enemy(pos: e.pos,
                                     vel: CGVector(dx: dx, dy: 55 * spd),
                                     kind: .mini, face: "🧍", shootAt: .infinity))
            }
        }
        let chance = (e.kind == .boss ? 1 : e.kind == .tank || e.kind == .security ? 0.35 : 0.06)
            * (lucky ? 2 : 1)
        if Double.random(in: 0..<1) < chance {
            drops.append(Drop(pos: e.pos, power: Power.allCases.randomElement()!))
        }
        // ponytail: upgrades are rare random drops — ~2.5% per kill, bosses a
        // solid bet — tune these two numbers if runs feel starved or flooded
        let uChance = (e.kind == .boss ? 0.35 : 0.025) * (lucky ? 2 : 1)
        if let u = upgradePool.randomElement(), Double.random(in: 0..<1) < uChance {
            drops.append(Drop(pos: e.pos, upgrade: u))
        }
        if e.kind == .boss {
            // downing the stage boss: fireworks, a score bonus, and a coin purse
            shake(8)
            burst(at: e.pos)
            burst(at: e.pos)
            let bonus = 250 * level
            score += bonus
            pops.append(Pop(pos: CGPoint(x: Self.W / 2, y: Self.H * 0.4),
                            text: "BOSS DOWN +\(bonus)", life: 1.6))
            play("Hero", 0.6)
            for _ in 0..<(e.face == "🤵" ? 6 : 3) {
                coinDrops.append(Bubble(pos: e.pos,
                                        vel: CGVector(dx: .random(in: -40...40), dy: 55)))
            }
        } else {
            play("Pop", 0.2)
            // ponytail: flat coin rate (20%, 40% lucky) for everyone but bosses
            if Int.random(in: 0..<5) < (lucky ? 2 : 1) {
                coinDrops.append(Bubble(pos: e.pos,
                                        vel: CGVector(dx: .random(in: -20...20), dy: 55)))
            }
        }
        enemies.remove(at: i)
    }

    private func shake(_ m: CGFloat) {
        shakeMag = m
        shakeUntil = time + 0.3
    }

    /// Magnet-and-fall physics shared by xp bubbles and crab-coins; returns
    /// how many reached the crab (off-screen strays just vanish).
    private func magnetSweep(_ items: inout [Bubble], _ dt: CGFloat) -> Int {
        for i in items.indices {
            let d = CGVector(dx: crabPos.x - items[i].pos.x, dy: crabPos.y - items[i].pos.y)
            let dist = max(1, sqrt(d.dx * d.dx + d.dy * d.dy))
            if dist < magnetR {
                items[i].vel = CGVector(dx: d.dx / dist * 260, dy: d.dy / dist * 260)
            }
            items[i].pos.x += items[i].vel.dx * dt
            items[i].pos.y += items[i].vel.dy * dt
        }
        var n = 0
        items.removeAll {
            if hypot($0.pos.x - crabPos.x, $0.pos.y - crabPos.y) < 20 {
                n += 1
                return true
            }
            return $0.pos.y > Self.H + 12
        }
        return n
    }

    /// Shop click: first time buys (if affordable), then equips. All persistent.
    func selectSkin(_ s: Skin) {
        if !owned.contains(s.rawValue) {
            guard coins >= s.price else { return }
            coins -= s.price
            owned.insert(s.rawValue)
            UserDefaults.standard.set(coins, forKey: "gameCoins")
            UserDefaults.standard.set(Array(owned), forKey: "gameSkinsOwned")
            if owned.count == Skin.allCases.count { award("closet") }
        }
        skin = s
        UserDefaults.standard.set(s.rawValue, forKey: "gameSkin")
    }

    /// A collected power-up lands immediately.
    private func apply(_ p: Power) {
        pops.append(Pop(pos: CGPoint(x: crabX, y: crabPos.y - 44), text: p.label))
        play("Purr", 0.5)
        switch p {
        case .bomb:
            shake(8)
            enemyShots = []
            for i in enemies.indices.reversed() {
                enemies[i].hp -= 4
                enemies[i].hitAt = time
                if enemies[i].hp <= 0 { kill(i) }
            }
        case .freeze:
            frozenUntil = max(frozenUntil, time + 4)
        case .star:
            starUntil = time + 4
        }
    }

    /// Full xp bar: next stage. Every level-up also drops the boss in — each
    /// round ends with a boss stage.
    private func maybeLevelUp() {
        guard xp >= xpNext else { return }
        xp -= xpNext
        // linear ramp: deep stages stay reachable — the stage table carries
        // the difficulty, not an xp wall
        xpNext += 6
        level += 1
        levelUpAt = time
        play("Glass", 0.5)
        if level > bestStage {
            bestStage = level
            UserDefaults.standard.set(bestStage, forKey: "gameBestStage")
        }
        if level >= 5 { award("stage5") }
        if level >= 10 { award("stage10") }
        if level >= 20 { award("stage20") }
        enemies.append(make(.boss, at: CGPoint(x: Self.W / 2, y: -40)))
    }

    func step(_ dt: CGFloat) {
        defer { frame += 1 }
        for i in sparks.indices {
            sparks[i].pos.x += sparks[i].vel.dx * dt
            sparks[i].pos.y += sparks[i].vel.dy * dt
            sparks[i].age += dt
        }
        sparks.removeAll { $0.age > 0.5 }
        for i in pops.indices {
            pops[i].pos.y -= 40 * dt
            pops[i].age += dt
        }
        pops.removeAll { $0.age > $0.life }
        guard scene != .paused, !over else { return }
        time += dt
        // menu keeps only the clock running — the starfield drift and blink
        guard scene == .playing else { return }

        if dir != 0 { facing = dir }
        let dashing = time < dashUntil
        let vx = dashing ? dashDir.dx * speed * 3.4 : dir * speed
        let vy = dashing ? dashDir.dy * speed * 3.4 : dirY * speed
        crabX = min(Self.W - 26, max(26, crabX + vx * dt))
        crabY = min(Self.H - 32, max(56, crabY + vy * dt))   // stay below the HUD
        if dashing {
            sparks.append(Spark(pos: CGPoint(x: crabX - dashDir.dx * 14,
                                             y: crabY - dashDir.dy * 14),
                                vel: CGVector(dx: -dashDir.dx * 60,
                                              dy: -dashDir.dy * 60 + .random(in: -30...30))))
        }

        // auto-fire: aim the volley at the nearest human, fan extra shrimp out
        if time - lastShot >= shotCD,
           let target = enemies.min(by: {
               hypot($0.pos.x - crabX, $0.pos.y - crabPos.y)
                   < hypot($1.pos.x - crabX, $1.pos.y - crabPos.y)
           }) {
            lastShot = time
            let origin = CGPoint(x: crabX, y: crabY - 20)
            let base = atan2(target.pos.y - origin.y, target.pos.x - origin.x)
            for k in 0..<volley {
                let a = base + (CGFloat(k) - CGFloat(volley - 1) / 2) * 0.16
                shots.append(Shot(pos: origin,
                                  vel: CGVector(dx: cos(a) * 380, dy: sin(a) * 380),
                                  pierce: pierce))
            }
        }

        for i in shots.indices {
            shots[i].pos.x += shots[i].vel.dx * dt
            shots[i].pos.y += shots[i].vel.dy * dt
        }
        shots.removeAll { $0.pos.y < -10 || $0.pos.y > Self.H + 10
            || $0.pos.x < -10 || $0.pos.x > Self.W + 10 }

        if time >= nextSpawn {
            // per-stage pace, with an in-run creep so camping never goes quiet
            nextSpawn = time + .random(in: 0.5...1.2) * st.pace
                * (1.4 - 0.6 * min(1, time / 240))
            spawn()
        }

        // office events: a banner-and-twist every half-minute or so
        if time >= nextEvent {
            nextEvent = time + .random(in: 28...45)
            let ev = OfficeEvent.allCases.randomElement()!
            event = ev
            switch ev {
            case .review: eventUntil = time + 5
            case .coffee:
                eventUntil = time + 3
                frozenUntil = max(frozenUntil, time + 3)
            case .friday: eventUntil = time + 8
            case .meeting:
                eventUntil = time + 2
                for k in -2...2 {   // a V formation marches in
                    var e = make(.walker, at: CGPoint(x: Self.W / 2 + CGFloat(k) * 42,
                                                      y: -16 - abs(CGFloat(k)) * 30))
                    e.vel = CGVector(dx: 0, dy: 55 * spd)
                    enemies.append(e)
                }
            }
        }

        // the fax machine: a fragile score piñata crossing the top
        if time >= nextFax {
            nextFax = time + .random(in: 20...35)
            enemies.append(make(.fax, at: .zero))
        }

        // per-kind brains: walkers wander and throw pencils, runners home in,
        // the fax flies straight through, the boss parks at the top — spread
        // volleys from the manager, summoned minis from HR. A freeze (🧊 or
        // coffee break) suspends all of it; a performance review is a sprint.
        let evSpeed: CGFloat = event == .review && time < eventUntil ? 1.8 : 1
        if time >= frozenUntil {
            for i in enemies.indices {
                var e = enemies[i]
                switch e.kind {
                case .runner:
                    e.vel.dx = max(-150, min(150, e.vel.dx + (crabX > e.pos.x ? 260 : -260) * dt))
                case .sales:   // weaves side to side, phase keyed on spawn column
                    e.vel.dx = sin((time + e.pos.y / 60) * 5) * 140 * st.speed
                case .consultant:   // descends, then parks and strafes
                    if e.pos.y >= 84 { e.vel.dy = 0 }
                case .zombie:   // homes in, capped so it stays dodgeable
                    let d = CGVector(dx: crabPos.x - e.pos.x, dy: crabPos.y - e.pos.y)
                    let len = max(1, hypot(d.dx, d.dy))
                    e.vel.dx += d.dx / len * 240 * dt
                    e.vel.dy += d.dy / len * 240 * dt
                    let v = hypot(e.vel.dx, e.vel.dy)
                    let cap = 130 * st.speed
                    if v > cap {
                        e.vel.dx *= cap / v
                        e.vel.dy *= cap / v
                    }
                case .boss:
                    // relentless chase — floats straight at Clawd, never leaves
                    let d = CGVector(dx: crabPos.x - e.pos.x, dy: crabPos.y - e.pos.y)
                    let len = max(1, hypot(d.dx, d.dy))
                    e.vel = CGVector(dx: d.dx / len * 55, dy: d.dy / len * 55)
                case .fax:
                    break
                default:
                    e.vel.dx = max(-90, min(90, e.vel.dx + .random(in: -300...300) * dt))
                }
                e.pos.x += e.vel.dx * evSpeed * dt
                e.pos.y += e.vel.dy * evSpeed * dt
                let m: CGFloat = e.kind == .boss ? 60 : 24
                if e.kind != .fax, e.pos.x < m || e.pos.x > Self.W - m {
                    e.vel.dx = -e.vel.dx
                    e.pos.x = max(m, min(Self.W - m, e.pos.x))
                }
                if e.kind == .walker, time >= e.shootAt {
                    e.shootAt = time + .random(in: 1.5...4.0)
                        * max(0.5, 1.6 - CGFloat(level) * 0.04)
                    let d = CGVector(dx: crabPos.x - e.pos.x, dy: crabPos.y - e.pos.y)
                    let len = max(1, sqrt(d.dx * d.dx + d.dy * d.dy))
                    enemyShots.append(Shot(
                        pos: e.pos,
                        vel: CGVector(dx: d.dx / len * 170 + .random(in: -40...40),
                                      dy: d.dy / len * 170)))
                }
                if e.kind == .consultant, time >= e.shootAt {
                    // sniper: a fast aimed shot from the parking row
                    e.shootAt = time + .random(in: 2.0...3.2)
                    let base = atan2(crabPos.y - e.pos.y, crabPos.x - e.pos.x)
                    enemyShots.append(Shot(pos: e.pos,
                                           vel: CGVector(dx: cos(base) * 250,
                                                         dy: sin(base) * 250)))
                }
                if e.kind == .boss, time >= e.shootAt {
                    // each face is a pattern: HR summons, the CTO fires aimed
                    // bursts, the CEO does both, the manager sprays a spread
                    let summon = {
                        for dx in [-30.0, 30.0] {
                            self.enemies.append(Enemy(
                                pos: CGPoint(x: e.pos.x + dx, y: e.pos.y + 20),
                                vel: CGVector(dx: dx, dy: 60),
                                kind: .mini, face: "🧍", shootAt: .infinity))
                        }
                    }
                    let spray = { (offs: [Double], v: CGFloat) in
                        let base = atan2(self.crabPos.y - e.pos.y, self.crabPos.x - e.pos.x)
                        for off in offs {
                            self.enemyShots.append(Shot(pos: e.pos,
                                                        vel: CGVector(dx: cos(base + off) * v,
                                                                      dy: sin(base + off) * v)))
                        }
                    }
                    switch e.face {
                    case "👩‍💼":
                        e.shootAt = time + .random(in: 1.8...2.6)
                        summon()
                    case "🧑‍💻":
                        e.shootAt = time + .random(in: 1.6...2.4)
                        spray([-0.11, -0.04, 0.04, 0.11], 230)
                    case "🤵":
                        e.shootAt = time + .random(in: 1.0...1.6)
                        if Bool.random() { spray([-0.5, -0.25, 0, 0.25, 0.5], 200) }
                        else { summon() }
                    default:
                        e.shootAt = time + .random(in: 1.0...1.6)
                        spray([-0.35, 0, 0.35], 190)
                    }
                }
                enemies[i] = e
            }
        }
        enemies.removeAll { $0.kind == .fax && ($0.pos.x < -30 || $0.pos.x > Self.W + 30) }

        for i in enemyShots.indices {
            enemyShots[i].pos.x += enemyShots[i].vel.dx * dt
            enemyShots[i].pos.y += enemyShots[i].vel.dy * dt
        }
        enemyShots.removeAll { $0.pos.y > Self.H + 10 || $0.pos.x < -10 || $0.pos.x > Self.W + 10 }

        // shrimp vs human: generous per-kind square hitbox, emoji aren't precise
        for s in shots.indices.reversed() {
            guard let e = enemies.firstIndex(where: {
                let r = $0.kind.size * 0.6 + 4
                return abs($0.pos.x - shots[s].pos.x) < r && abs($0.pos.y - shots[s].pos.y) < r
            }) else { continue }
            enemies[e].hp -= power
            enemies[e].hitAt = time
            if enemies[e].hp <= 0 { kill(e) } else { burst(at: enemies[e].pos) }
            if shots[s].pierce > 0 { shots[s].pierce -= 1 } else { shots.remove(at: s) }
        }

        // orbit shrimp chew on anything they brush, on a per-enemy cooldown
        for oi in 0..<orbits {
            let p = orbitPos(oi)
            for ei in enemies.indices.reversed() {
                let r = enemies[ei].kind.size * 0.6 + 4
                guard time - enemies[ei].orbAt > 0.4,
                      abs(enemies[ei].pos.x - p.x) < r, abs(enemies[ei].pos.y - p.y) < r
                else { continue }
                enemies[ei].orbAt = time
                enemies[ei].hitAt = time
                enemies[ei].hp -= 1
                if enemies[ei].hp <= 0 { kill(ei) }
            }
        }

        // shrimp vs pencil: shooting an incoming shot knocks it out of the air
        for s in shots.indices.reversed() {
            if let p = enemyShots.firstIndex(where: {
                abs($0.pos.x - shots[s].pos.x) < 14 && abs($0.pos.y - shots[s].pos.y) < 14
            }) {
                burst(at: enemyShots[p].pos)
                enemyShots.remove(at: p)
                if shots[s].pierce > 0 { shots[s].pierce -= 1 } else { shots.remove(at: s) }
            }
        }

        // xp bubbles and crab-coins drift down until the magnet grabs them
        xp += magnetSweep(&bubbles, dt) * (event == .friday && time < eventUntil ? 2 : 1)
        maybeLevelUp()
        let banked = magnetSweep(&coinDrops, dt)
        if banked > 0 {
            coins += banked
            UserDefaults.standard.set(coins, forKey: "gameCoins")
            pops.append(Pop(pos: CGPoint(x: crabX, y: crabPos.y - 30), text: "+\(banked)🟡"))
            play("Tink", 0.4)
            if coins >= 100 { award("rich") }
        }

        // falling power-ups and upgrades; effects land the moment they're caught
        for i in drops.indices { drops[i].pos.y += 60 * dt }
        var caught: [Drop] = []
        drops.removeAll {
            if abs($0.pos.x - crabX) < 24, abs($0.pos.y - crabPos.y) < 26 {
                caught.append($0)
                return true
            }
            return $0.pos.y > Self.H + 12
        }
        for d in caught {
            if let p = d.power { apply(p) }
            if let u = d.upgrade { apply(u) }
        }

        // pencil or body contact costs a life; a human slipping past does too
        // — unless the ⭐ is live or we're mid-dash, in which case contact wrecks *them*
        if enemyShots.contains(where: { abs($0.pos.x - crabX) < 22 && abs($0.pos.y - crabPos.y) < 18 }) {
            enemyShots.removeAll { abs($0.pos.x - crabX) < 22 && abs($0.pos.y - crabPos.y) < 18 }
            hurt()
        }
        if time < starUntil || time < dashUntil {
            for i in enemies.indices.reversed()
            where abs(enemies[i].pos.x - crabX) < max(24, enemies[i].kind.size * 0.6)
                && abs(enemies[i].pos.y - crabPos.y) < 22 {
                enemies[i].hp -= 4
                enemies[i].hitAt = time
                if enemies[i].hp <= 0 { kill(i) }
            }
        } else if enemies.contains(where: {
            abs($0.pos.x - crabX) < max(24, $0.kind.size * 0.6) && abs($0.pos.y - crabPos.y) < 22
        }) {
            hurt()
        }
        for i in enemies.indices.reversed()
        where enemies[i].kind != .boss && enemies[i].pos.y > Self.H - 14 {
            enemies.remove(at: i)
            hurt()
        }
    }
}

struct GameView: View {
    @StateObject private var model = GameModel()
    @FocusState private var focused: Bool
    @State private var leftHeld = false
    @State private var rightHeld = false
    @State private var upHeld = false
    @State private var downHeld = false
    @State private var shopSel = 0   // keyboard cursor in the skin shop

    // All poses pre-rendered once per skin at 1.5pt per cell; the game loop
    // just picks a frame.
    private static var skinCache: [Skin: (idle: [NSImage], walk: [NSImage], shoot: [NSImage])] = [:]
    static func poses(_ skin: Skin) -> (idle: [NSImage], walk: [NSImage], shoot: [NSImage]) {
        if let c = skinCache[skin] { return c }
        let outfit = ClawdAnims.Anim(uniq: [skin.outfit], seq: [0])
        func render(_ a: ClawdAnims.Anim) -> [NSImage] {
            frames(a.seq.count, wide: GameCrab.cellsWide) {
                drawAnim(a, frame: $0, at: .zero, scale: 1.5, colors: skin.colors)
                if !skin.outfit.isEmpty {
                    drawAnim(outfit, frame: 0, at: .zero, scale: 1.5, colors: skin.colors)
                }
            }
        }
        let p = (idle: render(GameCrab.idle), walk: render(GameCrab.walk),
                 shoot: render(GameCrab.shoot))
        skinCache[skin] = p
        return p
    }

    private static func frames(_ n: Int, wide: Int, _ draw: @escaping (Int) -> Void) -> [NSImage] {
        (0..<n).map { f in
            NSImage(size: NSSize(width: CGFloat(wide) * 1.5,
                                 height: CGFloat(Clawd.cellsHigh) * 1.5),
                    flipped: false) { _ in
                draw(f)
                return true
            }
        }
    }

    /// The game's one typeface: bold monospaced, arcade by way of a terminal.
    private func arcade(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    private func num(_ n: Int) -> String { String(format: "%06d", n) }

    var body: some View {
        GeometryReader { geo in
            // panels are laid out at world scale; match the canvas's context scale
            let s = min(geo.size.width / GameModel.W, geo.size.height / GameModel.H)
            ZStack {
                canvas
                if model.scene == .paused { pausePanel(s) }
                if model.scene == .shop { shopPanel(s) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(.black)
    }

    private var canvas: some View {
        Canvas { ctx, size in
            _ = model.frame  // redraw on every tick
            // world stays W×H; scale the *context*, not the rendered bitmap, so text and
            // shapes stay vector-crisp at any window size (letterboxed on black)
            let world = CGSize(width: GameModel.W, height: GameModel.H)
            let s = min(size.width / world.width, size.height / world.height)
            var ctx = ctx
            ctx.translateBy(x: (size.width - world.width * s) / 2,
                            y: (size.height - world.height * s) / 2)
            ctx.scaleBy(x: s, y: s)
            ctx.clip(to: Path(CGRect(origin: .zero, size: world)))

            ctx.fill(Path(CGRect(origin: .zero, size: world)),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.10), .vSurface]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: world.height)))

            // drifting starfield — positions are a fixed hash of the index, only y scrolls
            if Prefs.bool("gameStars", true) {
                for i in 0..<40 {
                    let x = CGFloat((i * 137) % Int(GameModel.W))
                    let y = (CGFloat((i * 89) % Int(GameModel.H)) + model.time * 14)
                        .truncatingRemainder(dividingBy: GameModel.H)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)),
                             with: .color(.white.opacity(i % 3 == 0 ? 0.25 : 0.1)))
                }
            }

            if model.scene == .menu || model.scene == .shop { drawMenu(ctx, world) }
            else { drawGame(ctx, world) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { press in
            switch press.key {
            case .leftArrow:
                if model.scene == .shop {
                    if press.phase != .up {
                        shopSel = (shopSel + Skin.allCases.count - 1) % Skin.allCases.count
                    }
                } else if press.phase == .down { leftHeld = true; model.dir = -1 }
                else if press.phase == .up { leftHeld = false; model.dir = rightHeld ? 1 : 0 }
            case .rightArrow:
                if model.scene == .shop {
                    if press.phase != .up { shopSel = (shopSel + 1) % Skin.allCases.count }
                } else if press.phase == .down { rightHeld = true; model.dir = 1 }
                else if press.phase == .up { rightHeld = false; model.dir = leftHeld ? -1 : 0 }
            case .upArrow:
                if press.phase == .down { upHeld = true; model.dirY = -1 }
                else if press.phase == .up { upHeld = false; model.dirY = downHeld ? 1 : 0 }
            case .downArrow:
                if press.phase == .down { downHeld = true; model.dirY = 1 }
                else if press.phase == .up { downHeld = false; model.dirY = upHeld ? -1 : 0 }
            case .space:
                if press.phase == .down { model.dash() }
            case .return:
                guard press.phase == .down else { break }
                if press.modifiers.contains(.command) { NSApp.keyWindow?.toggleFullScreen(nil) }
                else if model.scene == .shop { model.selectSkin(Skin.allCases[shopSel]) }
                else if model.scene == .paused { model.scene = .playing }
                else if model.scene == .menu || model.over { model.reset() }
            case .escape:
                guard press.phase == .down else { break }
                switch model.scene {
                case .playing where model.over:   // back to the title screen
                    model.reset()
                    model.scene = .menu
                case .playing: model.scene = .paused
                case .paused: model.scene = .playing
                case .shop: model.scene = .menu
                case .menu: break
                }
            default:
                if press.phase == .down, model.scene == .menu, press.characters == "s" {
                    shopSel = Skin.allCases.firstIndex(of: model.skin) ?? 0
                    model.scene = .shop
                    break
                }
                if press.phase == .down, model.scene == .paused {
                    switch press.characters {
                    case "r": model.reset()
                    case "m":
                        model.reset()
                        model.scene = .menu
                    case "1": flip("gameMap")
                    case "2": flip("gameStars")
                    case "3": flip("gameSound")
                    default: return .ignored
                    }
                    break
                }
                return .ignored
            }
            return .handled
        }
        .onAppear {
            focused = true
            model.start()
        }
        .onDisappear { model.stop() }
    }

    // MARK: Title screen

    private func drawMenu(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2
        ctx.draw(Text("CRAB INVADERS").font(arcade(28)).foregroundColor(.vPrimary),
                 at: CGPoint(x: cx, y: 96))
        ctx.draw(Text("CLAWD VS THE ENDLESS OFFICE").font(arcade(10)).tracking(4)
                    .foregroundColor(.vMuted),
                 at: CGPoint(x: cx, y: 126))
        let idle = Self.poses(model.skin).idle
        ctx.draw(Image(nsImage: idle[Int(model.time * 12) % idle.count])
                    .interpolation(.none),
                 at: CGPoint(x: cx, y: 205))
        ctx.draw(Text("HI SCORE \(num(model.hi))").font(arcade(11)).foregroundColor(.vSecondary),
                 at: CGPoint(x: cx, y: 272))
        if model.bestStage > 1 {
            ctx.draw(Text("BEST STAGE \(model.bestStage) — \(GameModel.stage(model.bestStage).name)")
                        .font(arcade(9)).foregroundColor(.vSecondary),
                     at: CGPoint(x: cx, y: 290))
        }
        ctx.draw(Text("🏆 \(model.ach.count)/\(GameModel.achievements.count)"
                      + " · 👔 \(model.kills) FILED")
                    .font(arcade(9)).foregroundColor(.vMuted),
                 at: CGPoint(x: cx, y: 306))
        ctx.draw(Text("🟡 \(model.coins) · PRESS S FOR SKIN SHOP").font(arcade(9))
                    .foregroundColor(.vSecondary),
                 at: CGPoint(x: cx, y: 322))
        if Int(model.time * 2) % 2 == 0 {
            ctx.draw(Text("PRESS ⏎ TO START").font(arcade(14)).foregroundColor(.vPrimary),
                     at: CGPoint(x: cx, y: 346))
        }
        ctx.draw(Text("←↑↓→ MOVE · SPACE DASH · AUTO-FIRE · COLLECT 💎 · LEVEL UP")
                    .font(arcade(9, .semibold)).foregroundColor(.vMuted),
                 at: CGPoint(x: cx, y: size.height - 24))
    }

    // MARK: Play field

    private func drawGame(_ ctx: GraphicsContext, _ size: CGSize) {
        var ctx = ctx
        if model.time < model.shakeUntil {   // screen shake, decaying
            let d = (model.shakeUntil - model.time) / 0.3
            ctx.translateBy(x: sin(model.time * 73) * model.shakeMag * d,
                            y: cos(model.time * 61) * model.shakeMag * d)
        }
        for b in model.bubbles {
            ctx.draw(Text("💎").font(.system(size: 11)), at: b.pos)
        }
        for c in model.coinDrops {
            ctx.draw(Text("🟡").font(.system(size: 12)), at: c.pos)
        }
        for d in model.drops {
            var c = ctx
            c.translateBy(x: d.pos.x, y: d.pos.y)
            c.rotate(by: .radians(sin(model.time * 6 + d.pos.y) * 0.2))
            if let u = d.upgrade {   // a cyan ring so the rare drop reads as special
                c.stroke(Path(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28)),
                         with: .color(.cyan.opacity(0.5 + 0.2 * sin(model.time * 6))),
                         lineWidth: 1.5)
                c.draw(Text(u.icon).font(.system(size: 18)), at: .zero)
            } else if let p = d.power {
                c.draw(Text(p.face).font(.system(size: 20)), at: .zero)
            }
        }
        for e in model.enemies {
            // wobble as they wander — phase keyed on x so the swarm isn't in lockstep
            var c = ctx
            c.translateBy(x: e.pos.x, y: e.pos.y)
            c.rotate(by: .radians(sin(model.time * 8 + e.pos.x) * 0.12))
            if model.time - e.hitAt < 0.12 {   // damage flash
                c.fill(Path(ellipseIn: CGRect(x: -e.kind.size * 0.6, y: -e.kind.size * 0.6,
                                              width: e.kind.size * 1.2, height: e.kind.size * 1.2)),
                       with: .color(.white.opacity(0.5)))
            }
            if model.time < model.frozenUntil {   // iced over
                c.fill(Path(ellipseIn: CGRect(x: -e.kind.size * 0.6, y: -e.kind.size * 0.6,
                                              width: e.kind.size * 1.2, height: e.kind.size * 1.2)),
                       with: .color(.cyan.opacity(0.3)))
            }
            if e.elite {   // angry variant wears an orange ring
                c.stroke(Path(ellipseIn: CGRect(x: -e.kind.size * 0.68, y: -e.kind.size * 0.68,
                                                width: e.kind.size * 1.36,
                                                height: e.kind.size * 1.36)),
                         with: .color(.orange.opacity(0.7)), lineWidth: 1.5)
            }
            c.draw(Text(e.face).font(.system(size: e.kind.size)), at: .zero)
            if e.kind == .boss {
                let w: CGFloat = 70, frac = CGFloat(e.hp) / CGFloat(e.maxHp)
                ctx.fill(Path(CGRect(x: e.pos.x - w / 2, y: e.pos.y - 48, width: w, height: 5)),
                         with: .color(.black.opacity(0.5)))
                ctx.fill(Path(CGRect(x: e.pos.x - w / 2, y: e.pos.y - 48, width: w * frac, height: 5)),
                         with: .color(Color(P.warning)))
            }
        }
        for s in model.shots {
            // shrimp fly nose-first along their heading
            var c = ctx
            c.translateBy(x: s.pos.x, y: s.pos.y)
            c.rotate(by: .radians(atan2(s.vel.dy, s.vel.dx) + .pi / 2))
            c.draw(Text("🦐").font(.system(size: 14)), at: .zero)
        }
        for i in 0..<model.orbits {
            let p = model.orbitPos(i)
            var c = ctx
            c.translateBy(x: p.x, y: p.y)
            c.rotate(by: .radians(model.time * 3 + .pi / 2))
            c.draw(Text("🦐").font(.system(size: 13)), at: .zero)
        }
        for s in model.enemyShots {
            var c = ctx
            c.translateBy(x: s.pos.x, y: s.pos.y)
            c.rotate(by: .radians(model.time * 10))
            c.draw(Text("✏️").font(.system(size: 13)), at: .zero)
        }
        for s in model.sparks {
            ctx.fill(Path(ellipseIn: CGRect(x: s.pos.x - 2, y: s.pos.y - 2, width: 4, height: 4)),
                     with: .color(.orange.opacity(1 - s.age * 2)))
        }
        for p in model.pops {   // floating score / pickup / trophy callouts
            ctx.draw(Text(p.text).font(arcade(10))
                        .foregroundColor(.orange.opacity(Double(1 - p.age / p.life))),
                     at: p.pos)
        }

        // 🛡️ shell ring while it's charged and ready to soak a hit
        if model.shell, model.time - model.shellAt >= model.shellCD {
            ctx.stroke(Path(ellipseIn: CGRect(x: model.crabPos.x - 24, y: model.crabPos.y - 24,
                                              width: 48, height: 48)),
                       with: .color(.cyan.opacity(0.3 + 0.1 * sin(model.time * 4))),
                       lineWidth: 1.5)
        }

        // ⭐ aura: while it's live, Clawd glows and contact is their problem
        if model.time < model.starUntil {
            ctx.fill(Path(ellipseIn: CGRect(x: model.crabPos.x - 26, y: model.crabPos.y - 26,
                                            width: 52, height: 52)),
                     with: .color(.yellow.opacity(0.25 + 0.1 * sin(model.time * 12))))
        }

        // blink while invincible so a hit reads even mid-swarm
        if model.time > model.hurtUntil || Int(model.time * 10) % 2 == 0 {
            // pose: shoot anim through the 0.25s after firing, walk cycle while
            // moving (mirrored to face the way he walks), breathe-and-blink idle
            // otherwise — plus lean/bob and a 0.12s squash-and-stretch recoil on top
            let sinceShot = model.time - model.lastShot
            let recoil = max(0, 1 - sinceShot / 0.12)
            let img: NSImage
            var flip: CGFloat = 1
            let poses = Self.poses(model.skin)
            if model.lastShot >= 0, sinceShot < 0.25 {
                img = poses.shoot[sinceShot < 0.15 ? 1 : 0]
            } else if model.dir != 0 || model.dirY != 0 {
                img = poses.walk[Int(model.time * 14) % poses.walk.count]
                flip = model.facing
            } else {
                img = poses.idle[Int(model.time * 12) % poses.idle.count]
            }
            let bob = model.dir == 0 && model.dirY == 0 ? 0 : sin(model.time * 18) * 2
            var c = ctx
            c.translateBy(x: model.crabPos.x, y: model.crabPos.y + bob)
            c.rotate(by: .radians(model.dir * 0.12))
            c.scaleBy(x: flip * (1 + 0.18 * recoil), y: 1 - 0.22 * recoil)
            c.draw(Image(nsImage: img).interpolation(.none), at: .zero)
            if recoil > 0 {
                ctx.fill(Path(ellipseIn: CGRect(x: model.crabX - 5, y: model.crabPos.y - 36,
                                                width: 10, height: 10)),
                         with: .color(.orange.opacity(0.6 * recoil)))
            }
        }

        drawHUD(ctx, size)
        if Prefs.bool("gameMap", true) { drawMiniMap(ctx, size) }

        // office-event banner while the twist is live
        if let ev = model.event, model.time < model.eventUntil {
            ctx.draw(Text(ev.banner).font(arcade(11)).foregroundColor(.cyan),
                     at: CGPoint(x: size.width / 2, y: 66))
        }

        // stage banner, flashing through its first moment
        if model.level > 1, model.time - model.levelUpAt < 1.6 {
            if Int(model.time * 5) % 2 == 0 {
                ctx.draw(Text("STAGE \(model.level)").font(arcade(28)).foregroundColor(.vPrimary),
                         at: CGPoint(x: size.width / 2, y: size.height * 0.32))
            }
            ctx.draw(Text(model.st.name).font(arcade(12)).foregroundColor(.vSecondary),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.32 + 26))
        }

        if model.over {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            ctx.draw(Text("GAME OVER").font(arcade(30)).foregroundColor(.vPrimary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2 - 40))
            ctx.draw(Text("SCORE \(num(model.score)) · STAGE \(model.level)").font(arcade(12))
                        .foregroundColor(.vSecondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2 - 6))
            if model.score > 0, model.score == model.hi {
                ctx.draw(Text("NEW HI SCORE!").font(arcade(12)).foregroundColor(.orange),
                         at: CGPoint(x: size.width / 2, y: size.height / 2 + 18))
            }
            ctx.draw(Text("⏎ PLAY AGAIN · ⎋ MENU").font(arcade(10, .semibold))
                        .foregroundColor(.vMuted),
                     at: CGPoint(x: size.width / 2, y: size.height / 2 + 44))
        }
    }

    /// The bar across the top: score, level, hi-score, lives — xp bar underneath.
    private func drawHUD(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 26)),
                 with: .color(.black.opacity(0.35)))
        ctx.fill(Path(CGRect(x: 0, y: 26, width: size.width, height: 1)),
                 with: .color(.vBorder))
        let frac = min(1, CGFloat(model.xp) / CGFloat(max(1, model.xpNext)))
        ctx.fill(Path(CGRect(x: 0, y: 27, width: size.width * frac, height: 3)),
                 with: .color(.cyan.opacity(0.7)))
        ctx.draw(Text("SCORE \(num(model.score))").font(arcade(10)).foregroundColor(.vPrimary),
                 at: CGPoint(x: 12, y: 13), anchor: .leading)
        ctx.draw(Text("🟡\(model.coins)").font(arcade(9)).foregroundColor(.yellow),
                 at: CGPoint(x: 118, y: 13), anchor: .leading)
        ctx.draw(Text("STAGE \(model.level) · \(model.st.name)").font(arcade(9))
                    .foregroundColor(.vSecondary),
                 at: CGPoint(x: size.width / 2, y: 13))
        ctx.draw(Text("HI \(num(max(model.hi, model.score)))").font(arcade(9))
                    .foregroundColor(.vMuted),
                 at: CGPoint(x: size.width - 66, y: 13), anchor: .trailing)
        ctx.draw(Text(String(repeating: "❤️", count: max(0, model.lives))).font(.system(size: 10)),
                 at: CGPoint(x: size.width - 12, y: 13), anchor: .trailing)

        // combo callout while the chain is alive
        if model.comboMult >= 2, model.time - model.lastKill < 2 {
            ctx.draw(Text("COMBO ×\(model.comboMult)").font(arcade(12)).foregroundColor(.orange),
                     at: CGPoint(x: size.width / 2, y: 44))
        }
        // dash charge, bottom-right
        let ready = model.time - model.lastDash >= model.dashCD
        ctx.draw(Text(ready ? "⚡DASH READY" : "⚡···").font(arcade(8, .semibold))
                    .foregroundColor(ready ? .vSecondary : .vMuted),
                 at: CGPoint(x: size.width - 12, y: size.height - 14), anchor: .trailing)
    }

    /// Radar in the corner: the whole field scaled down, hostiles and Clawd as dots.
    private func drawMiniMap(_ ctx: GraphicsContext, _ size: CGSize) {
        let mw: CGFloat = 76, mh = mw * GameModel.H / GameModel.W
        let r = CGRect(x: 10, y: size.height - mh - 10, width: mw, height: mh)
        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(.black.opacity(0.5)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.vBorder), lineWidth: 1)
        func dot(_ p: CGPoint, _ s: CGFloat, _ c: Color) {
            ctx.fill(Path(ellipseIn: CGRect(x: r.minX + p.x / GameModel.W * mw - s / 2,
                                            y: r.minY + p.y / GameModel.H * mh - s / 2,
                                            width: s, height: s)),
                     with: .color(c))
        }
        for e in model.enemies { dot(e.pos, e.kind == .boss ? 5 : 3, Color(P.warning)) }
        for s in model.enemyShots { dot(s.pos, 2, .orange) }
        for b in model.bubbles { dot(b.pos, 2, .cyan) }
        for c in model.coinDrops { dot(c.pos, 2, .yellow) }
        for d in model.drops { dot(d.pos, 3, .white) }
        dot(model.crabPos, 4, Color(P.good))
    }

    // MARK: Skin shop

    /// Menu's S key: palette-swap skins bought with crab-coins. Click a card to
    /// buy (first time) or equip; ⎋ back to the title.
    private func shopPanel(_ s: CGFloat) -> some View {
        VStack(spacing: 12 * s) {
            Text("SKIN SHOP")
                .font(.system(size: 13 * s, weight: .bold, design: .monospaced))
                .tracking(3 * s)
                .foregroundColor(.vPrimary)
            Text("🟡 \(model.coins)")
                .font(.system(size: 12 * s, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)
            HStack(spacing: 8 * s) {
                ForEach(Array(Skin.allCases.enumerated()), id: \.element) { i, sk in
                    let owned = model.owned.contains(sk.rawValue)
                    let sprite = GameView.poses(sk).idle[0]
                    Button {
                        shopSel = i
                        model.selectSkin(sk)
                        focused = true
                    } label: {
                        VStack(spacing: 6 * s) {
                            Image(nsImage: sprite)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: sprite.size.width * s,
                                       height: sprite.size.height * s)
                            Text(sk.title)
                                .font(.system(size: 10 * s, weight: .bold, design: .monospaced))
                                .foregroundColor(.vPrimary)
                            Text(model.skin == sk ? "EQUIPPED" : owned ? "OWNED" : "🟡 \(sk.price)")
                                .font(.system(size: 9 * s, weight: .bold, design: .monospaced))
                                .foregroundColor(model.skin == sk ? .cyan
                                                 : owned || model.coins >= sk.price
                                                 ? .vSecondary : .vMuted)
                        }
                        .padding(8 * s)
                        .frame(width: 80 * s, height: 100 * s)
                        .background(RoundedRectangle(cornerRadius: 8 * s).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 8 * s)
                            .stroke(shopSel == i ? Color.yellow
                                    : model.skin == sk ? Color.cyan : Color.vBorder,
                                    lineWidth: shopSel == i ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("←→ SELECT · ⏎ BUY/EQUIP · ⎋ BACK")
                .font(.system(size: 9 * s, weight: .semibold, design: .monospaced))
                .foregroundColor(.vMuted)
        }
        .padding(16 * s)
        .background(RoundedRectangle(cornerRadius: 10 * s).fill(Color.vSurface))
        .overlay(RoundedRectangle(cornerRadius: 10 * s).stroke(Color.vBorder))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pause / settings

    /// ⎋ panel: resume/restart/menu plus the game's settings, stored in
    /// UserDefaults like the rest of the app's prefs. Custom controls instead
    /// of native Toggle/Picker so everything lays out at world scale `s` and
    /// stays vector-crisp (scaleEffect blurred in fullscreen).
    private func pausePanel(_ s: CGFloat) -> some View {
        VStack(spacing: 16 * s) {
            Text("PAUSED")
                .font(.system(size: 15 * s, weight: .bold, design: .monospaced))
                .tracking(4 * s)
                .foregroundColor(.vPrimary)
            VStack(alignment: .leading, spacing: 8 * s) {
                checkRow("Mini-map", "gameMap", s)
                checkRow("Starfield", "gameStars", s)
                checkRow("Sound effects", "gameSound", s)
                Text("⏎/⎋ resume · R restart · M menu\n1/2/3 toggles")
                    .font(.system(size: 9 * s, design: .monospaced))
                    .foregroundColor(.vMuted)
            }
            HStack(spacing: 8 * s) {
                pauseButton("Resume", s) { model.scene = .playing; focused = true }
                pauseButton("Restart", s) { model.reset(); focused = true }
                pauseButton("Menu", s) {
                    model.reset()
                    model.scene = .menu
                    focused = true
                }
            }
        }
        .padding(18 * s)
        .frame(width: 230 * s)
        .background(RoundedRectangle(cornerRadius: 10 * s).fill(Color.vSurface))
        .overlay(RoundedRectangle(cornerRadius: 10 * s).stroke(Color.vBorder))
        .environment(\.colorScheme, .dark)
    }

    private func checkRow(_ label: String, _ key: String, _ s: CGFloat) -> some View {
        Button { flip(key) } label: {
            HStack(spacing: 7 * s) {
                RoundedRectangle(cornerRadius: 4 * s)
                    .fill(Prefs.bool(key, true) ? Color.accentColor
                          : Color.black.opacity(0.35))
                    .frame(width: 15 * s, height: 15 * s)
                    .overlay {
                        if Prefs.bool(key, true) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9 * s, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                Text(label)
                    .font(.system(size: 11 * s))
                    .foregroundColor(.vPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private func pauseButton(_ label: String, _ s: CGFloat,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundColor(.vPrimary)
                .padding(.horizontal, 10 * s)
                .padding(.vertical, 4 * s)
                .background(RoundedRectangle(cornerRadius: 6 * s)
                    .fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func flip(_ key: String) {
        UserDefaults.standard.set(!Prefs.bool(key, true), forKey: key)
    }
}
