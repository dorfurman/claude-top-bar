import SwiftUI

// MARK: - Pieces

/// Progress toward a cap. The fill carries severity; the track is the same hue at low
/// alpha (a lighter step of its own ramp) so state reads across the whole bar.
struct Meter: View {
    let pct: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.vSeverity(pct).opacity(0.22))
                Capsule()
                    .fill(Color.vSeverity(pct))
                    .frame(width: max(height, geo.size.width * min(1, max(0, pct))))
            }
        }
        .frame(height: height)
    }
}

/// Clawd in the card, drawn big from the same pixel data as the badge. Same rhythm as the
/// menu bar: one burst, a short rest, a freshly-rolled stunt for the next burst.
struct BigCrab: View {
    static let cycle = Clawd.frames + 12 * 2
    /// 3pt per cell: 102 x 69pt.
    var scale: CGFloat = 3
    @State private var tick = 0
    @State private var stunt = Stunt.classic
    private let timer = Timer.publish(every: 1.0 / 12, on: .main, in: .common).autoconnect()

    var body: some View {
        let f = tick % Self.cycle
        Image(nsImage: frameImage(f < Clawd.frames ? f : 0))
            .onReceive(timer) { _ in
                guard Prefs.bool("animate", true) else { return }
                tick += 1
                if tick % Self.cycle == 0 { stunt = Stunt.enabled.randomElement() ?? .classic }
            }
    }

    private func frameImage(_ f: Int) -> NSImage {
        NSImage(size: NSSize(width: CGFloat(Clawd.cellsWide) * scale,
                             height: CGFloat(Clawd.cellsHigh) * scale),
                flipped: false) { _ in
            if let a = stunt.anim { drawAnim(a, frame: f, at: .zero, scale: scale) }
            else { drawClawd(frame: f, at: .zero, scale: scale) }
            return true
        }
    }
}

