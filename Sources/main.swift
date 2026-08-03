import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// CRABBAR_ROOT overrides the transcript root — used to stage README screenshots
// from fabricated sessions instead of real (private) chat titles.
let CLAUDE_ROOT = ProcessInfo.processInfo.environment["CRABBAR_ROOT"]
    .map(URL.init(fileURLWithPath:))
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

/// A borderless window is not key-eligible by default, and its buttons then ignore clicks.
final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Per-banner, so one stacked toast timing out doesn't cut another's time short.
    var dismiss: Timer?
}

final class Bar: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    /// Kept for the lifetime of the app: see showCard().
    var host: NSHostingController<UsageCard>?
    var settingsWindow: NSWindow?
    var gameWindow: NSWindow?
    /// Live banners, top-down in stacking order, plus the corner they hang from.
    var toasts: [ToastPanel] = []
    var toastX: CGFloat = 0
    var toastTop: CGFloat = 0
    var snap = Snapshot()
    var usage: Usage?
    var usageError: UsageError?
    var weekDaily: [DayBar] = []
    var blockTimer: Timer?
    var weekTimer: Timer?
    var animTimer: Timer?
    var tick = 0
    /// The trick the current burst plays. Re-rolled as each burst starts; classic half the
    /// time so the stunts stay a surprise instead of a circus.
    var stunt = Stunt.classic

    /// The endpoint 429s hard and the 429 is sticky, so this is deliberately unhurried and
    /// doubles on refusal. Polling is piggybacked on the 15s block timer rather than
    /// running its own.
    var fetching = false
    var nextFetchAt = Date.distantPast
    var apiInterval: TimeInterval = 120
    /// .transient alone only closes once our app has been made active by a click inside,
    /// so watch for clicks delivered to other apps too.
    var outsideClick: Any?

    var mode: BadgeMode { BadgeMode(rawValue: Prefs.int("badgeMode", 0)) ?? .percentAndTime }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // An accessory app has no menu bar, and ⌘V/⌘C/⌘X only work by routing through
        // an Edit menu — without this, paste is dead in every text field we show.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        // The game window shows in the Dock like a real app; ⌘Q there should
        // close the game, not kill the menu-bar app. ⌘W closes the key window.
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        file.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        let main = NSMenu()
        main.addItem(fileItem)
        main.addItem(editItem)
        NSApp.mainMenu = main

        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.delegate = self

        askForNotifications()

        // Draw once, immediately, from the last known figures — the async work below
        // otherwise leaves the item blank and then resizes it twice.
        usage = Usage.cached
        render()

        // 5-hour block: ~24 files / 15 MB / ~0.4s, cheap enough to poll.
        refreshBlock()
        fetchUsageIfStale(olderThan: 0)
        blockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshBlock()
            self?.fetchUsageIfStale()
        }
        // 7-day total: ~94 files / 58 MB, so it runs on a slow cadence instead.
        refreshWeek()
        weekTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshWeek()
            self?.checkForUpdates()   // no-op unless the 6h throttle has lapsed
        }
        checkForUpdates()

        syncAnimation()

        // CRABBAR_TOAST=1: fire one banner at launch, to check the drawing and placement
        // without waiting on a real session to finish.
        // CRABBAR_TOAST=n fires n of them, a beat apart, to check the stack.
        if let n = ProcessInfo.processInfo.environment["CRABBAR_TOAST"].map({ Int($0) ?? 1 }) {
            let cwd = FileManager.default.currentDirectoryPath
            for i in 0..<max(1, n) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.7) { [weak self] in
                    self?.showToast("Claude finished · \(URL(fileURLWithPath: cwd).lastPathComponent)",
                                    "toast placement check \(i + 1)", cwd: cwd)
                }
            }
        }

        // Settings writes straight to UserDefaults; this is what makes a changed badge mode
        // or animation toggle land now instead of on the next 15s tick.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.syncAnimation()
                self?.render()
            }
    }

    /// Bursts, not perpetual motion. Handing the status item a new image is the expensive
    /// part — a steady 12fps costs ~7% of a core, all day, for a wiggle — so Clawd plays his
    /// loop once and then sits still until the next one. He runs continuously only while a
    /// fetch is in flight, which is the only "working on it" signal the pill has room for.
    func syncAnimation() {
        let on = Prefs.bool("animate", true)
        if on, animTimer == nil {
            let t = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.tick += 1
                if self.tick % Self.restCycle == 0 {
                    // Uniform over whatever is enabled; classic is just one of the crowd.
                    self.stunt = Stunt.enabled.randomElement() ?? .classic
                }
                // one frame past the burst still redraws, to park the crab back at rest
                if self.fetching || self.tick % Self.restCycle <= BadgeFrames.count {
                    self.render()
                }
            }
            // .common: keep scuttling while a menu or the popover is tracking events
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        } else if !on, animTimer != nil {
            animTimer?.invalidate()
            animTimer = nil
            tick = 0
            render()
        }
    }

    // MARK: Scanning

    @objc func refreshBlock() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 10h of history: the active block may have opened 5h ago, and deciding
            // whether that message opened a block needs the 5h before it.
            let entries = scan(root: CLAUDE_ROOT, since: Date().addingTimeInterval(-2 * FIVE_HOURS))
            var s = summarize(all: entries, anchor: Anchor.start)
            s.live = liveSessions(root: CLAUDE_ROOT)
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    /// Pulls the real percentages from claude.ai. `olderThan` lets an explicit refresh (or
    /// opening the popover) jump the queue without letting a click storm hammer the endpoint.
    func fetchUsageIfStale(olderThan: TimeInterval? = nil) {
        let due = olderThan.map { (usage?.fetchedAt ?? .distantPast) < Date().addingTimeInterval(-$0) }
            ?? (Date() >= nextFetchAt)
        guard due, !fetching else { return }
        fetching = true
        nextFetchAt = Date().addingTimeInterval(apiInterval)
        fetchUsage { [weak self] r in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fetching = false
                switch r {
                case .success(let u):
                    self.usage = u
                    self.usageError = nil
                    u.cache()
                    self.apiInterval = 120
                case .failure(let e):
                    self.usageError = e
                    if case .rateLimited = e { self.apiInterval = min(1800, self.apiInterval * 2) }
                }
                self.nextFetchAt = Date().addingTimeInterval(self.apiInterval)
                self.maybeNotify()
                self.render()
                if self.popover.isShown { self.showCard() }
            }
        }
    }

    /// Also recomputes the authoritative block anchor: only a full-history walk can find
    /// the last >= 5h gap the tiling is anchored to.
    func refreshWeek() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let entries = scan(root: CLAUDE_ROOT, since: Date().addingTimeInterval(-WEEK))
            let anchor = activeBlock(entries, now: Date())?.start
            let daily = dailySpend(entries)
            DispatchQueue.main.async {
                self?.weekDaily = daily
                Anchor.start = anchor
                self?.refreshBlock()
            }
        }
    }

    var wasWorking = false
    /// Sessions seen working on the previous scan, for the working→done edge.
    var workingIds: Set<String> = []

    func apply(_ s: Snapshot) {
        snap = s
        snap.daily = weekDaily
        notifyFinished(s.live)
        // idle→working edge only, so closing the game mid-streak isn't overridden
        // until Claude actually goes quiet and starts working again
        let working = s.live.contains(where: \.working)
        if working, !wasWorking, Prefs.bool("autoGame", false), gameWindow?.isVisible != true {
            openGame()
        }
        wasWorking = working
        render()
        if popover.isShown { showCard() }
    }

    /// Clawd's 43 frames at their native 12fps (3.6s), then a 2s rest, forever.
    static let restCycle = BadgeFrames.count + 12 * 2

    func render() {
        let f = fetching ? tick % BadgeFrames.count : tick % Self.restCycle
        let inBurst = f < BadgeFrames.count
        // Parked and fetching both stay classic: rest is a neutral pose, and the fetch
        // loop is the pill's "working on it" signal, not showtime.
        item.button?.image = BadgeFrames.at(usage, mode: mode,
                                            index: inBurst ? f : 0,
                                            stunt: inBurst && !fetching ? stunt : .classic)
    }

    // MARK: Interaction

    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            // opening the card is an explicit "tell me now" — but not more than every 20s
            fetchUsageIfStale(olderThan: 20)
            showCard()
            if let b = item.button {
                popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
                outsideClick = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                        self?.popover.performClose(nil)
                    }
            }
        }
    }

    func popoverDidClose(_ n: Notification) {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }

    func showCard() {
        let card = UsageCard(
            snap: snap,
            usage: usage,
            error: usageError,
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) },
            onRefresh: { [weak self] in
                self?.refreshBlock()
                self?.refreshWeek()
                self?.fetchUsageIfStale(olderThan: 5)
            },
            onGame: { [weak self] in self?.openGame() },
            onChat: { [weak self] cwd in
                self?.popover.performClose(nil)
                DispatchQueue.global(qos: .userInitiated).async { focusSession(cwd: cwd) }
            })
        // Reuse the hosting controller and hand it a new rootView: SwiftUI diffs the card in
        // place. Assigning a fresh controller to popover.contentViewController instead tears
        // the card down and rebuilds it, which flickers every time a refresh lands while the
        // card is open — and one always does, ~a second after opening it.
        let vc: NSHostingController<UsageCard>
        if let h = host {
            h.rootView = card
            vc = h
        } else {
            vc = NSHostingController(rootView: card)
            host = vc
            popover.contentViewController = vc
        }
        // must be set before show(): the popover places itself from contentSize, and if it
        // grows afterwards it grows upward, off the top of the screen. Only on a real change,
        // so a routine refresh doesn't re-lay-out an open popover for nothing.
        vc.view.layoutSubtreeIfNeeded()
        let size = vc.view.fittingSize
        if popover.contentSize != size { popover.contentSize = size }
    }

    func showMenu() {
        let m = NSMenu()
        if let u = Updates.available {
            m.addItem(withTitle: "⬆ Install v\(u.version) & restart", action: #selector(openUpdate), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Refresh Now", action: #selector(refreshBlock), keyEquivalent: "r").target = self
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "CrabBar v\(Updates.current)", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Quit CrabBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil   // restore left-click-to-popover
    }

    /// ⌘Q with the game up closes just the game; otherwise it quits CrabBar.
    @objc func quit() {
        if gameWindow?.isVisible == true { gameWindow?.close() } else { NSApp.terminate(nil) }
    }

    @objc func openGame() {
        popover.performClose(nil)
        // rebuilt each time, like settings — a closed game is over, not paused
        gameWindow?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: GameView()))
        w.title = "Crab Invaders"
        w.styleMask = [.titled, .closable, .resizable]
        w.collectionBehavior = [.fullScreenPrimary]
        w.setContentSize(NSSize(width: GameModel.W * 1.35, height: GameModel.H * 1.35))
        w.isReleasedWhenClosed = false
        gameWindow = w
        w.center()
        // show in the Dock / ⌘tab like a real app while the game is up
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        popover.performClose(nil)
        // rebuilt each time so the calibration fields see the current session cost
        settingsWindow?.close()
        let view = SettingsCard(
            status: usageError.map { "⚠︎ \($0.description)" }
                ?? (usage == nil ? "Contacting claude.ai…" : "Connected to claude.ai."),
            onLoginChange: { [weak self] on in self?.setLoginItem(on) })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "CrabBar Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        settingsWindow = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Login item

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Unsigned / relocated bundles can be refused by launchd — say so rather
            // than leaving a toggle that silently lies.
            let a = NSAlert()
            a.messageText = "Couldn't change the login item"
            a.informativeText = "\(error.localizedDescription)\n\nMove CrabBar.app to /Applications and try again."
            a.runModal()
            UserDefaults.standard.set(!on, forKey: "login")
        }
    }

    // MARK: Updates

    /// Notifies once per new version; the menu item and popover link come straight
    /// from Updates.available, so they need no bookkeeping here.
    func checkForUpdates() {
        Updates.check { u in
            let c = UNMutableNotificationContent()
            c.title = "CrabBar \(u.version) is available"
            c.body = "You're on \(Updates.current) · right-click the pill to install it."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "crab-update-\(u.version)", content: c, trigger: nil))
        }
    }

    /// Downloads and installs in place; the app relaunches itself when it lands.
    @objc func openUpdate() {
        guard let u = Updates.available else { return }
        Updates.install(u)
    }

    // MARK: Notifications

    func askForNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// One notification per session when the agent stops working. The transcript must have
    /// been written within WORKING_TTL — a session demoted for going silent (Esc, crashed
    /// CLI) didn't finish anything, so it shouldn't announce that it did.
    func notifyFinished(_ live: [LiveSession]) {
        let now = Set(live.filter(\.working).map(\.id))
        defer { workingIds = now }
        guard Prefs.bool("notifyDone", true) else { return }
        for s in live where workingIds.contains(s.id) && !now.contains(s.id)
            && Date().timeIntervalSince(s.modified) < WORKING_TTL {
            showToast("Claude finished · \(s.project)", s.title, cwd: s.cwd)
        }
    }

    /// A banner under the pill instead of a Notification Center alert: no permission prompt,
    /// no Do-Not-Disturb, and it points at the thing it's talking about. Several chats can
    /// finish in the same 15s scan, so banners stack downward, newest at the bottom, each on
    /// its own dismiss timer; the survivors slide up as one goes away.
    func showToast(_ title: String, _ message: String, cwd: String? = nil) {
        guard let button = item.button, let bar = button.window else { return }
        let p = ToastPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ToastView(
            title: title, message: message,
            onOpen: { [weak self] in
                self?.hideToast(p)
                // lsof / ps / AppleScript: off the main thread, the click shouldn't wait
                DispatchQueue.global(qos: .userInitiated).async { focusSession(cwd: cwd) }
            },
            onClose: { [weak self] in self?.hideToast(p) }))
        host.layout()
        let size = host.fittingSize
        let anchor = bar.convertToScreen(button.convert(button.bounds, to: nil))
        // right-align under the pill, but never off the right edge of the screen
        let limit = (button.window?.screen ?? NSScreen.main)?.visibleFrame.maxX ?? anchor.maxX
        toastX = min(anchor.maxX, limit) - size.width
        toastTop = anchor.minY - 6

        p.contentView = host
        p.setFrame(NSRect(x: toastX, y: toastTop - size.height, width: size.width, height: size.height),
                   display: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.alphaValue = 0

        toasts.append(p)
        // A quiet hour of finished chats shouldn't wall off the screen; the oldest goes.
        while toasts.count > 4, let old = toasts.first { hideToast(old) }
        stackToasts()
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }

        // .common so the countdown keeps running while a menu or the popover tracks events
        let t = Timer(timeInterval: 6, repeats: false) { [weak self] _ in self?.hideToast(p) }
        RunLoop.main.add(t, forMode: .common)
        p.dismiss = t
    }

    /// Lays the live banners out top-down from under the pill. Animated, so a dismissal in
    /// the middle of the stack closes its gap instead of leaving a hole.
    private func stackToasts() {
        var y = toastTop
        for p in toasts {
            y -= p.frame.height
            let f = NSRect(x: toastX, y: y, width: p.frame.width, height: p.frame.height)
            if p.frame != f { p.animator().setFrame(f, display: true) }
            y -= 6
        }
    }

    func hideToast(_ p: ToastPanel) {
        p.dismiss?.invalidate()
        p.dismiss = nil
        guard let i = toasts.firstIndex(of: p) else { return }   // already going away
        toasts.remove(at: i)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2
                                              p.animator().alphaValue = 0 }) { p.close() }
        stackToasts()
    }

    /// Fires once per threshold per window; the crossed set resets when the window rolls.
    /// Keyed on the reset time reported by claude.ai, so it tracks the real window rather
    /// than a locally-inferred one.
    func maybeNotify() {
        guard Prefs.bool("notify", true), let w = usage?.fiveHour, let reset = w.resetsAt
        else { return }
        let d = UserDefaults.standard
        let tag = isoString(reset)
        if d.string(forKey: "notifyBlock") != tag {
            d.set(tag, forKey: "notifyBlock")
            d.set(0, forKey: "notifyHighest")
        }
        let highest = d.integer(forKey: "notifyHighest")
        guard let crossed = [90].first(where: { Int(w.utilization) >= $0 && $0 > highest })
        else { return }
        d.set(crossed, forKey: "notifyHighest")

        let c = UNMutableNotificationContent()
        c.title = "\(crossed)% of your 5-hour limit"
        c.body = "\(pct(100 - w.utilization)) left · resets \(clockTime(reset))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "crab-\(tag)-\(crossed)", content: c, trigger: nil))
    }
}

