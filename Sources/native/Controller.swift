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
    var loaded = false
    var region = NSRect.zero  // from the side window's top-left, reported by the page
    var dragging = false
    var target: (id: Int, frame: CGRect)?
    var platforms: [(id: Int, frame: CGRect, sticky: Bool)] = []  // every ordinary window, front to back
    var ticks = 0
    var moving = 0
    var sentGeometry = ""
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
    var skinBusy = false, lastReported = ""
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
    var trusted = false
    var homeX: CGFloat?, homeWidth: CGFloat = 0           // where the window was before we made room
    var expectedX: CGFloat = 0, expectedWidth: CGFloat = 0 // where we last put it; anything else means the owner moved it
    var ownMoveAt: CFTimeInterval = 0, resettle = false
    var fullHome: CGRect?      // the window's frame behind native full screen, while the panel has brought it out
    var glide: (from: CGFloat, to: CGFloat, step: Int)?
    var last: CFTimeInterval = 0
    var spill: CGFloat = 0
    var stopSource: DispatchSourceSignal?, collapseSource: DispatchSourceSignal?, reportSource: DispatchSourceSignal?
    var headerBusy = false, lastBand = 0, canCapture = false, captureAsked = false
    var listEnd: CGFloat = 0                  // where WeChat's chat list ends, in points, as of the last time its search box showed
    var headerAt: CFTimeInterval = 0          // a click in WeChat may have opened another chat: read the title then, not on the next round
    var stackUntil: CFTimeInterval = 0, wasPressed = false   // windows may be reordering until then: check every frame
    var lastWindowSign: CGFloat = 0, windowShakes: [CFTimeInterval] = []
    // self-test
    var testWindow: NSWindow?
    var fakeMouse: V?
    var frameTimes: [CFTimeInterval] = []

    init(selfTest: Bool) { self.selfTest = selfTest }

    func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    func mouse() -> V {
        if let fake = fakeMouse { return fake }
        let m = NSEvent.mouseLocation
        return V(m.x, (NSScreen.screens.first?.frame.maxY ?? 0) - m.y)
    }

    @objc func checkForUpdate() { updater.showOrCheck() }
    var statistics: Bool?   // nil where there is nothing to switch: a development build
    @objc func toggleStatistics() {
        let on = !(statistics ?? true)
        statistics = on
        web.evaluateJavaScript("setStatistics(\(on))")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        lastApp = NSWorkspace.shared.frontmostApplication
        updater.owner = self
        backend.onFail = { [weak self] reason in self?.giveUp(reason) }
        backend.onReady = { [weak self] address in
            guard let self else { return }
            let restarted = self.url != nil
            self.url = address
            if restarted { self.web.load(URLRequest(url: address)) } else { self.launch() }
        }
        backend.start(arguments: CommandLine.arguments.dropFirst().filter { $0 != "--selftest" })
    }

    func giveUp(_ reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tako 启动不了"
        alert.informativeText = reason
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// The Dock icon does what the shortcut does. Tako never keeps the keyboard from the app it sits on.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard goo != nil else { return false }
        lastApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.summon() }
        return false
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
        gooPanel.orderFront(nil)

        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("accessibility trusted=\(trusted)")
        // A hung app must not freeze the goo for the default 6 seconds per question.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        scan()
        startGoo()

        let link = gooView.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link

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
            if let other = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, other != NSRunningApplication.current { self?.lastApp = other }
            self?.stackUntil = CACurrentMediaTime() + 0.8
            // The new app's windows come forward a moment after the notification.
            for delay in [0.0, 0.1, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan() } }
        }
        pollCommands()
        installHotKey()
        installMenus()
        if selfTest { runSelfTest() }
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
    }

    func startGoo() {
        let pet = UserDefaults.standard.string(forKey: modeKey) == "pet"
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

    @objc func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 120 : min(0.05, now - last)
        last = now
        if selfTest { frameTimes.append(dt) }

        if targetRefreshDue() { refresh() }
        refreshStanding()
        ticks += 1
        let pressed = NSEvent.pressedMouseButtons != 0
        if pressed != wasPressed {
            wasPressed = pressed
            stackUntil = CACurrentMediaTime() + 0.5
            if !pressed, isWeChat, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { headerAt = CACurrentMediaTime() + 0.12 }
        }
        if ticks % 30 == 0 { scan() } else if pressed || CACurrentMediaTime() < stackUntil { keepStacked() }
        if headerAt > 0, CACurrentMediaTime() >= headerAt, !headerBusy { headerAt = 0; readHeaderIfDue() }
        else if ticks % 30 == 0 { readHeaderIfDue() }
        stepGlide()
        followScreen()

        spill = min(0.05, spill + CGFloat(dt))
        let fixed: CGFloat = 1.0 / 240
        while spill >= fixed { goo.step(fixed); spill -= fixed }
        goo.draw()
        enchant.step(CGFloat(dt))
        if ticks % 300 == 0 { sampleSkin() }
        // A run whose end never came (a restart, a lost reply) must not leave the panel unclickable.
        if operating, !cardsShown, ticks % 120 == 0, CACurrentMediaTime() - lastStep > 60 { log("run went quiet"); operating = false; goo.reachGoal = nil }
        // Settled, it doesn't need every frame the display can give; everything counted in ticks slows down with it.
        let wantedRate: Float = goo.mode == .grabbed || goo.mode == .free || moving > 0 || glide != nil ? 120 : 60
        if link.preferredFrameRateRange.preferred != wantedRate {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: wantedRate)
        }
        updateClickThrough()
        updateOrder()

        if ticks % 120 == 0 && !trusted {
            trusted = AXIsProcessTrusted()
            if trusted {
                log("accessibility trusted=true")
                web.evaluateJavaScript("setCanMove(true)")
                makeRoom(animated: true)
            }
        }
        // One question at a time: the screen is asked for as soon as accessibility is settled, whatever window it sits on.
        if ticks % 120 == 0 && !canCapture {
            canCapture = CGPreflightScreenCaptureAccess()
            if canCapture {
                log("screen capture trusted=true")
                web.evaluateJavaScript("setCanRead(true)")
            } else if trusted && !captureAsked {
                captureAsked = true
                log("screen capture trusted=false")
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }

    func targetRefreshDue() -> Bool {
        NSEvent.pressedMouseButtons != 0 || moving > 0 || ticks % 12 == 0 || goo.mode == .grabbed
    }

    func followScreen() {
        let point: V
        switch goo.mode {
        case .grabbed: point = mouse()  // the pointer leads: otherwise the screen's own bounds would stop it at the edge
        case .free: point = goo.c
        default: point = target.map { V($0.frame.maxX - 1, $0.frame.midY) } ?? goo.c
        }
        guard let primary = NSScreen.screens.first?.frame else { return }
        let ns = NSPoint(x: point.x, y: primary.maxY - point.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(ns) }), screen.frame != gooPanel.frame {
            setScreen(screen)
        }
    }

    func updateClickThrough() {
        let m = mouse()
        let onGoo = goo.mode == .grabbed || (m - goo.c).length < goo.radius + 7
        if gooPanel.ignoresMouseEvents == onGoo { gooPanel.ignoresMouseEvents = !onGoo }
        if sideOpen {
            let local = NSPoint(x: m.x - side.frame.minX, y: m.y - ((NSScreen.screens.first?.frame.maxY ?? 0) - side.frame.maxY))
            // While it is working a window the panel may lie over part of it: its own presses have to reach that window.
            let through = (operating && !cardsShown) || (!dragging && !region.contains(local))
            if side.ignoresMouseEvents != through { side.ignoresMouseEvents = through }
        }
    }

    /// Attached: just above WeChat, so other apps cover both. Free: above everything, a pet on the glass.
    func updateOrder() {
        let free = goo.mode == .free || goo.mode == .grabbed
        let level: NSWindow.Level = free ? .floating : .normal
        if gooPanel.level != level {
            gooPanel.level = level
            gooPanel.collectionBehavior = free ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
            if free { gooPanel.orderFront(nil) }
        }
    }

    func showMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let pet = goo.mode == .free || goo.mode == .grabbed
        let name = appName.isEmpty ? "窗口" : appName
        let toggle = NSMenuItem(title: pet ? "粘回\(name)" : "从\(name)上扒下来", action: #selector(toggleStick), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !pet || target != nil
        menu.addItem(toggle)
        let shortcut = NSMenuItem(title: "随时叫它：⌃⌥T", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())
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
        let quit = NSMenuItem(title: "退出 Tako", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func toggleStick() {
        if goo.mode == .free || goo.mode == .grabbed {
            if let edge = target?.frame.maxX { goo.stick(to: edge, window: target?.id) }
        } else {
            goo.tearOff(velocity: V(190, -240), reason: "menu")
        }
    }

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
