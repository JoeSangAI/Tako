// The side window: the web page beside the window, and everything the page says to the app.
import AppKit
import WebKit

let sidePanelWidth: CGFloat = 720
let minimumWidth: CGFloat = 280
let minimumSharedWidth: CGFloat = 420   // a window sharing the screen with the panel never gets narrower than this
let widthKey = "sideWidth"
let modeKey = "gooMode"
let learnedKey = "learned"

final class SideWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    // Left to itself AppKit pushes a panel down out of the menu bar, and the ink would no longer sit on the window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension Controller: WKScriptMessageHandler, WKNavigationDelegate {
    /// `show: false`: the desktop conversation, with its panel left closed (an answer in the bubble, `sayAside`).
    func openDesktop(show: Bool = true, then: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
        post(path: "/desktop", body: [:]) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else { failed?(); return }
                self.panelPlace = .floating; self.setWatching(false)
                if show { self.showDesktopPanel() }
                then?()
            }
        }
    }

    /// What the owner said with the speaking key, or typed in its bubble: the panel opens where a click on the goo opens it
    /// (on the window it is stuck to, else beside it on the desktop; one already open stays the one they are looking at),
    /// and the words go out by the panel's own send, so they are its newest line and Tako's answer follows them there.
    func sayInPanel(_ text: String, failed: @escaping () -> Void) {
        let send = { [weak self] in
            guard let self else { return }
            guard self.loaded, let data = try? JSONSerialization.data(withJSONObject: [text]), let words = String(data: data, encoding: .utf8) else {
                self.post(path: "/ask", body: ["text": text]); return   // no page to show it in yet: still not lost
            }
            self.web.evaluateJavaScript("sayFromKey(\(words)[0])")
        }
        if sideOpen { send(); return }
        if goo.mode == .attached || goo.mode == .open, target != nil { web.evaluateJavaScript("setOpen(true)"); send(); return }
        openDesktop(then: send, failed: failed)
    }

    /// On the desktop with the panel closed, the answer comes back in the speaking bubble instead of the panel.
    var answersAside: Bool { ReplyLayout.answersAside(panelOpen: sideOpen, stuck: (goo.mode == .attached || goo.mode == .open) && target != nil) }

    /// The same send into the desktop conversation, the panel left closed. The page reads this conversation's own state for
    /// the bubble (side.html `asideNews`) and opens the panel itself for anything the owner has to act on.
    func sayAside(_ text: String, failed: @escaping () -> Void) {
        openDesktop(show: false, then: { [weak self] in
            guard let self else { return }
            guard self.loaded, let data = try? JSONSerialization.data(withJSONObject: [text]), let words = String(data: data, encoding: .utf8) else {
                self.post(path: "/ask", body: ["text": text]); return
            }
            self.web.evaluateJavaScript("sayFromKey(\(words)[0], true)")
        }, failed: failed)
    }

    /// Opening a to-do from its title, bubble or notification: the owner pressed it, so the window or chat it belongs to comes up,
    /// with its conversation in the panel; with no window of its own, the conversation opens beside the goo. It stays pending.
    func lookAtEntrusted(_ id: String, finished: (() -> Void)? = nil) {
        post(path: "/entrusted/look", body: ["id": id]) { [weak self] data in
            DispatchQueue.main.async {
                defer { finished?() }
                guard let self, let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else { return }
                self.entrusted.withdrawNotification(id)
                if self.entrusted.offerID == id { self.entrusted.offerID = nil; self.goo.takeHandBack("seen") }
                _ = self.attention.takeReturned("entrusted")
                let key = result["key"] as? String ?? "", window = result["window"] as? String ?? ""
                Task { @MainActor in
                    if !window.isEmpty, await self.resolve(window) != nil { self.goTo(window, chat: result["chat"] as? String ?? "", openPanel: true) }
                    else { self.openConversation(key) }
                }
                self.entrusted.poll()
            }
        }
    }

    func openConversation(_ key: String) {
        guard !key.isEmpty else { openHere(); return }
        post(path: "/conversation/open", body: ["key": key]) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true else { return }
                self.panelPlace = .floating; self.setWatching(false); self.showDesktopPanel()
            }
        }
    }

    func showDesktopPanel() {
        placeSide()
        web.evaluateJavaScript("openFresh()")
    }

    /// The body on the open desktop panel: it sits at its corner as on a window's panel, goes along when the panel is
    /// dragged, and does nothing of its own meanwhile (Goo `seat`). Closed, it is a pet again.
    func seatGoo() {
        guard goo != nil, side != nil, let primary = NSScreen.screens.first else { return }
        guard desktopPanel, sideOpen, goo.mode == .free || goo.mode == .grabbed else { goo.seat = nil; return }
        let top = primary.frame.maxY - side.frame.maxY
        let at = PanelPlace.seat(of: CGRect(x: side.frame.minX, y: top, width: side.frame.width, height: side.frame.height), bar: barHeight)
        goo.seat = V(at.x, at.y)
    }

    /// While the owner holds the desktop panel's header (side.html `moveStart`): the panel goes with the pointer, kept on
    /// the screen it is over, and the body with it; let go, it stays there for the rest of this run (not saved).
    func movePanel() {
        guard let grip = panelGrip else { return }
        guard desktopPanel, sideOpen, NSEvent.pressedMouseButtons & 1 != 0, let primary = NSScreen.screens.first else {
            panelGrip = nil
            if desktopPanel, sideOpen, let at = desktopAt { desktopLast = at }
            return
        }
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main ?? primary
        let vis = screen.visibleFrame
        let visible = CGRect(x: vis.minX, y: primary.frame.maxY - vis.maxY, width: vis.width, height: vis.height)
        let wanted = CGRect(x: m.x - grip.x, y: (primary.frame.maxY - m.y) - grip.y, width: side.frame.width, height: side.frame.height)
        let frame = PanelPlace.clamp(wanted, to: visible)
        guard frame.origin != desktopAt else { return }
        desktopAt = frame.origin
        sideX = frame.minX
        side.setFrameOrigin(NSPoint(x: frame.minX, y: primary.frame.maxY - frame.maxY))
        seatGoo()
        tellOrigin()
    }

    /// Whether another app's window lies over the open desktop panel: a double click on the body then brings it back up.
    func desktopPanelCovered() -> Bool {
        guard desktopPanel, sideOpen, let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(side.windowNumber)) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let frame = CGRect(x: side.frame.minX, y: primary.frame.maxY - side.frame.maxY, width: side.frame.width, height: side.frame.height)
        return above.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { return false }
            return rect.intersects(frame)
        }
    }

    func raiseDesktopPanel() {
        side.makeKeyAndOrderFront(nil)
        side.orderFrontRegardless()
        side.makeFirstResponder(web)
        goo.kick(30)
    }

    /// Where the body is on the panel's page, for the card to grow out of and go back into (side.html `setOrigin`). Told when
    /// the panel is placed and, from the frame loop, when the body has moved; the frame loop runs only while something moves.
    func tellOrigin() {
        guard loaded, side != nil, let primary = NSScreen.screens.first else { return }
        let x = Int(goo.c.x - side.frame.minX), y = Int(side.frame.maxY - (primary.frame.maxY - goo.c.y))
        let key = "\(x / 4),\(y / 4)"
        guard key != toldOrigin else { return }
        toldOrigin = key
        web.evaluateJavaScript("setOrigin(\(x),\(y))")
    }

    // MARK: side window

    func toggleSide() { web.evaluateJavaScript("setOpen(\(!sideOpen))") }
    func closeSide() { if sideOpen { web.evaluateJavaScript("setOpen(false)") } }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("panel loaded")
        loaded = true
        let saved = UserDefaults.standard.double(forKey: widthKey)
        if saved > 0 { web.evaluateJavaScript("setWidth(\(saved))") }
        web.evaluateJavaScript("setCanMove(\(trusted))")
        web.evaluateJavaScript("setCanRead(\(CGPreflightScreenCaptureAccess()))")
        tellPermissions()
        entrusted.tellNotification()
        entrusted.tellHeldItems()
        tellLearned()
        updater.panelLoaded()
        sentGeometry = ""
        placeSide()
        sampleSkin()
        // A page that has just loaded knows nothing: after a backend restart it is a new server too.
        if sideOpen { web.evaluateJavaScript("setOpen(true)") }
        let onWindow = !desktopPanel && (goo.mode == .attached || goo.mode == .open)
        setWatching(onWindow)
        if onWindow, let id = target?.id {
            lastReported = ""
            reportStuck(title: currentTitle(id: id))
        }
        if !onWindow { post(path: "/desktop", body: [:]) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let rect = body["region"] as? [Double], rect.count == 4 {
            region = NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        if let value = body["dragging"] as? Bool { dragging = value }
        // The desktop panel's header held: where the pointer holds it, for `movePanel` on each frame until let go.
        if body["moveStart"] != nil, desktopPanel, sideOpen {
            let m = NSEvent.mouseLocation
            panelGrip = CGPoint(x: m.x - side.frame.minX, y: side.frame.maxY - m.y)
            wakeLoop("panel")
        }
        if let value = body["cards"] as? Bool { cardsShown = value }
        if let value = body["width"] as? Double { UserDefaults.standard.set(value, forKey: widthKey) }
        if let text = body["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let news = body["aside"] as? [String: Any] { speaking.aside(news) }
        if let value = body["goo"] as? String { goo.state = value; enchant.setMood(value); if value != "idle" { teaching.hide() } }
        if let value = body["act"] as? String { goo.act = value }
        // the service the owner's key is for: a DeepSeek key puts the whale on, if the outfit is left to Tako (a look only)
        if let value = body["service"] as? String, !selfTest, value != Outfit.service {
            Outfit.service = value
            goo.costume.checkedAt = -100
        }
        if body["done"] != nil { goo.celebrate(); teaching.completed() }
        if body["oops"] != nil { goo.fumble() }
        if let value = body["cardWidth"] as? Double { cardWidth = CGFloat(value); enchant.sync(); if desktopPanel { placeSide() } }
        if let path = body["openFile"] as? String {
            var folder: ObjCBool = false
            // Tako's own folder opens in Finder; a file goes through the same check as any other.
            if FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) } else { openFile(path) }
        }
        if let spec = body["goTo"] as? String { goTo(spec, chat: body["chat"] as? String ?? "") }
        if body["pickFiles"] != nil { pickFiles() }
        if body["connectSources"] != nil { systemSources.connect() }  // the owner's own tap: only now may the system ask
        if let now = body["chooseFolder"] as? String { chooseFolder(from: now) }
        if let action = body["update"] as? String { updater.act(action) }
        if let value = body["statistics"] as? Bool { statistics = value }
        if let path = body["revealFile"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        if let link = body["openURL"] as? String, let target = URL(string: link), ["http", "https"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
        // Only these two pages: nothing the page says can open anything else in System Settings.
        if let pane = body["settings"] as? String {
            if pane == "notifications", let page = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(page) }
            else if pane == "screen" { openScreenRecordingList() }
            else if let name = ["accessibility": "Privacy_Accessibility", "screen": "Privacy_ScreenCapture", "files": "Privacy_FilesAndFolders"][pane],
                    let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") { NSWorkspace.shared.open(page) }
        }
        if let action = body["heldAction"] as? String, ["done", "cancel", "look", "later", "restore"].contains(action), let id = body["heldID"] as? String { entrusted.respondToTap(id, action: action) }
        if let n = body["unpoint"] as? Int { unpoint(n, tellPanel: false) }
        if body["pointsSent"] != nil { pointsSent() }
        if let which = body["repair"] { if which as? String == "screen" { repairScreen() } else { repairAccessibility() } }
        if body["relaunch"] != nil { relaunch() }
        // A step Tako can't work without (no model yet, a switch off): its card is put in front of the owner once, where the goo is.
        if body["needsSetup"] != nil, !sideOpen, !selfTest { openHere() }
        // The model just became ready: the next step may be a switch now.
        if body["nextStep"] != nil { teaching.nextStep(lines: false) }
        if let name = body["learned"] as? String { learn(name) }
        if let value = body["pop"] as? Double { goo.pop = CGFloat(value); goo.kick(CGFloat(value) * 90) }
        if let value = body["wanted"] as? Double {
            wanted = value
            if sideOpen && dragging { makeRoom(animated: false) }
        }
        if let open = body["open"] as? Bool {
            if sideOpen && !open { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.teaching.nextStep() } }  // a free moment
            sideOpen = open
            enchant.sync()
            // The body puts its weight into it: a squeeze as the card leaves it or comes back, eyes on the card.
            if let primary = NSScreen.screens.first {
                let toward = V(side.frame.midX - goo.c.x, (primary.frame.maxY - side.frame.midY) - goo.c.y)
                goo.kick(open ? 42 : 28)
                if toward.length > 1 { goo.lookAt = toward.unit; goo.lookTime = open ? 0.6 : 0.35 }
            }
            if open {
                speaking.endReply()   // the panel has it now, with the answer in view
                // It only speaks while stuck on, so an opening side window always has a window to sit on.
                if !desktopPanel, goo.mode == .attached { goo.mode = .open }
                side.ignoresMouseEvents = false
                // The keyboard is the page's: the web view the window's first responder, not only the window key.
                if openQuietly { side.orderFront(nil) } else { side.makeKeyAndOrderFront(nil); side.makeFirstResponder(web) }
                openQuietly = false
                if desktopPanel, let primary = NSScreen.screens.first {
                    // At the ordinary level `makeKeyAndOrderFront` from an app that is not in front leaves it behind the
                    // front app's windows (seen in the isolated run): opened by the owner it comes up in front, once.
                    side.orderFrontRegardless()
                    desktopAt = CGPoint(x: side.frame.minX, y: primary.frame.maxY - side.frame.maxY)
                    seatGoo()
                    log("desktop panel open key=\(side.isKeyWindow ? 1 : 0) responder=\(side.firstResponder === web ? "web" : "other") active=\(NSApp.isActive ? 1 : 0)")
                }
                if !desktopPanel, let id = target?.id { side.order(.above, relativeTo: id) }
                if enchant.panel.isVisible { enchant.panel.order(.above, relativeTo: side.windowNumber) }
                gooPanel.order(.above, relativeTo: enchant.panel.isVisible ? enchant.panel.windowNumber : side.windowNumber)
                if !desktopPanel { makeRoom(animated: true); sampleSkin() }
            } else {
                if goo.mode == .open { goo.mode = .attached }
                if !desktopPanel { moveBack() }
                if desktopPanel, let at = desktopAt { desktopLast = at }   // opened again this run, it is where it was
                desktopAt = nil; panelGrip = nil
                seatGoo()
                let restore = desktopPanel && stuckOn && target != nil
                panelPlace.close(bodyAttached: restore)
                if restore, let id = target?.id {
                    setWatching(true); lastReported = ""; reportStuck(title: currentTitle(id: id))
                }
                side.ignoresMouseEvents = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in   // the card is back in the body (side.html shrink)
                    guard let self, !self.sideOpen else { return }
                    self.side.orderOut(nil)
                }
            }
        }
    }

    /// What the owner has done once and need not be offered again in the empty panel (side.html, "things to try"): names only.
    func learn(_ name: String) {
        if measuring { return }   // a copy being measured leaves the owner's settings alone
        var known = UserDefaults.standard.stringArray(forKey: learnedKey) ?? []
        guard !known.contains(name), !selfTest else { return }
        known.append(name)
        UserDefaults.standard.set(known, forKey: learnedKey)
        tellLearned()
    }

    func tellLearned() {
        guard loaded, let data = try? JSONSerialization.data(withJSONObject: UserDefaults.standard.stringArray(forKey: learnedKey) ?? []),
              let text = String(data: data, encoding: .utf8) else { return }
        guard let catalog = try? JSONSerialization.data(withJSONObject: Teaching.catalog),
              let tips = String(data: catalog, encoding: .utf8) else { return }
        web.evaluateJavaScript("setLearned(\(text), \(tips))")
    }

    /// The panel's page crashed: no message will ever come from it again, so the native side lets go by itself.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("panel page crashed")
        sideOpen = false
        cardsShown = false
        side.orderOut(nil)
        moveBack()
        webView.reload()
    }
}
