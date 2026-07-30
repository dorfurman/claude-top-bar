import AppKit
import SwiftUI

// MARK: - Palette
//
// Dark steps from the validated reference palette. The popover commits to the dark
// surface in both system appearances so it reads as one object with the menu bar pill,
// and so every contrast/CVD result below holds unconditionally.
//
// Validated for this exact set (validate_palette.js, --mode dark, surface #1a1a19):
// lightness band PASS · chroma floor PASS · adjacent CVD worst ΔE 8.4 PASS ·
// normal-vision worst ΔE 19.8 PASS · contrast >= 3:1 PASS.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum P {
    static let surface = NSColor(hex: 0x1A1A19)
    static let plane = NSColor(hex: 0x0D0D0D)
    static let primary = NSColor(hex: 0xFFFFFF)
    static let secondary = NSColor(hex: 0xC3C2B7)
    static let muted = NSColor(hex: 0x898781)
    static let gridline = NSColor(hex: 0x2C2C2A)
    static let baseline = NSColor(hex: 0x383835)
    static let border = NSColor(hex: 0xFFFFFF, alpha: 0.10)

    static let good = NSColor(hex: 0x0CA30C)
    static let warning = NSColor(hex: 0xFAB219)
    static let serious = NSColor(hex: 0xEC835A)
    static let critical = NSColor(hex: 0xD03B3B)

    /// Categorical slots in fixed order — never cycled, never reordered per-render.
    static let series: [NSColor] = [
        NSColor(hex: 0x3987E5), NSColor(hex: 0xD95926), NSColor(hex: 0x199E70),
        NSColor(hex: 0xC98500), NSColor(hex: 0xD55181), NSColor(hex: 0x008300),
        NSColor(hex: 0x9085E9), NSColor(hex: 0xE66767),
    ]

    /// Status ramp for a fill that carries severity.
    static func severity(_ pct: Double) -> NSColor {
        if pct < 0.50 { return good }
        if pct < 0.75 { return warning }
        if pct < 0.90 { return serious }
        return critical
    }
}

// SwiftUI mirrors
extension Color {
    static let vSurface = Color(P.surface)
    static let vPlane = Color(P.plane)
    static let vPrimary = Color(P.primary)
    static let vSecondary = Color(P.secondary)
    static let vMuted = Color(P.muted)
    static let vGridline = Color(P.gridline)
    static let vBaseline = Color(P.baseline)
    static let vBorder = Color(P.border)
    static func vSeries(_ i: Int) -> Color { Color(P.series[i % P.series.count]) }
    static func vSeverity(_ p: Double) -> Color { Color(P.severity(p)) }
}

// MARK: - Menu bar badge

enum BadgeMode: Int, CaseIterable {
    case percentAndTime = 0, percent = 1, week = 2, iconOnly = 3

    var label: String {
        switch self {
        case .percentAndTime: return "5-hour % + time left"
        case .percent: return "5-hour % only"
        case .week: return "Weekly %"
        case .iconOnly: return "Crab only"
        }
    }
}

/// Tricks Clawd can play a burst with. `classic` is the original baked Lottie; the rest
/// are new pixel animations composed from its parts (tools/make_anims.py), all the same
/// 43-frame length so the badge timing never changes.
enum Stunt: Int, CaseIterable {
    case classic    // the original: blink, pull out the laptop, type
    case scuttle    // dashes sideways and back, kicking up dust
    case bubbles    // blows bubbles that drift up and pop
    case snooze     // nods off, Zs float away, wakes up
    case rave       // claws up, alternating, sparkles
    case jump       // crouch, leap, hang time, land

    var label: String {
        switch self {
        case .classic: return "Classic (laptop)"
        case .scuttle: return "Scuttle"
        case .bubbles: return "Bubbles"
        case .snooze: return "Snooze"
        case .rave: return "Rave claws"
        case .jump: return "Jump"
        }
    }

    var anim: ClawdAnims.Anim? {
        switch self {
        case .classic: return nil
        case .scuttle: return ClawdAnims.scuttle
        case .bubbles: return ClawdAnims.bubbles
        case .snooze: return ClawdAnims.snooze
        case .rave: return ClawdAnims.rave
        case .jump: return ClawdAnims.jump
        }
    }

    /// User-enabled set, stored as a bitmask ("stunts", all on by default).
    static var enabled: [Stunt] {
        let mask = Prefs.int("stunts", -1)
        return allCases.filter { mask & (1 << $0.rawValue) != 0 }
    }
}

/// One cycle of Clawd's animation, pre-rendered. Frame 0 is the crab at rest.
///
/// The frames only depend on the text, which changes at most once a minute, so the cycle is
/// rendered once and then replayed rather than redrawn per frame.
enum BadgeFrames {
    static let count = Clawd.frames
    private static var key = ""
    private static var frames: [NSImage] = []

    static func at(_ usage: Usage?, mode: BadgeMode, index: Int, stunt: Stunt = .classic) -> NSImage {
        let w = mode == .week ? usage?.sevenDay : usage?.fiveHour
        let mins = w?.resetsAt.map { Int(max(0, $0.timeIntervalSinceNow) / 60) }
        let k = "\(mode.rawValue)|\(w?.utilization ?? -1)|\(mins ?? -1)|\(stunt.rawValue)|\(Auth.isSignedIn)"
        if k != key || frames.count != count {
            key = k
            frames = (0..<count).map { flattened(badgeImage(usage, mode: mode, frame: $0, stunt: stunt)) }
        }
        return frames[((index % count) + count) % count]
    }
}

