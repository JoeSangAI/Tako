// The app itself: what it holds, how it starts and ends, and what happens every frame.
// Three panels: a screen-sized click-through one for the goo (Goo.swift), a side window whose contents are the web page
// (SidePanel.swift), and the ink around the window (Enchant.swift). Which window it is on is in Windows.swift, making room
// beside that window in MakeRoom.swift, what it can do to a window in Hands.swift and Operate.swift.
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import QuartzCore
import WebKit

final class Controller: NSObject, NSApplicationDelegate {
    var url: URL!
    let backend = Backend()
    let updater = Updater()
    var lastApp: NSRunningApplication?  // the app in front before Tako was, which gets the keyboard back
    let selfTest: Bool
    var side: SideWindow!
    var web: WKWebView!
    var gooPanel: NSPanel!
    var gooView: GooView!
    var goo: Goo!
    var link: CADisplayLink?
    var arrivalWatching = false
    var lastArrivalNotice = 0.0
    var loaded = false
    var region = NSRect.zero  // from the side window's top-left, reported by the page
    var dragging = false
    var target: (id: Int, frame: CGRect)?
    var platforms: [(id: Int, frame: CGRect, sticky: Bool)] = []  // every ordinary window, front to back
    var ticks = 0
    var moving = 0
    var sentGeometry = ""
    var toldOrigin = "", toldOriginAt = 0.0
    var wanted: CGFloat = 0
    var sideOpen = false
    var sideX: CGFloat = 0
    var pid: pid_t = 0
    var bundle = ""            // of the app it is stuck to
    var appName = ""
    var barHeight: CGFloat = 52
    var enchant: Enchant!
    var neverStuck = true, lostID: Int?, lostBundle = ""
    var cardWidth: CGFloat = 0
    var skinBusy = false, skinDirty = false, lastReported = ""
    var appearanceObservation: NSKeyValueObservation?
    var elements: [Int: [Element]] = [:]   // what could be pressed in each window, as of its last look
    var typingInto: [Int: AXUIElement] = [:]  // the text field last pressed in each window
    var askedForContent: Set<pid_t> = []      // apps already asked to show what is inside them
    var operating = false, lastSummon: CFTimeInterval = 0
    var reopenAfterFollow = false, openQuietly = false  // the panel coming along after a step on another window, not taking the keyboard
    var listener: Listener?
    var cardsShown = false, lastStep: CFTimeInterval = 0   // a card has to be clickable, even in the middle of a run
    let inkFlash = InkFlash()
    var hotKey: EventHotKeyRef?
    var isWeChat: Bool { bundle == weChatBundle }
    var isDingTalk: Bool { bundle == dingTalkBundle }
    var trusted = false
    var trustTimer: Timer?, trustTicks = 0, repairedOnce = false, askingFresh = false   // Permissions.swift
    var signedAs = "", adhocSigned = false, screenWhy = "", screenFresh: Bool?, screenRepaired: Bool?, accessRepaired: Bool?   // Permissions.swift
    let launchedAt = Date()
    var pointTap: CFMachPort?                   // ⌃ and the pointer on the stuck window (Pointing.swift)
    var gesture: PointGesture?
    var pointed: [Pointed] = []
    var pointingShown = false, hoverAt: CFTimeInterval = 0, hoverBusy = false
    var hovered: (at: CGPoint, found: Found?, time: CFTimeInterval)?   // the last look under the pointer while ⌃ was held
    var snapshot: (id: Int, frame: CGRect, at: CFTimeInterval, image: Task<CGImage?, Never>)?  // the window as it was when ⌃ went down
    var homeX: CGFloat?, homeWidth: CGFloat = 0           // where the window was before we made room
    var expectedX: CGFloat = 0, expectedWidth: CGFloat = 0 // where we last put it; anything else means the owner moved it
    var ownMoveAt: CFTimeInterval = 0, resettle = false
    var fullHome: CGRect?      // the window's frame behind native full screen, while the panel has brought it out
    var leavingFull = false    // Tako itself is taking the window out of full screen: the move that follows is ours, not the owner's
    var glide: (from: CGFloat, to: CGFloat, step: Int)?
    var last: CFTimeInterval = 0
    var spill: CGFloat = 0
    var stopSource: DispatchSourceSignal?, collapseSource: DispatchSourceSignal?, reportSource: DispatchSourceSignal?
    var headerBusy = false, canCapture = false, captureAsked = false
    var screenTurn = false   // Screen Recording is the one next step (`askSwitch`): only then may the system be asked for it
    var headerRoundBand = 0, sentBand = 0      // the strip as last read in this round, and as last told to the brain
    var headerClickAt: CFTimeInterval = 0, headerDue: CFTimeInterval = 0, headerLate = 0, headerLooking = false
    var headerSeq = 0, openChat = ""           // reads told to the brain, numbered; the chat it settled on (WeChatHeader.swift)
    let headerRun = UUID().uuidString
    var listEnds: [Int: CGFloat] = [:]        // per WeChat window, where its chat list ends, as of the last time its search box showed. A chat opened in a window of its own has no list,
                                              // and the main window's edge cut its whole title off as list
    var headerUntil: CFTimeInterval = 0, headerStable = 0
    let headerCapture = HeaderCapture(reader: { id, width, previous, listEnd, pid in
        await Controller.headerTitles(windowID: id, width: width, previous: previous, listEnd: listEnd, onlyFrontPid: pid)
    }, front: { pid in
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    })
    var stackUntil: CFTimeInterval = 0, wasPressed = false   // windows may be reordering until then: check every frame
    var lastWindowSign: CGFloat = 0, windowShakes: [CFTimeInterval] = []
    // self-test
    var testWindow: NSWindow?
    var panelPlace = PanelPlace.window
    // The desktop panel (PanelPlace, SidePanel.swift): where it is while open, where it last was this run (dragged or not; never
    // saved), the pointer's hold on its header while dragged, and whether a panel carried off a drag opens again on the window it lands on.
    var desktopAt: CGPoint?, desktopLast: CGPoint?, panelGrip: CGPoint?, reopenOnStick = false
    var filePermissionExplained = false
    var desktopPanel: Bool { panelPlace == .floating }
    lazy var attention = Attention(self)
    lazy var entrusted = Entrusted(self)
    lazy var speaking = Speaking(self)
    lazy var teaching = Teaching(self)
    lazy var systemSources = SystemSources(self)
    var fakeMouse: V?
    var frameTimes: [CFTimeInterval] = []
    // The pace (see `advance`): the display callback runs only while something moves; otherwise a slow tick or none at all.
    var paused = false, paceTimer: DispatchSourceTimer?, calmSince: CFTimeInterval = 0, pausedPicture = 0
    var lastRefresh: CFTimeInterval = 0, lastScan: CFTimeInterval = 0, lastTitle: CFTimeInterval = 0, lastStanding: CFTimeInterval = 0
    var paceObserver: CFRunLoopObserver?, pointerMonitors: [Any] = []
    /// A copy being measured (`TAKO_PACE_LOG`): see `paceTest`. `nolog` measures it without the counting itself.
    let measuring = ProcessInfo.processInfo.environment["TAKO_PACE_LOG"] != nil
    lazy var paceLog = measuring && !paceTest.contains("nolog")
    /// Measuring only (`TAKO_PACE_LOG=free`): start as a pet, without touching the saved choice. A copy being measured
    /// beside the owner's own Tako takes neither the summoning shortcut nor ⌃ and the speaking key from it.
    let paceTest = ProcessInfo.processInfo.environment["TAKO_PACE_LOG"] ?? ""
    var paceCount = (frames: 0, ticks: 0, since: CACurrentMediaTime(), label: "")
    var paceWakes: [String: Int] = [:], paceWhys: [String: Int] = [:]
    var paceCPU = [Double](repeating: 0, count: 6)   // TAKO_PACE_LOG: main-thread seconds per part of a frame
    func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    init(selfTest: Bool) { self.selfTest = selfTest }