/// The "Claude finished" banner, shown in a borderless panel hanging off the menu bar item
/// (see Bar.showToast). Same surface and hairline as the card, so it reads as the same app.
struct ToastView: View {
    let title: String
    let message: String
    /// Tapping the banner routes back to the chat's terminal tab; the ✗ just dismisses.
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Color(P.good)).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.vPrimary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.vSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.vMuted)
                    .padding(4)          // a 16pt hit area for an 8pt glyph
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 240, alignment: .leading)
        .contentShape(Rectangle())       // the gaps are clickable too, not just the text
        .onTapGesture(perform: onOpen)
        .background(Color.vSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.vBorder, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Card

struct UsageCard: View {
    let snap: Snapshot
    /// nil until claude.ai has answered once. Everything limit-related is gated on it —
    /// the card shows "no data" rather than a locally-derived guess.
    let usage: Usage?
    let error: UsageError?
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onGame: () -> Void = {}
    var onChat: (String?) -> Void = { _ in }
    /// id of the chat row under the cursor — the only reason this view has state
    @State private var hovered: String?

    // Signed out, everything limit-related reads as absent — cached figures from the
    // previous login are stale, and the card's job is to say "sign in", not guess.
    private var five: Window? { Auth.isSignedIn ? usage?.fiveHour : nil }

    var body: some View {
        // one 14pt rhythm; hairlines land centered in it, so every section breathes evenly
        VStack(alignment: .leading, spacing: 14) {
            header
            hero
            if !Auth.isSignedIn {
                SignInBox(onDone: onRefresh)
            } else if let e = error, usage == nil {
                problem(e)
            }
            if !otherWindows.isEmpty {
                divider
                others
            }
            if !snap.live.isEmpty {
                divider
                chats
            }
            divider
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(Color.vSurface)
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(Color.vBorder).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("5-HOUR SESSION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.vMuted)
            Spacer()
            if let r = five?.resetsAt {
                Text("resets \(clockTime(r))")
                    .font(.system(size: 11))
                    .foregroundColor(.vMuted)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            // crab bottom-aligned with the subtext so he stands on the meter's edge,
            // not floating beside the number
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // hero figure: proportional figures, one per view; "%" demoted so
                    // the value carries the weight
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(five.map { "\(Int($0.utilization.rounded()))" } ?? "—")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundColor(five == nil ? .vMuted : .vPrimary)
                        if five != nil {
                            Text("%")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.vSecondary)
                        }
                    }
                    Text(five.map {
                        "\(pct(100 - $0.utilization)) left\($0.resetsAt.map { " · \(shortDuration($0.timeIntervalSinceNow)) to reset" } ?? "")"
                    } ?? "No usage figures from claude.ai yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.vSecondary)
                }
                Spacer(minLength: 0)
                BigCrab()
            }
            if let w = five {
                Meter(pct: w.fraction)
                pace(w)
            }
        }
    }

    /// Projection, not measurement — always phrased as such, and only shown once the block
    /// has enough shape for the rate to mean anything.
    @ViewBuilder private func pace(_ w: Window) -> some View {
        if snap.elapsedBuckets >= 2 {
            if let secs = snap.secondsToCap(utilization: w.utilization) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("At this rate you run out in \(shortDuration(secs))")
                        .font(.system(size: 10))
                }
                .foregroundColor(Color(P.serious))
            } else if snap.burnPerHour > 0 {
                Text("At this rate, ~\(pct(snap.projected(utilization: w.utilization))) by reset")
                    .font(.system(size: 10))
                    .foregroundColor(.vMuted)
            }
        }
    }

    /// Sign-in flow, inline in the card: open the browser, paste back the code claude.ai
    /// shows. Lives in the long-lived hosting controller, so its @State (and the pending
    /// PKCE verifier in Auth) survives the popover closing while the user is in the browser.
    private struct SignInBox: View {
        var onDone: () -> Void
        @State private var code = ""
        @State private var opened = false
        @State private var busy = false
        @State private var failed = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in with your Claude account to see live usage.")
                    .font(.system(size: 11))
                    .foregroundColor(.vSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(opened ? "Reopen claude.ai…" : "Sign in with Claude…") {
                    NSWorkspace.shared.open(Auth.signInURL())
                    opened = true
                    code = ""
                }
                if opened {
                    Text("Approve in the browser, then paste the code it shows:")
                        .font(.system(size: 10))
                        .foregroundColor(.vMuted)
                    HStack(spacing: 6) {
                        TextField("code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button(busy ? "…" : "Connect") {
                            busy = true
                            failed = false
                            Auth.exchange(code) { ok in
                                busy = false
                                failed = !ok
                                if ok { onDone() }
                            }
                        }
                        .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if failed {
                        Text("That code didn't work — reopen claude.ai and try again.")
                            .font(.system(size: 10))
                            .foregroundColor(Color(P.warning))
                    }
                }
            }
        }
    }

    private func problem(_ e: UsageError) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
            Text(e.description).font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Color(P.warning))
    }

    // MARK: Other windows

    private var otherWindows: [(String, Window)] {
        guard Auth.isSignedIn, let u = usage else { return [] }
        var rows = u.sevenDay.map { [("Weekly · all models", $0)] } ?? []
        rows += u.models.map { ("Weekly · \($0.name)", $0.window) }
        return rows
    }

    private var others: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(otherWindows, id: \.0) { name, w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundColor(.vSecondary)
                        Spacer()
                        if let r = w.resetsAt {
                            Text(dayTime(r))
                                .font(.system(size: 10))
                                .foregroundColor(.vMuted)
                                .monospacedDigit()
                        }
                        Text(pct(w.utilization))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.vPrimary)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    Meter(pct: w.fraction, height: 5)
                }
            }
        }
    }

    // MARK: Chats

    /// Sessions active in the last 30 minutes, working ones first. The state is read from
    /// each transcript's tail (see Sessions.swift), refreshed on the same 15 s cadence as
    /// the block scan — plus on popover open, like everything else.
    private var chats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHATS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.vMuted)
            ForEach(snap.live.prefix(5)) { s in
                HStack(spacing: 8) {
                    Circle()
                        .fill(s.working ? Color(P.good) : Color.vBaseline)
                        .frame(width: 6, height: 6)
                    Text(s.title)
                        .font(.system(size: 11))
                        .foregroundColor(.vPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(s.working ? "working" : "idle \(shortDuration(-s.modified.timeIntervalSinceNow))")
                        .font(.system(size: 10))
                        .foregroundColor(s.working ? Color(P.good) : .vMuted)
                        .monospacedDigit()
                }
                // the row is a link back to its terminal; padding gives the hover fill
                // somewhere to live and widens the target past the text itself
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovered == s.id ? Color.vGridline : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
                .onTapGesture { onChat(s.cwd) }
                .help("\(s.project) · \(s.title) — click to open in your terminal")
            }
            if snap.live.count > 5 {
                Text("+ \(snap.live.count - 5) more")
                    .font(.system(size: 10))
                    .foregroundColor(.vMuted)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(snap.requests) requests · \(snap.sessions) sessions · \(compact(snap.output)) out")
                    .font(.system(size: 10))
                    .foregroundColor(.vMuted)
                Text(source)
                    .font(.system(size: 10))
                    .foregroundColor(.vMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let u = Updates.available {
                    Button(action: u.open) {
                        Text("Update available — v\(u.version) ↗")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.vPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the release page. You're on v\(Updates.current).")
                }
            }
            HStack(spacing: 4) {
                iconButton("arrow.clockwise", "Refresh", action: onRefresh)
                iconButton("gearshape", "Settings", action: onSettings)
                iconButton("gamecontroller", "Crab Invaders — Clawd vs the humans", action: onGame)
                Spacer()
                iconButton("power", "Quit CrabBar", action: onQuit)
            }
        }
    }

    private func iconButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.vSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// Provenance line — the whole point of the app is that these numbers aren't guesses,
    /// so it says where they came from and how stale they are.
    private var source: String {
        guard let u = usage else { return "Percentages come live from claude.ai." }
        let secs = -u.fetchedAt.timeIntervalSinceNow
        let age = secs < 60 ? "just now" : "\(shortDuration(secs)) ago"
        let stale = error.map { " · last check failed: \($0.description)" } ?? ""
        return "Live from claude.ai · updated \(age)\(stale)."
    }
}

// MARK: - Settings

struct SettingsCard: View {
    let status: String
    @State private var notify = Prefs.bool("notify", true)
    @State private var notifyDone = Prefs.bool("notifyDone", true)
    @State private var login = Prefs.bool("login", false)
    var onLoginChange: (Bool) -> Void = { _ in }

    var body: some View {
        Form {
            Section("Data source") {
                Text(status).font(.system(size: 11))
                Text("Usage percentages come live from claude.ai for the Claude account "
                     + "you signed in with — the same figures /usage shows. Nothing is estimated.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                if Auth.isSignedIn {
                    Button("Sign out") {
                        Auth.signOut()
                        Usage.clearCache()
                    }
                }
            }
            Section {
                Toggle("Notify at 90%", isOn: $notify)
                    .onChange(of: notify) { _, v in UserDefaults.standard.set(v, forKey: "notify") }
                Toggle("Notify when Claude finishes working", isOn: $notifyDone)
                    .onChange(of: notifyDone) { _, v in UserDefaults.standard.set(v, forKey: "notifyDone") }
                Toggle("Launch at login", isOn: $login)
                    .onChange(of: login) { _, v in
                        UserDefaults.standard.set(v, forKey: "login")
                        onLoginChange(v)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 320)
    }
}