/// A block-backed NSImage re-runs its drawing block on every single display pass, so a
/// pre-rendered frame isn't pre-rendered until it's been baked into a bitmap.
private func flattened(_ src: NSImage) -> NSImage {
    let out = NSImage(size: src.size)
    out.lockFocus()
    src.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    out.isTemplate = false
    return out
}

private func run(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight,
                 _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ])
}

/// "04:18" — hours:minutes until reset.
private func durationAttr(_ secs: TimeInterval) -> NSAttributedString {
    let m = max(0, Int(secs / 60))
    return run(String(format: "%02d:%02d", m / 60, m % 60), 11.5, .medium, P.secondary)
}

/// The status item's image: a dark pill with Clawd, a value, and a severity meter.
/// Drawn rather than set as a title because a status item title cannot carry a background.
///
/// Every field is drawn into a slot wide enough for its widest value ("100%", "0h00m"), so
/// the pill keeps one width and the menu bar stops shuffling every time a digit drops.
///
/// `usage` is nil until the first successful call to claude.ai. There is deliberately no
/// local fallback figure — a guessed percentage next to a real one is worse than "—".
///
/// `frame` indexes Clawd's animation cycle, 0..<Clawd.frames. `stunt` picks which trick
/// the cycle is drawn as.
func badgeImage(_ usage: Usage?, mode: BadgeMode, frame: Int = 0, stunt: Stunt = .classic) -> NSImage {
    let window = mode == .week ? usage?.sevenDay : usage?.fiveHour
    let frac = window?.fraction ?? 0
    let h = NSStatusBar.system.thickness - 4
    let pad: CGFloat = 7, gap: CGFloat = 6, barW: CGFloat = 48

    // 0.75pt per cell: 25.5 x 17.25pt, filling most of the pill height. Art pixels land on
    // 1.5 Retina pixels so edges are a touch softer than the old 0.5 — acceptable at this size.
    let cellPt: CGFloat = 0.75
    let crabSlot = CGFloat(Clawd.cellsWide) * cellPt

    // (text, slot width, right-aligned) — slot is the widest the field can ever get. The
    // percentage is right-aligned so its "%" never moves as the value goes 4 → 40 → 100;
    // the slack lands next to the crab, where nothing is trying to be read.
    // Layout order: crab, percentage, bar, time left.
    var fields: [(NSAttributedString, CGFloat, Bool)] = []
    // Signed out: just the crab and the label, whatever the mode and whatever figures are
    // cached — a stale percentage next to a dead login reads as live data.
    let needsAuth = !Auth.isSignedIn
    if needsAuth {
        let v = run("not signed in", 11.5, .medium, P.warning)
        fields.append((v, v.size().width, true))
    } else if mode != .iconOnly {
        let v = run(window.map { pct($0.utilization) } ?? "—", 11.5, .medium, P.secondary)
        // slot hugs the actual text — the pill resizes when a digit is gained, but there's
        // no blank slack sitting between the crab and the value the rest of the time
        fields.append((v, v.size().width, true))
    }
    let showBar = mode != .iconOnly && window != nil && !needsAuth

    var timeField: (NSAttributedString, CGFloat, Bool)?
    if !needsAuth, mode == .percentAndTime, let reset = window?.resetsAt, reset > Date() {
        let t = durationAttr(reset.timeIntervalSinceNow)
        timeField = (t, max(t.size().width, durationAttr(4 * 3600).size().width), false)
    }

    var w = pad + crabSlot
    for f in fields { w += gap + f.1 }
    // One baseline for every field.
    let ref = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    let baseline = (h - (ref.ascender - ref.descender)) / 2 - ref.descender
    if showBar { w += gap + barW }
    if let t = timeField { w += gap + t.1 }
    w += pad

    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1),
                                xRadius: (h - 1) / 2, yRadius: (h - 1) / 2)
        P.surface.withAlphaComponent(0.95).setFill()
        body.fill()
        P.border.setStroke()   // hairline so the pill has an edge on a light menu bar too
        body.stroke()

        // Snapped to a whole point so the art pixels stay on the Retina grid.
        let crabOrigin = NSPoint(x: pad,
                                 y: (h - CGFloat(Clawd.cellsHigh) * cellPt).rounded() / 2)
        if let a = stunt.anim {
            drawAnim(a, frame: frame, at: crabOrigin, scale: cellPt)
        } else {
            drawClawd(frame: frame, at: crabOrigin, scale: cellPt)
        }

        var x = pad + crabSlot
        func drawField(_ text: NSAttributedString, _ slot: CGFloat, _ rightAligned: Bool) {
            x += gap
            // draw(at:) takes the bounding box origin, so back off by the deepest descender
            // in the string to land it on the shared baseline
            var descender: CGFloat = 0
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { v, _, _ in
                if let f = v as? NSFont { descender = min(descender, f.descender) }
            }
            text.draw(at: NSPoint(x: rightAligned ? x + slot - text.size().width : x,
                                  y: baseline + descender))
            x += slot
        }
        for (text, slot, rightAligned) in fields { drawField(text, slot, rightAligned) }

        if showBar {
            x += gap
            let track = NSRect(x: x, y: h / 2 - 3.5, width: barW, height: 7)
            P.severity(frac).withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            P.severity(frac).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                             width: max(7, barW * frac), height: 7),
                         xRadius: 3.5, yRadius: 3.5).fill()
            x += barW
        }

        if let (text, slot, rightAligned) = timeField { drawField(text, slot, rightAligned) }
        return true
    }
    img.isTemplate = false   // keep the pill dark in both system appearances
    return img
}