    func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    func mouse() -> V {
        if let fake = fakeMouse { return fake }
        let m = NSEvent.mouseLocation
        return V(m.x, (NSScreen.screens.first?.frame.maxY ?? 0) - m.y)
    }

    @objc func checkForUpdate() { updater.showOrCheck() }
    /// 做过的事…: every ask in the records and where Tako's folder is, wherever the goo is.
    @objc func showHistory() {
        openHere()
        web.evaluateJavaScript("showHistory()")
    }
    /// 模型设置…: the panel's first card again (account or key), wherever the goo is.
    @objc func chooseModel() {
        openHere()
        web.evaluateJavaScript("chooseModel()")
    }
    var statistics: Bool?   // nil where there is nothing to switch: a development build
    @objc func toggleStatistics() {
        let on = !(statistics ?? true)
        statistics = on
        web.evaluateJavaScript("setStatistics(\(on))")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        entrusted.prepare()  // A local notification may have launched us before the backend is ready.
        lastApp = NSWorkspace.shared.frontmostApplication
        updater.owner = self
        backend.onFail = { [weak self] reason in self?.giveUp(reason) }
        backend.onReady = { [weak self] address in
            guard let self else { return }
            let restarted = self.url != nil
            self.url = address
            if restarted { self.web.load(URLRequest(url: address)) } else { self.launch() }
        }
        backend.start(arguments: CommandLine.arguments.dropFirst().filter { $0 != "--selftest" && !$0.hasPrefix("--showcase") })
    }

