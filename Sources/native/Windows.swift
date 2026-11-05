// Which window it is on: following it, finding it again, and keeping the panels in order above it.
import AppKit

// It sticks to any ordinary window except these.
let blockedOwners: Set<String> = ["Tako", "TAKO", "universalAccessAuthWarn", "Dock", "Window Server", "程序坞", "控制中心", "通知中心", "UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent"]
let weChatBundle = "com.tencent.xinWeChat"

extension Controller {
    func keepAbove(_ found: (id: Int, frame: CGRect), in ids: [Int]) {
        // A click on the window brings it forward on the press, not the release: catching up only after it let the goo blink behind it.
        guard !dragging else { return }
        var below = found.id
        if sideOpen {
            let s = ids.firstIndex(of: side.windowNumber), t = ids.firstIndex(of: found.id)
            // In use it may float up; once the owner has gone off to another app it goes back down with its window.
            let inUse = side.isKeyWindow && (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || side.frame.contains(NSEvent.mouseLocation))
            if !(s != nil && t != nil && s! + 1 == t!) && !inUse { side.order(.above, relativeTo: found.id) }
            below = side.windowNumber
        }
        guard goo.mode != .free && goo.mode != .grabbed else { return }
        // from the back: the window, the side window, its ink, the goo
        let ink = ids.firstIndex(of: enchant.panel.windowNumber), under = ids.firstIndex(of: below)
        let inkMoved = enchant.panel.isVisible && !(ink != nil && under != nil && ink! < under!)
        if inkMoved { enchant.panel.order(.above, relativeTo: below) }
        let top = enchant.panel.isVisible ? enchant.panel.windowNumber : below
        let g = ids.firstIndex(of: gooPanel.windowNumber), t = ids.firstIndex(of: top)
        // The ink just moved: the order read before that says nothing about the goo any more.
        if inkMoved || !(g != nil && t != nil && g! < t!) { gooPanel.order(.above, relativeTo: top) }
    }

