// The side window: the web page beside the window, and everything the page says to the app.
import AppKit
import WebKit

let sidePanelWidth: CGFloat = 720
let minimumWidth: CGFloat = 280
let minimumSharedWidth: CGFloat = 420   // a window sharing the screen with the panel never gets narrower than this
let widthKey = "sideWidth"
let modeKey = "gooMode"

final class SideWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    // Left to itself AppKit pushes a panel down out of the menu bar, and the ink would no longer sit on the window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension Controller: WKScriptMessageHandler, WKNavigationDelegate {
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
        updater.panelLoaded()
        sentGeometry = ""
        placeSide()
        sampleSkin()
        // A page that has just loaded knows nothing: after a backend restart it is a new server too.
        if sideOpen { web.evaluateJavaScript("setOpen(true)") }
        let onWindow = goo.mode == .attached || goo.mode == .open
        setWatching(onWindow)
        if onWindow, let id = target?.id {
            lastReported = ""
            reportStuck(title: currentTitle(id: id))
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let rect = body["region"] as? [Double], rect.count == 4 {
            region = NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        if let value = body["dragging"] as? Bool { dragging = value }
        if let value = body["cards"] as? Bool { cardsShown = value }
        if let value = body["width"] as? Double { UserDefaults.standard.set(value, forKey: widthKey) }
        if let text = body["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let value = body["goo"] as? String { goo.state = value; enchant.setMood(value) }
        if body["done"] != nil { goo.celebrate() }
        if body["oops"] != nil { goo.fumble() }
        if let value = body["cardWidth"] as? Double { cardWidth = CGFloat(value); enchant.sync() }
        if let path = body["openFile"] as? String { openFile(path) }
        if body["pickFiles"] != nil { pickFiles() }
        if let action = body["update"] as? String { updater.act(action) }
        if let value = body["statistics"] as? Bool { statistics = value }
        if let path = body["revealFile"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        if let link = body["openURL"] as? String, let target = URL(string: link), ["http", "https"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
        if let value = body["pop"] as? Double { goo.pop = CGFloat(value); goo.kick(CGFloat(value) * 90) }
        if let value = body["wanted"] as? Double {
            wanted = value
            if sideOpen && dragging { makeRoom(animated: false) }
        }
        if let open = body["open"] as? Bool {
            sideOpen = open
            enchant.sync()
            if open {
                // It only speaks while stuck on, so an opening side window always has a window to sit on.
                if goo.mode == .attached { goo.mode = .open }
                side.ignoresMouseEvents = false
                side.makeKeyAndOrderFront(nil)
                if let id = target?.id { side.order(.above, relativeTo: id) }
                if enchant.panel.isVisible { enchant.panel.order(.above, relativeTo: side.windowNumber) }
                gooPanel.order(.above, relativeTo: enchant.panel.isVisible ? enchant.panel.windowNumber : side.windowNumber)
                makeRoom(animated: true)
                sampleSkin()
            } else {
                if goo.mode == .open { goo.mode = .attached }
                moveBack()
                side.ignoresMouseEvents = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, !self.sideOpen else { return }
                    self.side.orderOut(nil)
                }
            }
        }
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