    func giveUp(_ reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tako 启动不了"
        alert.informativeText = reason
        if reason.contains("系统设置中 Tako 对桌面、文稿和下载") {
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn, let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(page) }
        } else {
            alert.addButton(withTitle: "退出")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    /// A Dock click calls the body over without attaching it or opening a conversation.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard goo != nil else { return false }
        learn("dock")
        lastApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.comeHere() }
        return false
    }

    func comeHere() {
        if attention.hidden { attention.setQuiet(hidden: false) }
        if goo.mode == .attached || goo.mode == .open { goo.tearOff(velocity: V(), reason: "dock") }
        closeSide()
        goo.sleeping = false; goo.puddle = false; goo.peekSide = 0; goo.stopIdleScene()
        let front = lastApp?.processIdentifier
        let win = openWindows().first { $0.pid == front && $0.frame.width > 300 && $0.frame.height > 200 }
        guard let primary = NSScreen.screens.first else { return }
        let cursor = NSEvent.mouseLocation
        // Arrive just above the window's top edge so normal free-body gravity can settle it there.
        let p = win.map { V($0.frame.maxX - goo.radius * 1.5, $0.frame.minY - goo.radius * 2) } ?? V(cursor.x, primary.frame.maxY - cursor.y)
        let screenPoint = win.map { NSPoint(x: $0.frame.midX, y: primary.frame.maxY - $0.frame.midY) } ?? cursor
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main ?? primary
        let bounds = screen.visibleFrame
        let top = primary.frame.maxY - bounds.maxY, bottom = primary.frame.maxY - bounds.minY
        goo.dockDestination = V(clamp(p.x, bounds.minX + goo.radius * 2, bounds.maxX - goo.radius * 2), clamp(p.y, top + goo.radius * 2, bottom - goo.radius * 2))
        if gooPanel.frame != screen.frame { setScreen(screen) }
        gooPanel.orderFrontRegardless()
    }

    func launch() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "goo")
        let start = NSRect(x: 0, y: 0, width: sidePanelWidth, height: 600)
        web = TakoWeb(frame: start, configuration: config)
        (web as? TakoWeb)?.owner = self
        web.registerForDraggedTypes([.fileURL])
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.load(URLRequest(url: url))

        side = SideWindow(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(side)
        side.contentView = web

        let screen = NSScreen.main ?? NSScreen.screens[0]
        gooPanel = SideWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(gooPanel)
        gooView = GooView(frame: NSRect(origin: .zero, size: screen.frame.size))
        gooView.owner = self
        gooView.autoresizingMask = [.width, .height]
        gooView.registerForDraggedTypes([.fileURL])
        gooPanel.contentView = gooView
        goo = Goo(host: self, view: gooView)
        enchant = Enchant(host: self)
        setScreen(screen)
        if !attention.hidden { gooPanel.orderFront(nil) }

        checkTrustAtLaunch()
        installPointing()
        // A hung app must not freeze the goo for the default 6 seconds per question.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        scan()
        startGoo()
        attention.start()

        let link = gooView.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        if !selfTest { watchForWork() }

        // Being stopped must not strand the window where we moved it.
        signal(SIGTERM, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        stop.setEventHandler { [weak self] in self?.moveBackNow(); self?.backend.stop(); exit(0) }
        stop.resume()
        restoreMoved()
        if !selfTest { updater.start() }  // A check of the goo opens no panels and moves no windows.
        // A display unplugged or rearranged: never leave it on a screen that is gone.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let primary = NSScreen.screens.first?.frame else { return }
            let here = NSPoint(x: self.goo.c.x, y: primary.maxY - self.goo.c.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(here) }) ?? NSScreen.main { self.setScreen(screen) }
            self.placeSide()
        }
        stopSource = stop

        // SIGUSR1 collapses the side window, for scripted checks of the move back.
        signal(SIGUSR1, SIG_IGN)
        let collapse = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        collapse.setEventHandler { [weak self] in self?.closeSide() }
        collapse.resume()
        collapseSource = collapse

        // SIGUSR2 reports where it is, also for scripted checks.
        signal(SIGUSR2, SIG_IGN)
        let report = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        report.setEventHandler { [weak self] in
            guard let self else { return }
            self.log("at \(Int(self.goo.c.x)) \(Int(self.goo.c.y)) \(self.goo.mode) on \(self.bundle) key=\(self.side.isKeyWindow) responder=\(String(describing: self.side.firstResponder.map { type(of: $0) }))")
        }
        report.resume()
        reportSource = report

        // Switching apps reorders every window: catch up at once rather than on the next scan.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.noteArrival()
            if let other = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, other != NSRunningApplication.current { self?.lastApp = other }
            if let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid { self.sampleSkin() }
            self?.noteHeaderActivity(switching: true)   // a chat app coming forward may show another chat (a notification clicked, say)
            self?.stackUntil = CACurrentMediaTime() + 0.8
            // The new app's windows come forward a moment after the notification.
            for delay in [0.0, 0.1, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan() } }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.sampleSkin() }
        }
        pollCommands()
        entrusted.start()
        systemSources.start()
        // The one next step (`Ladder.next`): a switch soon after launch, a line only once things have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.teaching.nextStep(lines: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.teaching.nextStep() }
        if !measuring { installHotKey() }
        installMenus()
        if selfTest { CommandLine.arguments.contains { $0.hasPrefix("--showcase") } ? runShowcase() : runSelfTest() }
        // Opening an app puts it in front; Tako goes to the window it sits on, not in the way of it.
        if lastApp == nil || lastApp == NSRunningApplication.current {
            lastApp = openWindows().first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }  // By now macOS has already put Tako in front.
        }
        lastApp?.activate()
    }

    func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // Holding the keyboard (the panel open, or the body just pressed), pointer moves come to Tako itself, not to the
        // global monitor: taken, they reach the local one and the click-through follows the pointer (`watchForWork`).
        panel.acceptsMouseMovedEvents = true
    }

    func startGoo() {
        let pet = UserDefaults.standard.string(forKey: modeKey) == "pet" || paceTest.contains("free")
        if pet || target == nil {
            goo.mode = .free
            goo.place(at: V(goo.visible.maxX - 120, goo.visible.maxY - 300))
            setWatching(false)
        } else if let w = target?.frame {
            // drops in from above and grabs on
            goo.place(at: V(min(w.maxX + 40, goo.visible.maxX - 20), w.minY + 10))
            goo.stick(to: w.maxX)
        }
    }

    func setScreen(_ screen: NSScreen) {
        guard let primary = NSScreen.screens.first?.frame else { return }
        let f = screen.frame, vis = screen.visibleFrame
        goo.screenRect = CGRect(x: f.minX, y: primary.maxY - f.maxY, width: f.width, height: f.height)
        goo.visible = CGRect(x: vis.minX, y: primary.maxY - vis.maxY, width: vis.width, height: vis.height)
        gooPanel.setFrame(f, display: false)
        gooView.layer?.frame = CGRect(origin: .zero, size: f.size)
    }

    // MARK: every frame

    func noteArrival() {
        guard arrivalWatching, CACurrentMediaTime() - lastArrivalNotice > 0.15 else { return }
        lastArrivalNotice = CACurrentMediaTime()
        for delay in [0.15, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.arrivalWatching else { return }
                self.post(path: "/native/arrival", body: [:])
            }
        }
    }

    @objc func frame(_ link: CADisplayLink) { advance(to: link.timestamp, linked: true) }

    /// One frame: the body stepped to `now` and drawn, and whatever has to follow the window or the pointer. `linked`: from the
    /// display callback; otherwise a tick of a slow pace (`pace`), where the time since the last frame is stepped coarsely,
    /// and time that passed with nothing moving at all is skipped over (`fastForward`).
    func advance(to now: CFTimeInterval, linked: Bool) {
        let gap = last == 0 ? 1.0 / 120 : now - last
        last = now
        var dt = min(0.05, gap)
        if selfTest { frameTimes.append(dt) }
        let slow = !selfTest && (!linked || gap > 0.06)
        if paceLog { linked ? (paceCount.frames += 1) : (paceCount.ticks += 1) }
        var mark = paceLog ? threadCPU() : 0
        func part(_ i: Int) { guard paceLog else { return }; let t = threadCPU(); paceCPU[i] += t - mark; mark = t }

        let pressed = NSEvent.pressedMouseButtons != 0
        if pressed != wasPressed {
            wasPressed = pressed
            stackUntil = CACurrentMediaTime() + 0.5
            if !pressed { noteHeaderActivity(switching: pointerOnTarget) }   // some lists open a chat on release: read from then, not from the press
        }
        // The window it is on: every frame while something is pressed or moving, a few times a second otherwise, once a second at a slow pace.
        if pressed || moving > 0 || goo.mode == .grabbed || now - lastRefresh >= (slow ? 1 : 0.1) { lastRefresh = now; refresh() }
        if goo.standingID != nil, pressed || now - lastStanding >= 0.05 { lastStanding = now; refreshStanding() }
        ticks += 1
        if now - lastScan >= (slow ? 5 : 0.4) { lastScan = now; scan() } else if pressed || CACurrentMediaTime() < stackUntil { keepStacked() }
        if !isWeChat && now - lastTitle >= 2 { lastTitle = now; readHeaderIfDue(title: true) }
        stepGlide()
        movePanel()
        followScreen()
        followPointing()
        speaking.track(); teaching.track()
        if now - toldOriginAt >= 0.2 { toldOriginAt = now; tellOrigin() }
        part(0)

        if slow {
            let stepped = min(gap, 0.5)
            goo.fastForward(gap - stepped)
            let n = max(1, Int((stepped * 30).rounded()))   // nothing fast is moving: steps of a thirtieth of a second hold it as steady
            for _ in 0..<n { goo.step(CGFloat(stepped) / CGFloat(n)) }
            spill = 0
            dt = stepped
        } else {
            spill = min(0.05, spill + CGFloat(dt))
            let fixed: CGFloat = 1.0 / 240
            while spill >= fixed { goo.step(fixed); spill -= fixed }
        }
        part(1)
        goo.draw()
        part(2)
        enchant.step(CGFloat(dt))
        // A run whose end never came (a restart, a lost reply) must not leave the panel unclickable.
        if operating, !cardsShown, CACurrentMediaTime() - lastStep > 60 { log("run went quiet"); operating = false; goo.reachGoal = nil }
        updateClickThrough()
        updateOrder()
        pace(linked: linked)
        part(3)
    }

    // MARK: pace

    /// What the body and everything around it need now. Anything the owner is doing with it (pressing, dragging, pointing,
    /// speaking), a window moving or Tako working a window keeps every frame; otherwise the body says (`Goo.pace`).
    var wantedPace: Pace {
        if selfTest || dragging || moving > 0 || glide != nil || gesture != nil || pointingShown || speaking.animating || operating
            || enchant.jellyAt > 0 || CACurrentMediaTime() < stackUntil || NSEvent.pressedMouseButtons != 0 { return .busy }
        if paceLog { let (pace, why) = goo.paceWhy; paceWhys[why, default: 0] += 1; return pace }
        return goo.pace
    }

    /// For TAKO_PACE_LOG: what keeps it busy, outside the body or in it.
    var busyWhy: String {
        let host: [(Bool, String)] = [(dragging, "dragging"), (moving > 0, "moving"), (glide != nil, "glide"), (gesture != nil, "gesture"),
            (pointingShown, "pointing"), (speaking.animating, "speaking"), (operating, "operating"), (enchant.jellyAt > 0, "jelly"),
            (CACurrentMediaTime() < stackUntil, "stack"), (NSEvent.pressedMouseButtons != 0, "pressed")]
        return host.first { $0.0 }?.1 ?? goo.paceWhy.1
    }

    /// After each frame: keep the display callback at the rate the moment needs, or let it go and leave a slow tick or nothing.
    func pace(linked: Bool) {
        let now = CACurrentMediaTime(), want = wantedPace
        if paceLog, now - paceCount.since >= 5 {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let process = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            let ms = paceCPU.prefix(4).map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/")
            log("pace \(paceCount.label) frames=\(paceCount.frames) ticks=\(paceCount.ticks) in \(Int(now - paceCount.since))s main-ms(house/step/draw/rest)=\(ms) process-ms=\(String(format: "%.0f", (process - paceCPU[5]) * 1000)) wakes=\(paceWakes) why=\(paceWhys) draw-ms=\(goo.drawCPU.map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/"))")
            goo.drawCPU = [Double](repeating: 0, count: 8)
            paceWakes = [:]; paceWhys = [:]
            paceCPU = [0, 0, 0, 0, 0, process]
            paceCount = (0, 0, now, "")
        }
        // Its breath is Core Animation's whenever nothing but slow things move; anything busy and the skin breathes itself.
        if want == .busy || paceTest.contains("nobreath") { goo.stopBreathing() } else { goo.keepBreathing(mouthToo: want == .still) }
        switch want {
        case .busy, .looking:
            calmSince = 0
            if !linked { return wakeLoop("tick found \(want)") }
            let rate: Float
            if want == .looking { rate = 30 }   // eyes after the pointer, a blink
            else { rate = goo.mode == .grabbed || goo.mode == .free || moving > 0 || glide != nil ? 120 : 60 }
            if let link, link.preferredFrameRateRange.preferred != rate {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: rate)
            }
        case .ambient, .still:
            if linked {
                if calmSince == 0 { calmSince = now }
                guard now - calmSince >= 0.12, let link else { return }
                link.isPaused = true
                paused = true
                if paceLog { paceCount.label = "\(want)" }
            }
            pausedPicture = picture
            schedule(want)
        }
    }

    /// The next slow tick, or the moment the body does something by itself (a blink, a glance), whichever comes first. Still,
    /// with nothing coming, there is no timer at all: only something happening wakes it.
    func schedule(_ want: Pace) {
        paceTimer?.cancel(); paceTimer = nil
        let now = CACurrentMediaTime()
        var next = Double.infinity, event = false
        if case .ambient(let rate) = want { next = now + 1 / rate }
        if let due = goo.nextEvent {
            let at = last + (due - goo.clock) - 0.04
            if at < next { next = max(now, at); event = true }
        }
        guard next.isFinite else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + (next - now), leeway: .milliseconds(event ? 4 : 12))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.paceTimer?.cancel(); self.paceTimer = nil
            if event { self.wakeLoop("event") } else { self.advance(to: CACurrentMediaTime(), linked: false) }
        }
        timer.resume()
        paceTimer = timer
    }

    /// Back to every frame: something happened (the pointer, a command, the panel, a promise, a notice).
    func wakeLoop(_ why: String = "other") {
        guard paused, let link else { return }
        if paceLog { paceWakes[why, default: 0] += 1 }
        paused = false
        paceTimer?.cancel(); paceTimer = nil
        calmSince = 0
        link.isPaused = false
    }

    /// A pointer move far from the body that its eyes would hardly follow wakes nothing: only a press, a move near it or near
    /// a promise held out, one that turns its eyes by a visible amount, or any move at all while it sleeps (that wakes it).
    func pointerMatters(_ event: NSEvent) -> Bool {
        guard event.type == .mouseMoved else { return true }
        if goo.sleeping { return true }
        let m = pointer(), to = m - goo.c, distance = to.length
        if distance < 300 || !goo.handPhase.isEmpty || goo.carrying { return true }
        let look = to.unit * min(1, distance / 90)
        return (look - goo.gazeGoal).length * goo.radius * 0.13 > 0.15   // how far the pupils would move, in points
    }

    /// Whatever could change the still picture without anything on the body moving.
    var picture: Int {
        var h = Hasher()
        h.combine(goo.handText); h.combine(goo.onDark); h.combine(goo.costume.outfit?.id); h.combine(goo.state); h.combine(goo.act)
        h.combine(goo.handPhase); h.combine(goo.carrying); h.combine(goo.silenced); h.combine(goo.sleeping); h.combine(sideOpen)
        h.combine(Int(goo.c.x * 4)); h.combine(Int(goo.c.y * 4)); h.combine(target?.id); h.combine(goo.radius)
        if let frame = target?.frame { h.combine(Int(frame.minX)); h.combine(Int(frame.minY)); h.combine(Int(frame.width)); h.combine(Int(frame.height)) }
        return h.finalize()
    }

    /// While the callback is let go, anything at all that runs on the main thread (a command, a reply, a page message, a
    /// notice, a timer of another part) is looked at once it is done: if it set the body going, frames come back at once.
    /// The pointer and buttons anywhere wake it as well, so its eyes follow and it can be caught.
    func watchForWork() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, self.paused else { return }
            if self.paceLog { self.paceWakes["(looked)", default: 0] += 1 }
            switch self.wantedPace {
            case .busy, .looking: self.wakeLoop(self.paceLog ? "work:" + self.busyWhy : "work")
            default: if self.picture != self.pausedPicture { self.wakeLoop("picture") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        paceObserver = observer
        let pointer: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                              .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged, .keyDown]
        let seen: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.attention.noteInput()
            if event.type == .keyDown || (event.type == .flagsChanged && !self.stuckOn) { return }   // typing moves nothing on the body
            self.updateClickThrough()
            if self.paused, self.fakeMouse == nil, self.pointerMatters(event) { self.wakeLoop("pointer") }
        }
        // Measuring the body left alone (`TAKO_PACE_LOG=…,alone`): the body sees the pointer held where it was; presses and
        // the window letting them through still follow the real pointer.
        if paceTest.contains("alone") { fakeMouse = mouse() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: pointer, handler: seen) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: pointer, handler: { seen($0); return $0 }) { pointerMonitors.append(local) }
    }

    func followScreen() {
        let point: V
        if let destination = goo.handHome { point = destination }
        else { switch goo.mode {
        case .grabbed: point = mouse()  // the pointer leads: otherwise the screen's own bounds would stop it at the edge
        case .free: point = goo.c
        default: point = target.map { V($0.frame.maxX - 1, $0.frame.midY) } ?? goo.c
        } }
        guard let primary = NSScreen.screens.first?.frame else { return }
        let ns = NSPoint(x: point.x, y: primary.maxY - point.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(ns) }), screen.frame != gooPanel.frame {
            setScreen(screen)
        }
    }

    /// Where the pointer really is. Measuring with the pointer held for the body (`fakeMouse`, `alone`), presses still go
    /// where the real pointer is.
    func pointer() -> V {
        if selfTest { return mouse() }
        let m = NSEvent.mouseLocation
        return V(m.x, (NSScreen.screens.first?.frame.maxY ?? 0) - m.y)
    }

    /// Called on every frame and on every pointer move, also while the body is not being drawn: otherwise a promise held out
    /// would let presses on its buttons through to the window under it.
    func updateClickThrough() {
        let m = pointer()
        entrusted.observeHand(at: m)
        let hovering = goo.carrying && goo.handPhase != "offer" && goo.handRect.insetBy(dx: -8, dy: -8).contains(goo.L(m))
        let preview = AttentionPolicy.heldPreview(hovered: hovering, quiet: attention.quiet)
        if preview != goo.handHovered {
            if preview { attention.freshen() }
            goo.handHovered = preview && !attention.quiet
            goo.drawHand()
            attention.rewatch()
        }
        let onGoo = HandHit.takesClicks(grabbed: goo.mode == .grabbed, distance: (m - goo.c).length, radius: goo.radius, onHand: goo.handHit(m) != nil)
        if gooPanel.ignoresMouseEvents == onGoo { gooPanel.ignoresMouseEvents = !onGoo }
        if sideOpen {
            let local = NSPoint(x: m.x - side.frame.minX, y: m.y - ((NSScreen.screens.first?.frame.maxY ?? 0) - side.frame.maxY))
            // While it is working a window the panel may lie over part of it: its own presses have to reach that window.
            let through = HandHit.panelLetsThrough(floating: desktopPanel, inCard: region.contains(local), dragging: dragging, working: operating && !cardsShown)
            if side.ignoresMouseEvents != through { side.ignoresMouseEvents = through }
        }
    }

    /// Attached: just above WeChat, so other apps cover both. Free: above everything, a pet on the glass.
    func updateOrder() {
        if attention.hidden { return }
        let free = goo.mode == .free || goo.mode == .grabbed || goo.handHome != nil
        let level: NSWindow.Level = free ? .floating : .normal
        if gooPanel.level != level {
            gooPanel.level = level
            gooPanel.collectionBehavior = free ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
            if free { gooPanel.orderFront(nil) }
        }
    }

    func showMenu(_ event: NSEvent, in view: NSView) { learn("menu"); NSMenu.popUpContextMenu(menu(), with: event, for: view) }

    /// The Dock icon carries the same menu: when the goo is out of sight (its window minimized, another Space) it is the only way in.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { goo == nil ? nil : menu(dock: true) }

    func menu(dock: Bool = false) -> NSMenu {
        let menu = NSMenu()
        if dock {
            let attach = NSMenuItem(title: "贴到当前窗口", action: #selector(attachFrontWindow), keyEquivalent: "")
            attach.target = self; menu.addItem(attach)
        }
        let pet = goo.mode == .free || goo.mode == .grabbed
        let name = appName.isEmpty ? "窗口" : appName
        let toggle = NSMenuItem(title: pet ? "粘回\(name)" : "从\(name)上扒下来", action: #selector(toggleStick), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !pet || target != nil
        // The shortcut lives here now: a greyed-out line of its own read as a broken setting.
        toggle.toolTip = "点一下 Tako 就能跟它说话；在任意窗口按 ⌃⌥T，它直接过来。"
        menu.addItem(toggle)
        let mute = NSMenuItem(title: "禁言", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self; mute.state = attention.muted ? .on : .off; menu.addItem(mute)
        let hide = NSMenuItem(title: "隐藏", action: #selector(toggleHidden), keyEquivalent: "")
        hide.target = self; hide.state = attention.hidden ? .on : .off; menu.addItem(hide)
        let speak = NSMenuItem(title: "右 ⌥ 说话键", action: #selector(toggleSpeaking), keyEquivalent: "")
        speak.target = self; speak.state = speaking.enabled ? .on : .off; menu.addItem(speak)
        let hints = NSMenuItem(title: "使用提示", action: #selector(toggleTeaching), keyEquivalent: "")
        hints.target = self; hints.state = teaching.enabled ? .on : .off; menu.addItem(hints)
        menu.addItem(outfitMenu())
        menu.addItem(.separator())
        let history = NSMenuItem(title: "做过的事…", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        history.toolTip = "Tako 做过的事，和它的对话记录、产出文件放在哪。"
        menu.addItem(history)
        let model = NSMenuItem(title: "模型设置…", action: #selector(chooseModel), keyEquivalent: "")
        model.target = self
        model.toolTip = "用 AI 账号登录，或者换成 API key。"
        menu.addItem(model)
        if let statistics {
            let item = NSMenuItem(title: "帮助作者优化", action: #selector(toggleStatistics), keyEquivalent: "")
            item.target = self
            item.toolTip = "匿名回传错误、用量和固定词表里的标签，没有你说的话。"
            item.state = statistics ? .on : .off
            menu.addItem(item)
        }
        let version = NSMenuItem(title: "Tako \(Updater.current)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let update = NSMenuItem(title: updater.menuTitle, action: #selector(checkForUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        if dock { return menu }   // the Dock adds its own 退出
        let quit = NSMenuItem(title: "退出 Tako", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// 装扮: follow the occasions (nothing chosen means this), wear one hat from the wardrobe, or none at all.
    func outfitMenu() -> NSMenuItem {
        let today = Outfit.today(), choice = Outfit.choice
        let sub = NSMenu()
        func add(_ title: String, _ value: String) {
            let item = NSMenuItem(title: title, action: #selector(chooseOutfit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = choice == value ? .on : .off
            sub.addItem(item)
        }
        let now = Outfit.occasion(on: today, service: Outfit.service)
        add(now.map { "跟着节日换（\($0.service != nil ? "接着 DeepSeek" : "这几天")：\($0.name)）" } ?? "跟着节日换", "occasions")
        sub.addItem(.separator())
        for outfit in Outfit.wardrobe(on: today) { add(outfit.name, outfit.id) }
        sub.addItem(.separator())
        add("不戴", "none")
        let item = NSMenuItem(title: "装扮", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc func chooseOutfit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Outfit.choice = value
        goo.costume.checkedAt = -100   // put it on (or take it off) now, not at the next minute
    }

    @objc func toggleStick() {
        if goo.mode == .free || goo.mode == .grabbed {
            if let edge = target?.frame.maxX { goo.stick(to: edge, window: target?.id) }
        } else {
            goo.tearOff(velocity: V(190, -240), reason: "menu")
        }
    }

    @objc func attachFrontWindow() {
        let pid = lastApp?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let win = openWindows().first(where: { $0.pid == pid && $0.frame.width > 300 && $0.frame.height > 200 }) else { goo.fumble(); return }
        if attention.hidden { attention.setQuiet(hidden: false) }
        goo.dockDestination = nil; goo.stick(to: win.frame.maxX, window: win.id); gooPanel.orderFrontRegardless()
    }

    @objc func toggleTeaching() { teaching.toggle() }
    @objc func toggleSpeaking() { speaking.toggle() }
    @objc func toggleMute() { learn("mute"); attention.setQuiet(muted: !attention.muted) }
    @objc func toggleHidden() { attention.setQuiet(hidden: !attention.hidden) }

    @objc func quit() {
        moveBackNow()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stop()
        guard goo != nil else { return }  // It never got as far as moving anything.
        moveBackNow()
        homeX = nil   // Back, or left where the owner put it: nothing for the next start to put right.
        recordMoved()
    }
}
