// Making room: moving or narrowing the window so the panel fits beside it, always putting it back unless the owner moved it,
// and writing it down so that even a crash can't strand it.
import ApplicationServices
import AppKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension Controller {
    // MARK: making room

    func axWindow(pid wanted: pid_t? = nil, frame given: CGRect? = nil, id: Int? = nil) -> AXUIElement? {
        guard let frame = given ?? target?.frame else { return nil }
        let app = AXUIElementCreateApplication(wanted ?? pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        // Two windows of one app can lie exactly on top of each other: the id decides where it can be had.
        if let id, let exact = windows.first(where: { var number: CGWindowID = 0; return _AXUIElementGetWindow($0, &number) == .success && Int(number) == id }) { return exact }
        for window in windows {
            var position: CFTypeRef?, extent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &extent) == .success else { continue }
            var origin = CGPoint.zero, dimension = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
            if abs(origin.x - frame.minX) < 2 && abs(origin.y - frame.minY) < 2 && abs(dimension.width - frame.width) < 2 {
                return window
            }
        }
        return nil
    }

    func setWindow(x: CGFloat, width: CGFloat? = nil) {
        guard let window = axWindow(), let frame = target?.frame else { return }
        var point = CGPoint(x: x, y: frame.minY)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if result != .success { log("move failed \(result.rawValue)") }
        if let width {
            var extent = CGSize(width: width, height: frame.height)
            if let value = AXValueCreate(.cgSize, &extent) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        }
        expectedX = x
        expectedWidth = width ?? frame.width
        ownMoveAt = CACurrentMediaTime()
        recordMoved()
        moving = 20
        refresh()
    }

    /// Right after we set a window it may settle somewhere else (its own minimum width, say): that is still our doing, not the owner's.
    func noteAnswer(_ rect: CGRect) {
        if CACurrentMediaTime() - ownMoveAt < 0.6 {
            expectedX = rect.minX
            expectedWidth = rect.width
            recordMoved()
        } else if NSEvent.pressedMouseButtons == 0 {
            resettle = true
        }
    }

    func stillWherePut(_ frame: CGRect) -> Bool { abs(frame.minX - expectedX) < 2 && abs(frame.width - expectedWidth) < 2 }

    /// The owner made the window fill the screen while the panel is open (the green button, a window manager).
    func shareScreen() {
        guard sideOpen, let frame = target?.frame, let visible = visibleFrame(of: frame),
              frame.width + min(wanted, sidePanelWidth) > visible.width + 1 else { return }
        // The owner has just asked for native full screen: don't pull it back out. The panel steps aside until they call it.
        if let window = axWindow(), isFullScreen(window) { closeSide(); return }
        makeRoom(animated: false)
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success && value as? Bool == true
    }

    func axFrame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &extent) == .success else { return nil }
        var origin = CGPoint.zero, dimension = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
        return CGRect(origin: origin, size: dimension)
    }

    func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, dimension = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &dimension) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    /// Native full screen is a Space of its own: nothing can resize the window there or sit beside it. So the panel
    /// brings it out to fill the desktop with the panel, and closing the panel sends it back in.
    func leaveFullScreen(_ window: AXUIElement) {
        log("leaving full screen for the panel")
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        settleOut(of: window, last: nil, left: 40)
    }

    func settleOut(of window: AXUIElement, last: CGRect?, left: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let now = self.axFrame(window)
            if left > 0, self.isFullScreen(window) || now == nil || now != last {
                self.settleOut(of: window, last: now, left: left - 1)
                return
            }
            guard self.sideOpen else {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
                return
            }
            guard let now, !self.isFullScreen(window), let primary = NSScreen.screens.first?.frame, let visible = self.visibleFrame(of: now) else { return }
            self.fullHome = now
            self.homeX = visible.minX
            self.homeWidth = visible.width
            let shared = CGRect(x: visible.minX, y: primary.maxY - visible.maxY, width: visible.width - min(self.wanted, sidePanelWidth), height: visible.height)
            self.setFrame(window, shared)
            self.expectedX = shared.minX
            self.expectedWidth = shared.width
            self.ownMoveAt = CACurrentMediaTime()
            self.recordMoved()
            self.moving = 20
            self.refresh()
            self.side.makeKeyAndOrderFront(nil)
            self.scan()
            self.placeSide()
            self.enchant.sync()
        }
    }

    /// Back to where full screen had it: the frame it will return to when the owner leaves full screen, and then in.
    func returnToFullScreen(_ full: CGRect) {
        fullHome = nil
        homeX = nil
        guard let frame = target?.frame, stillWherePut(frame), let window = axWindow() else { recordMoved(); return }
        setFrame(window, full)
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        recordMoved()
    }

    /// Slides the window left, and if it fills the screen, narrows it too: the two share the screen rather than overlap.
    func makeRoom(animated: Bool) {
        guard sideOpen, trusted, let frame = target?.frame, let visible = visibleFrame(of: frame) else { return }
        if let window = axWindow(), isFullScreen(window) { leaveFullScreen(window); return }
        if homeX != nil && !stillWherePut(frame) { homeX = nil }
        let fromX = homeX ?? frame.minX, fromWidth = homeX == nil ? frame.width : homeWidth
        let lacking = min(wanted, sidePanelWidth) - (visible.maxX - (fromX + fromWidth))
        var x = fromX, width = fromWidth
        if lacking > 0 {
            x = min(fromX, max(visible.minX, fromX - lacking))
            let short = lacking - (fromX - x)
            if short > 0 { width = max(min(fromWidth, minimumSharedWidth), fromWidth - short) }
        }
        guard abs(x - frame.minX) >= 1 || abs(width - frame.width) >= 1 else { return }
        if homeX == nil { homeX = frame.minX; homeWidth = frame.width; log("making room: \(frame.minX),\(frame.width) to \(x),\(width)") }
        // Resizing can be slow in a heavy app, so only a slide is animated.
        if animated && abs(width - frame.width) < 1 {
            expectedX = frame.minX
            expectedWidth = frame.width
            glide = (frame.minX, x, 0)
        } else {
            glide = nil
            setWindow(x: x, width: width)
        }
    }

    func moveBack() {
        // The window is away (minimized, another Space): the debt stands until it is back.
        guard target != nil else { return }
        if let full = fullHome { returnToFullScreen(full); return }
        defer { homeX = nil; recordMoved() }
        guard let home = homeX, let frame = target?.frame else { return }
        // The owner moved it meanwhile: the new place is theirs, so leave it there.
        guard stillWherePut(frame) else { log("left where the owner put it"); return }
        log("moved back to \(home),\(homeWidth)")
        if abs(frame.width - homeWidth) >= 1 {
            glide = nil
            setWindow(x: home, width: homeWidth)
        } else {
            glide = (frame.minX, home, 0)
        }
    }

    func moveBackNow() {
        if let full = fullHome { returnToFullScreen(full); return }
        guard let home = homeX, let frame = target?.frame, stillWherePut(frame) else { return }
        glide = nil
        setWindow(x: home, width: homeWidth)
    }

    /// Written down each time a window is moved, so that even a crash can't strand it: the next start puts it back.
    var movedFile: URL { takoHome.appendingPathComponent("moved.json") }

    func recordMoved() {
        guard let home = homeX, let id = target?.id else { try? FileManager.default.removeItem(at: movedFile); return }
        var note: [String: Any] = ["id": id, "pid": Int(pid), "home": Double(fullHome?.minX ?? home), "homeWidth": Double(fullHome?.width ?? homeWidth), "expected": Double(expectedX), "expectedWidth": Double(expectedWidth)]
        if let full = fullHome { note["homeY"] = Double(full.minY); note["homeHeight"] = Double(full.height) }
        try? JSONSerialization.data(withJSONObject: note).write(to: movedFile)
    }

    func restoreMoved() {
        guard let data = try? Data(contentsOf: movedFile), let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = note["id"] as? Int, let owner = note["pid"] as? Int, let home = note["home"] as? Double, let expected = note["expected"] as? Double else { return }
        try? FileManager.default.removeItem(at: movedFile)
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first,
              (info[kCGWindowOwnerPID as String] as? Int) == owner, let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw), abs(rect.minX - expected) < 2,
              abs(rect.width - (note["expectedWidth"] as? Double ?? rect.width)) < 2,
              let window = axWindow(pid: pid_t(owner), frame: rect) else { return }
        setFrame(window, CGRect(x: home, y: note["homeY"] as? Double ?? rect.minY, width: note["homeWidth"] as? Double ?? rect.width, height: note["homeHeight"] as? Double ?? rect.height))
        log("moved a window back after an unclean exit")
    }

    func stepGlide() {
        guard let current = glide else { return }
        let step = current.step + 1, steps = 18
        let t = 1 - pow(1 - CGFloat(step) / CGFloat(steps), 3)
        setWindow(x: current.from + (current.to - current.from) * t)
        glide = step >= steps ? nil : (current.from, current.to, step)
    }
}