// MARK: - Offscreen render (design check without screen-recording permission)

@MainActor func renderCard(to path: String) {
    let entries = scan(root: CLAUDE_ROOT, since: Date().addingTimeInterval(-WEEK))
    var snap = summarize(all: entries)
    snap.daily = dailySpend(entries)
    snap.live = liveSessions(root: CLAUDE_ROOT)

    // blocking fetch: this path is a one-shot design check, not the running app
    var live: Usage?
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { if case .success(let u) = $0 { live = u }; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)

    let renderer = ImageRenderer(
        content: UsageCard(snap: snap, usage: live, error: nil).frame(width: 300))
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { print("render failed"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(Int(img.size.width))x\(Int(img.size.height)) pt)")
}

/// The badge across one animation cycle, on a menu-bar-ish strip — same reason renderCard
/// exists: check the drawing without a screen recording.
@MainActor func renderBadgeStrip(to path: String) {
    var live: Usage?
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { if case .success(let u) = $0 { live = u }; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)

    let n = BadgeFrames.count
    // One column per stunt, frames running down each column.
    let cols = Stunt.allCases.map { s in
        (0..<n).map { badgeImage(live, mode: .percentAndTime, frame: $0, stunt: s) }
    }
    let cell = NSSize(width: cols[0][0].size.width + 16, height: NSStatusBar.system.thickness)
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(cols.count),
                                     height: cell.height * CGFloat(n)),
                        flipped: false) { rect in
        NSColor(hex: 0xEDEDED).setFill()   // light menu bar: the harder background
        NSBezierPath(rect: rect).fill()
        for (c, col) in cols.enumerated() {
            for (i, f) in col.enumerated() {
                f.draw(at: NSPoint(x: CGFloat(c) * cell.width + 8,
                                   y: CGFloat(i) * cell.height + (cell.height - f.size.height) / 2),
                       from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        return true
    }
    guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { print("render failed"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// The badge animation as a looping GIF on a menu-bar strip, for the README.
/// A few stunts back to back, each followed by the rest pose held for a beat.
@MainActor func renderBadgeGif(to path: String) {
    var live: Usage?
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { if case .success(let u) = $0 { live = u }; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)

    let stunts: [Stunt] = [.classic, .scuttle, .jump]
    let sample = badgeImage(live, mode: .percentAndTime)
    let size = NSSize(width: sample.size.width + 24, height: NSStatusBar.system.thickness)
    let scale: CGFloat = 2

    func frame(_ img: NSImage) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hex: 0xEDEDED).setFill()   // light menu bar: the harder background
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        img.draw(at: NSPoint(x: 12, y: (size.height - img.size.height) / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // (image, seconds) — the rest pose is one long-delay frame, not 12 copies
    var frames: [(CGImage, Double)] = []
    for s in stunts {
        for f in 0..<BadgeFrames.count {
            if let c = frame(badgeImage(live, mode: .percentAndTime, frame: f, stunt: s)) {
                frames.append((c, 1.0 / 12))
            }
        }
        if let c = frame(badgeImage(live, mode: .percentAndTime)) { frames.append((c, 1.5)) }
    }

    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString,
        frames.count, nil) else { print("gif failed"); return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (img, delay) in frames {
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: delay,
             kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { print("gif failed"); return }
    print("wrote \(path)  (\(frames.count) frames)")
}

/// The game crab's poses on one strip — same reason --badge exists: eyeball
/// hand-typed pixel data without launching the game.
@MainActor func renderGameStrip(to path: String) {
    // one column per distinct pose (idle's seq is long but mostly repeats)
    let anims = [GameCrab.walk, GameCrab.shoot, GameCrab.idle]
        .map { ClawdAnims.Anim(uniq: $0.uniq, seq: Array(0..<$0.uniq.count)) }
    let cell = NSSize(width: CGFloat(GameCrab.cellsWide) * 3 + 12,
                      height: CGFloat(Clawd.cellsHigh) * 3 + 12)
    let maxFrames = anims.map(\.seq.count).max() ?? 0
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(maxFrames),
                                     height: cell.height * CGFloat(anims.count)),
                        flipped: false) { rect in
        NSColor(hex: 0x1B1B1B).setFill()
        NSBezierPath(rect: rect).fill()
        for (row, a) in anims.enumerated() {
            for f in 0..<a.seq.count {
                drawAnim(a, frame: f,
                         at: NSPoint(x: CGFloat(f) * cell.width + 6,
                                     y: CGFloat(anims.count - 1 - row) * cell.height + 6),
                         scale: 3)
            }
        }
        return true
    }
    guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { print("render failed"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// MARK: - main

let args = CommandLine.arguments

if args.contains("--test") {
    selfTest()
} else if args.contains("--usage") {
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { r in
        switch r {
        case .success(let u):
            let rows: [(String, Window?)] = [("5-hour", u.fiveHour), ("7-day all", u.sevenDay)]
                + u.models.map { ("7-day \($0.name.lowercased())", Optional($0.window)) }
            for (name, w) in rows {
                guard let w else { continue }
                print(String(format: "%-14@ %5.1f%% used  resets %@", name as NSString,
                             w.utilization, w.resetsAt.map(dayTime) ?? "?"))
            }
        case .failure(let e): print("error: \(e)")
        }
        sem.signal()
    }
    sem.wait()

    // local detail the API doesn't break down: which models, how much traffic
    let entries = scan(root: CLAUDE_ROOT, since: Date().addingTimeInterval(-WEEK))
    let s = summarize(all: entries)
    guard s.cost > 0 else { exit(0) }
    print("\nthis session: \(s.requests) reqs · \(s.sessions) sessions"
          + (s.blockStart.map { " · opened \(clockTime($0))" } ?? ""))
    for m in s.models {
        print(String(format: "  %-16@ %@", m.short as NSString, pct(m.cost / s.cost * 100)))
    }
} else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderCard(to: args[i + 1]) }
} else if let i = args.firstIndex(of: "--badge"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderBadgeStrip(to: args[i + 1]) }
} else if let i = args.firstIndex(of: "--gif"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderBadgeGif(to: args[i + 1]) }
} else if let i = args.firstIndex(of: "--game"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderGameStrip(to: args[i + 1]) }
} else {
    Updates.consolidate()   // one copy of us, in /Applications — before any UI exists
    let app = NSApplication.shared
    let bar = Bar()
    app.delegate = bar
    app.run()
}