    /// Only the windows above its own, which is cheap enough to ask every frame while a click or an app switch may be reordering them.
    func keepStacked() {
        guard let current = target, goo.mode == .attached || goo.mode == .open,
              let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(current.id)) as? [[String: Any]] else { return }
        let ids = above.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowNumber as String] as? Int }
        keepAbove(current, in: ids + [current.id])
    }

    // MARK: the window it is on

    func refresh() {
        moving = max(0, moving - 1)
        guard let current = target else { return }
        if moving == 0 && resettle && NSEvent.pressedMouseButtons == 0 { resettle = false; shareScreen() }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(current.id)) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else {
            windowGone()
            return
        }
        if rect != current.frame {
            noteWindowMove(dx: rect.minX - current.frame.minX)
            target = (current.id, rect)
            noteAnswer(rect)
            moving = 20
            placeSide()
            enchant.sync()
        }
    }

    /// While it stands on a window, that window's position matters every frame the mouse is down.
    func refreshStanding() {
        guard let id = goo.standingID, NSEvent.pressedMouseButtons != 0 || ticks % 6 == 0,
              let index = platforms.firstIndex(where: { $0.id == id }),
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else { return }
        platforms[index].frame = rect
    }

    func windowGone() {
        let gone = target?.id
        log("window gone")
        lostID = gone
        lostBundle = bundle
        target = nil
        side.orderOut(nil)
        forgetMarks()
        enchant.hide()
        guard goo.mode == .attached || goo.mode == .open else { return }
        // Off this Space or minimized, it waits with the window. Really closed, it has nothing to hold: it falls.
        let exists = { gone.flatMap { CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID($0)) as? [[String: Any]] }?.isEmpty == false }
        if exists() {
            gooPanel.orderOut(nil)
        } else {
            // A window changing Spaces (in or out of full screen) is missing from the list for a moment: only a window still gone is closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.target == nil, self.lostID == gone, self.goo.mode == .attached || self.goo.mode == .open, !exists() else { return }
                self.goo.tearOff(velocity: V(40, -180), reason: "window closed")
                self.gooPanel.orderFront(nil)
            }
        }
    }

    /// The window to drop it on: only near its right edge, where it lives (Joe 2026-11-04: over the middle of a window it is just being carried, or set down as a pet).
    /// The one it is already feeling for keeps it over a wider band, so the feelers don't flicker at the boundary. A window in front hides the ones behind it.
    func windowNear(_ c: V, keeping held: Int? = nil) -> (id: Int, frame: CGRect)? {
        for w in platforms where c.y > w.frame.minY - 8 && c.y < w.frame.maxY + 8 {
            let (inside, outside): (CGFloat, CGFloat) = w.id == held ? (110, 116) : (90, 96)  // Joe 2026-11-04: 56/64 was a bit narrow
            let past = c.x - w.frame.maxX
            if past >= -inside && past <= outside { return w.sticky ? (w.id, w.frame) : nil }
            if w.frame.contains(CGPoint(x: c.x, y: c.y)) { return nil }
        }
        return nil
    }

    /// Stuck onto this window: it becomes the one it serves.
    func adopt(_ id: Int, contact: V?) {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first,
              let raw = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { return }
        let changed = (target?.id ?? lostID) != id
        // Moved the old window to make room: it goes back before the goo leaves it.
        if changed { moveBackNow(); homeX = nil; glide = nil; forgetMarks() }
        target = (id, rect)
        pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
        appName = info[kCGWindowOwnerName as String] as? String ?? ""
        bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? appName
        neverStuck = false
        if changed { lastBand = 0 }
        placeSide()
        reportStuck(title: info[kCGWindowName as String] as? String ?? "")
        sampleSkin()
        enchant.attach(contact: contact ?? V(rect.maxX, rect.minY + 66))
        log("stuck on \(bundle)")
    }

    /// Keeps track of every window; finds its way back to the one it was on when that one comes back.
    func scan() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let ordinary = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        platforms = ordinary.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  number != side.windowNumber, number != gooPanel.windowNumber, number != enchant.panel.windowNumber,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw),
                  rect.width > 200, rect.height > 80 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            // Another Tako's ink and panels (a second copy, as in a self-test) are nothing to stand on and hide nothing behind them. This one's own test window still counts.
            let process = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            guard !(["Tako", "TAKO"].contains(owner) && process != ProcessInfo.processInfo.processIdentifier) else { return nil }
            return (number, rect, !blockedOwners.contains(owner) && rect.width > 300 && rect.height > 200)
        }
        if let current = target {
            if let now = platforms.first(where: { $0.id == current.id }) {
                if now.frame != current.frame { target = (current.id, now.frame); noteAnswer(now.frame); placeSide(); enchant.sync() }
                keepAbove(target!, in: ordinary.compactMap { $0[kCGWindowNumber as String] as? Int })
            }
            return
        }
        // Nothing to hold yet: the window it lost if that is back, a window of the same app, or at first WeChat.
        var best: (id: Int, frame: CGRect)?
        var bestInfo: [String: Any]?
        for info in ordinary {
            guard let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), rect.width > 300, rect.height > 200,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int else { continue }
            if number == lostID { best = (number, rect); bestInfo = info; break }
            guard let app = NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier else { continue }
            guard app == (lostBundle.isEmpty ? weChatBundle : lostBundle) else { continue }
            if best == nil || rect.width * rect.height > best!.frame.width * best!.frame.height {
                best = (number, rect)
                bestInfo = info
            }
        }
        guard let found = best, let info = bestInfo else { return }
        log(found.id == lostID ? "window back" : "found a window")
        target = found
        pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
        appName = info[kCGWindowOwnerName as String] as? String ?? ""
        bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? appName
        placeSide()
        if goo.mode != .free && goo.mode != .grabbed {
            gooPanel.orderFront(nil)
            reportStuck(title: info[kCGWindowName as String] as? String ?? "")
            sampleSkin()
            enchant.attach(contact: nil)
        }
    }

    /// Flush with the window's right edge and the same height. With too little screen to the
    /// right, the side window keeps its minimum width and overlaps the window by the difference.
    func placeSide() {
        guard let frame = target?.frame, let primary = NSScreen.screens.first,
              let visible = visibleFrame(of: frame) else { return }
        let room = visible.maxX - frame.maxX
        let x = room >= minimumWidth ? frame.maxX : visible.maxX - minimumWidth
        sideX = x
        let next = NSRect(x: x, y: primary.frame.maxY - frame.maxY, width: sidePanelWidth, height: frame.height)
        if next.size == side.frame.size {
            side.setFrameOrigin(next.origin)
        } else {
            side.setFrame(next, display: sideOpen)
        }
        let geometry = "\(frame.maxX - x),\(room)"
        if loaded && geometry != sentGeometry {
            sentGeometry = geometry
            web.evaluateJavaScript("setGeometry(\(geometry))")
        }
    }

    func visibleFrame(of frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let middle = NSPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        return (NSScreen.screens.first { $0.frame.contains(middle) } ?? primary).visibleFrame
    }

    /// Shaking the window hard throws it off.
    func noteWindowMove(dx: CGFloat) {
        let now = CACurrentMediaTime()
        guard abs(dx) > 2, glide == nil else { return }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if sign != lastWindowSign {
            if lastWindowSign != 0 { windowShakes.append(now) }
            lastWindowSign = sign
        }
        windowShakes.removeAll { now - $0 > 1.1 }
        if windowShakes.count >= 4, goo.mode == .attached || goo.mode == .open {
            windowShakes.removeAll()
            goo.makeDizzy(2.6, "window shaken")
            goo.tearOff(velocity: V(sign * 260, -320), reason: "window shaken")
        }
    }
}
