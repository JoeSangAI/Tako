// Fixed, local hints. They never start a model turn or look at a window's contents.
// What may come before the owner, and when, is decided in one place: the brain's `Ladder.next` (ladder.py).
// This file only tells it what the app knows (the two switches, whether a chat app is on this Mac, what the owner has done once),
// asks the system for a switch when that is the step, and says a line by the body when nothing else has the floor.
import AppKit
import ApplicationServices

final class TeachingInk: NSView {
    var text = "", onDark = false
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: bounds.insetBy(dx: 8, dy: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(calibratedWhite: onDark ? 0.95 : 0.35, alpha: 0.78), .paragraphStyle: paragraph])
        NSColor(calibratedWhite: onDark ? 0.95 : 0.35, alpha: 0.38).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 5, width: 2, height: 2)).fill()
    }
}

final class Teaching {
    unowned let host: Controller
    private var finished = false
    private var panel: NSPanel?
    private var until: CFTimeInterval = 0
    private var goal: V?
    private let enabledKey = "hintsEnabled"
    /// What the page needs for its one 试试 button: only asking, in a window or a chat, until it has been done once.
    static let catalog: [[String: String]] = [["id": "ask", "panel": "ask"]]
    /// The steps that are a line by the body. The others are the panel's (a card, a line) or the system's (a switch).
    static let bubbles: Set<String> = ["first", "speak", "summon"]
    init(_ host: Controller) { self.host = host }
    var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    func toggle() { UserDefaults.standard.set(!enabled, forKey: enabledKey); if !enabled { hide() }; host.attention.rewatch() }
    /// A turn finished: the next step, if there is one, comes a moment later.
    func completed() {
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.check() }
    }

    /// A single tap on the body by someone who has never double clicked it: once the double-click interval has passed with no
    /// second tap, the one thing to know comes now. It answers the owner's own tap, so it is not one of the day's invitations:
    /// once a run, gone by itself, never once learned, never over anything else.
    private var pokeTold = false
    func poked() {
        guard !host.selfTest, enabled, !learned("open"), !pokeTold else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15) { [weak self] in
            guard let self, !self.learned("open"), !self.pokeTold, !self.busy, !self.host.attention.frontIsFullScreen() else { return }
            self.pokeTold = true
            self.show("open", "双击我，跟我说话。")
        }
    }
    private func learned(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: learnedKey) ?? []).contains(id) }

    /// A line by the body is still to come (the last answer named one that could not be said yet): only then is the owner coming
    /// back worth watching for.
    private var waiting = false
    var pendingToday: Bool { !host.selfTest && enabled && waiting }

    // ---- the one next step (`Ladder.next`) ----
    private var asking = false
    /// Asks the brain for the one next step with what the app knows. A switch is asked of the system when it is the step (once
    /// each, `askSwitch`); a line is said only when nothing else has the floor, and only then does it count as offered (`take`).
    /// `lines: false` at launch and when a switch changed: the switches only, the first line waits for its own moment.
    func nextStep(lines: Bool = true) {
        guard !host.selfTest, host.url != nil, !asking else { return }
        let free = lines && enabled && !busy && !host.attention.frontIsFullScreen()
        let chatApps = [weChatBundle, dingTalkBundle].contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        let body: [String: Any] = ["trusted": host.trusted, "capture": host.canCapture || CGPreflightScreenCaptureAccess(), "chat_apps": chatApps,
                                   "learned": UserDefaults.standard.stringArray(forKey: learnedKey) ?? [], "take": free]
        asking = true
        host.post(path: "/ladder/next", body: body) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                let step = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let id = step["id"] as? String ?? ""
                if id == "accessibility" || id == "screen" { self.host.askSwitch(id) }
                self.waiting = Self.bubbles.contains(id) && !free
                if free, let say = step["say"] as? String, !say.isEmpty { self.firstTry(say, feature: id) }
                self.host.attention.rewatch()
            }
        }
    }

    /// A line of the next step, as soon as nothing else has the floor (an answer in the bubble, the panel, speaking); given up after
    /// `tries` seconds rather than pushed in. The first try's next step (`teach`) waits longer: it is about what was just entrusted.
    func firstTry(_ line: String, feature: String = "first", tries: Int = 30) {
        guard !host.selfTest, enabled, tries > 0 else { return }
        if host.attention.quiet || host.sideOpen || host.operating || host.speaking.active || host.goo.carrying && host.entrusted.offerID != nil
            || host.attention.frontIsFullScreen() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.firstTry(line, feature: feature, tries: tries - 1) }
            return
        }
        show(feature, line, seconds: feature == "first" ? 8 : 5)
        host.attention.rewatch()
    }

    /// Called when a turn finishes or the owner comes back from being away (Attention); never on a clock.
    func check() {
        guard !host.selfTest else { return }
        let returned = host.attention.takeReturned("teaching")
        guard finished || returned || waiting else { return }
        finished = false
        nextStep()
    }

    /// Anything else going on puts a hint away.
    private var busy: Bool {
        // The first try's line is about the very promise just made: holding it doesn't put that line away.
        host.attention.quiet || !enabled || (feature != "first" && (!host.entrusted.items.isEmpty || host.goo.carrying))
            || host.sideOpen || host.operating || host.goo.state != "idle" || host.speaking.active
    }
    private var feature = ""
    private func show(_ feature: String, _ text: String, seconds: Double = 4) {
        let size = BubbleLayout.size(text, font: .systemFont(ofSize: 10.5), maximum: 180)
        let compact = CGSize(width: size.width, height: size.height > 32 ? 38 : 24)
        guard let p = host.speaking.showHint(text, size: compact) else { return }
        guard let primary = NSScreen.screens.first else { return }
        let point = NSPoint(x: host.goo.c.x, y: primary.frame.maxY - host.goo.c.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? primary
        p.setFrame(BubbleLayout.frame(size: compact, point: point, visible: screen.visibleFrame, radius: host.goo.radius), display: false)
        panel = p; until = CACurrentMediaTime() + seconds; self.feature = feature
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            guard let self, self.panel === p, CACurrentMediaTime() >= self.until else { return }
            self.hide()
        }
        let r = host.goo.radius
        let offset: V
        switch feature {
        case "speak", "type": offset = V(-r, -r)
        default: offset = V(r * 1.2, -r * 0.5)
        }
        let hand = host.goo.c + offset; goal = hand; host.goo.reachGoal = hand
        p.orderFrontRegardless()
    }
    func track() {
        guard let panel, panel.isVisible, let primary = NSScreen.screens.first else { return }
        if busy || CACurrentMediaTime() >= until { hide(); return }
        let point = NSPoint(x: host.goo.c.x, y: primary.frame.maxY - host.goo.c.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let frame = BubbleLayout.frame(size: panel.frame.size, point: point, visible: screen.visibleFrame, radius: host.goo.radius)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if let ink = panel.contentView as? TeachingInk, ink.onDark != host.goo.onDark { ink.onDark = host.goo.onDark; ink.needsDisplay = true }
        host.goo.bubbleGoal = BubbleLayout.goal(frame: frame, point: point, primaryTop: primary.frame.maxY)
    }
    func hide(keepingFirst: Bool = false) {
        if keepingFirst && feature == "first" && panel != nil { return }
        if panel != nil { host.goo.bubbleGoal = nil }
        host.speaking.hideHint(); panel = nil
        if let goal, host.goo.reachGoal?.x == goal.x, host.goo.reachGoal?.y == goal.y { host.goo.reachGoal = nil }
        goal = nil
    }
}
