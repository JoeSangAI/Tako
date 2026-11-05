// The owner showing Tako what they mean (Joe 2026-11-04). Holding ⌃ on the window it is stuck to, the pointer points:
// dragged across text it selects as the app always would, dragged anywhere else or round in a loop it circles,
// a press circles the one thing under it. A ring is a finger, not a picture: what is pointed at is found right then,
// behind the window (a link's address, an image, a button, a run of text, a file), because the window may scroll before
// they finish their sentence. Everywhere else, and without ⌃, every press goes on to the app as before.
import ApplicationServices
import AppKit

/// What a ring or a line under text stands for, in the panel, the prompt and on the window.
struct Pointed {
    let n: Int
    var rect: CGRect          // on the screen
    var info: [String: Any]   // what goes to the panel and the brain
    var mark: CALayer?
    var began = CACurrentMediaTime()
}

/// One press while ⌃ was held, until it is let go.
struct PointGesture {
    let start: CGPoint
    var points: [CGPoint]
    var moved = false
    var passing = false       // a drag over text, handed on to the app so it selects as it always does
}

/// The thing under one spot, as found through Accessibility.
struct Found {
    var rect: CGRect
    var kind: String          // fixed words: 链接 图片 图片局部 按钮 输入框 文字 文件 条目 区域
    var name = ""
    var text = ""
    var url = ""
}

/// Marks the presses Tako hands on to the app itself, so they pass straight through its own listening.
private let ownPress: Int64 = 0x7A6B6F

private let pointingCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue().onPointer(type, event)
}

extension Controller {
    // MARK: listening

    /// Needs Accessibility, so it starts once that is there. Only presses, drags and scrolls: never a key.
    func installPointing() {
        guard pointTap == nil, trusted, !selfTest else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: pointingCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("pointing tap refused")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pointTap = tap
        log("pointing ready")
    }

    var stuckOn: Bool { goo != nil && (goo.mode == .attached || goo.mode == .open) && target != nil }

    /// ⌃ alone: with ⌘, ⌥ or ⇧ it is some other shortcut.
    func onlyControl(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
    }

    /// On the window it is stuck to, and that window is the one showing there: not a window lying over it.
    func pointsHere(_ at: CGPoint) -> Bool {
        guard stuckOn, trusted, let frame = target?.frame, frame.contains(at) else { return false }
        return openWindows().first { $0.frame.contains(at) }?.id == target?.id
    }

    func onPointer(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let pointTap { CGEvent.tapEnable(tap: pointTap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == ownPress { return pass }
        let at = event.location
        switch type {
        case .scrollWheel:
            // The page moved under the rings: they no longer mark anything, but what they found stays in the panel.
            if target?.frame.contains(at) == true {
                snapshot = nil
                if !pointed.isEmpty { enchant.fadeMarks() }
            }
            return pass
        case .leftMouseDown:
            guard gesture == nil, onlyControl(event.flags), pointsHere(at) else { return pass }
            gesture = PointGesture(start: at, points: [at])
            return nil
        case .leftMouseDragged:
            guard var g = gesture else { return pass }
            g.points.append(at)
            if !g.moved, hypot(at.x - g.start.x, at.y - g.start.y) > 6 {
                g.moved = true
                enchant.hover(nil)
                if Controller.startsOnText(g.start, pid: pid) {
                    // The app selects, as it would without ⌃: its own press where this one began, then the drag without ⌃.
                    g.passing = true
                    post(.leftMouseDown, at: g.start)
                }
            }
            gesture = g
            if g.passing {
                post(.leftMouseDragged, at: at)
                return nil
            }
            if g.moved { enchant.trail(g.points) }
            return nil
        case .leftMouseUp:
            guard let g = gesture else { return pass }
            gesture = nil
            if g.passing {
                post(.leftMouseUp, at: at)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pickSelection(from: g.start, to: at) }
                return nil
            }
            enchant.trail(nil)
            if g.moved {
                let xs = g.points.map(\.x), ys = g.points.map(\.y)
                let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                if box.width > 14 || box.height > 14 { pickRegion(box.insetBy(dx: min(0, (box.width - 24) / 2), dy: min(0, (box.height - 24) / 2))) }
            } else {
                pickSpot(g.start)
            }
            return nil
        default:
            return pass
        }
    }

    /// A press of the app's own, without ⌃: the same thing the owner did, minus the key that makes it Tako's.
    func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: ownPress)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: while ⌃ is held

    /// Every frame: holding ⌃ over the window shows what a press would take, and the goo looks.
    func followPointing() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let m = mouse()
        let on = flags == [.control] && gesture == nil && stuckOn && target?.frame.contains(CGPoint(x: m.x, y: m.y)) == true
        let dragging = gesture != nil && stuckOn
        if !on && !dragging {
            if pointingShown { pointingShown = false; enchant.hover(nil); enchant.aim(at: nil); web.evaluateJavaScript("setAiming(false)") }
            return
        }
        // Tako lends its ink: a tip at the pointer, a bolder edge, and its eyes on what is being pointed at.
        enchant.aim(at: m)
        goo.lookAt = (m - goo.c).unit
        goo.lookTime = 0.15
        if dragging { return }
        if !pointingShown {
            pointingShown = true
            goo.pop = max(goo.pop, 0.8)
            web.evaluateJavaScript("setAiming(true)")
            // Chrome shows Accessibility nothing of the page until asked, and the first press must already find something.
            if let target { Task { await askForAccessibleContent(Win(id: target.id, frame: target.frame, pid: pid, bundle: bundle, app: appName, title: "")) } }
            // While they aim, one picture of the window: reading a ring's words afterwards is then only reading.
            takeSnapshot()
        }
        guard CACurrentMediaTime() - hoverAt > 0.04, !hoverBusy, let frame = target?.frame else { return }
        hoverAt = CACurrentMediaTime()
        hoverBusy = true
        let at = CGPoint(x: m.x, y: m.y), app = pid
        Task.detached {
            let found = Controller.thing(at: at, pid: app, in: frame, deep: false)
            await MainActor.run {
                self.hoverBusy = false
                // A press right here needs no second look: what the outline went round is what it rings.
                self.hovered = (at, found, CACurrentMediaTime())
                guard self.pointingShown else { return }
                // Already ringed: the ink is there, no preview over it.
                let ringed = found.map { f in self.pointed.contains { overlap($0.rect, f.rect) > 0.8 } } ?? false
                self.enchant.hover(ringed ? nil : found?.rect)
            }
        }
    }

    // MARK: finding what is there

    nonisolated static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var found: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
    }

    nonisolated static func words(_ element: AXUIElement, _ name: String) -> String {
        switch value(element, name) {
        case let text as String: return text
        case let text as NSAttributedString: return text.string
        case let url as URL: return url.absoluteString
        default: return ""
        }
    }

    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        // swiftlint:disable:next force_cast
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    nonisolated static func leaf(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    /// Text that the app itself can select: a drag starting here is a selection, not a ring.
    nonisolated static func startsOnText(_ point: CGPoint, pid: pid_t) -> Bool {
        guard let element = leaf(at: point, pid: pid) else { return false }
        return ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(words(element, kAXRoleAttribute))
    }

    /// The text under an element, as the page lays it out, up to a page's worth.
    nonisolated static func text(under element: AXUIElement, depth: Int = 0, into found: inout String) {
        guard found.count < 1500 else { return }
        let role = words(element, kAXRoleAttribute)
        if role == "AXStaticText" {
            found += words(element, kAXValueAttribute)
            return
        }
        guard depth < 5, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children.prefix(80) { text(under: child, depth: depth + 1, into: &found) }
    }

    /// The thing a press here means: the nearest link, image, button, field, paragraph or row, never the whole page.
    /// Not `deep`, it only says what and where (a few questions to the app, for drawing at once); deep, it also gathers the words inside.
    nonisolated static func thing(at point: CGPoint, pid: pid_t, in window: CGRect, deep: Bool = true) -> Found? {
        guard let start = leaf(at: point, pid: pid) else { return nil }
        var chain = [start]
        while chain.count < 8, let up = value(chain.last!, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            let parent = up as! AXUIElement
            if words(parent, kAXRoleAttribute) == "AXWindow" { break }
            chain.append(parent)
        }
        let whole = window.width * window.height
        func fits(_ rect: CGRect?) -> CGRect? {
            guard let rect, rect.width >= 4, rect.height >= 4, rect.width * rect.height < 0.6 * whole else { return nil }
            return rect.intersection(window.insetBy(dx: -2, dy: -2))
        }
        func label(_ element: AXUIElement) -> String {
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                let said = words(element, name).trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty, said.count < 300 { return said }
            }
            guard deep else { return "" }
            var inside = ""
            text(under: element, into: &inside)
            return String(inside.prefix(200))
        }
        for (index, element) in chain.enumerated() {
            let role = words(element, kAXRoleAttribute)
            let url = words(element, "AXURL")
            if url.hasPrefix("file://"), let rect = fits(frame(of: element)) {
                return Found(rect: rect, kind: "文件", name: label(element), url: URL(string: url)?.path ?? url)
            }
            switch role {
            case "AXLink" where index < 4:
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "链接", name: label(element), url: url) }
            case "AXImage":
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "图片", name: label(element), url: url) }
            case "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXMenuItem":
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "按钮", name: label(element)) }
            case "AXTextField", "AXComboBox", "AXSearchField":
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "输入框", name: label(element), text: words(element, kAXValueAttribute)) }
            case "AXTextArea":
                // A document's own text view is the whole page: the line under the pointer is what was meant.
                if let line = line(of: element, at: point) { return line }
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "输入框", name: label(element), text: String(words(element, kAXValueAttribute).prefix(2000))) }
            case "AXStaticText", "AXHeading":
                // A page splits a paragraph at every link and bold word: the paragraph holding it is what was meant.
                var holder = element
                for parent in chain.dropFirst(index + 1).prefix(2) where ["AXGroup", "AXParagraph", "AXListItem", "AXCell", "AXHeading"].contains(words(parent, kAXRoleAttribute)) {
                    if fits(frame(of: parent)) != nil { holder = parent; break }
                }
                var inside = ""
                if deep { text(under: holder, into: &inside) }
                if inside.isEmpty { inside = words(element, kAXValueAttribute) }
                if let rect = fits(frame(of: holder)) ?? fits(frame(of: element)) { return Found(rect: rect, kind: "文字", text: inside) }
            case "AXCell", "AXRow":
                var inside = ""
                if deep { text(under: element, into: &inside) }
                if let rect = fits(frame(of: element)) { return Found(rect: rect, kind: "条目", name: label(element), text: inside, url: url) }
            default:
                continue
            }
        }
        return nil
    }

    /// In a text view: the line under the point, with where it sits.
    nonisolated static func line(of element: AXUIElement, at point: CGPoint) -> Found? {
        var spot = point
        guard let where_ = AXValueCreate(.cgPoint, &spot) else { return nil }
        var found: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXRangeForPosition" as CFString, where_, &found) == .success,
              let range = found as! AXValue?, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var at = CFRange()
        AXValueGetValue(range, .cfRange, &at)
        var number: CFTypeRef?, lineRange: CFTypeRef?, bounds: CFTypeRef?, said: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXLineForIndex" as CFString, at.location as CFNumber, &number) == .success, let number,
              AXUIElementCopyParameterizedAttributeValue(element, "AXRangeForLine" as CFString, number, &lineRange) == .success, let lineRange,
              AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, lineRange, &said) == .success,
              AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString, lineRange, &bounds) == .success, let bounds else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
        let text = (said as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || rect.isEmpty ? nil : Found(rect: rect, kind: "文字", text: text)
    }

    // MARK: picking

    func currentWin() -> Win? {
        guard let target else { return nil }
        return Win(id: target.id, frame: target.frame, pid: pid, bundle: bundle, app: appName, title: currentTitle(id: target.id))
    }

    /// One press: the thing under it, or, where Accessibility sees nothing (WeChat), the patch of one colour it sits on.
    /// The ring goes up at once from what the hover outline already knew; the words inside are gathered behind it.
    func pickSpot(_ at: CGPoint) {
        guard let win = currentWin() else { return }
        Task { @MainActor in
            var quick: Found?
            if let seen = self.hovered, CACurrentMediaTime() - seen.time < 1.5, hypot(seen.at.x - at.x, seen.at.y - at.y) < 8 {
                quick = seen.found
            } else {
                quick = await Task.detached { Controller.thing(at: at, pid: win.pid, in: win.frame, deep: false) }.value
            }
            // The same thing again takes it back.
            if let same = self.pointed.first(where: { mark in
                if let quick { return overlap(mark.rect, quick.rect) > 0.8 }
                return mark.info["spot"] as? Bool == true && mark.rect.contains(at)
            }) {
                self.unpoint(same.n, tellPanel: true)
                return
            }
            let n = self.beginPoint(quick ?? Found(rect: CGRect(x: at.x - 60, y: at.y - 22, width: 120, height: 44), kind: "区域"), in: win, underline: false)
            if quick == nil { self.pointed[self.pointed.count - 1].info["spot"] = true }
            var found = await Task.detached { Controller.thing(at: at, pid: win.pid, in: win.frame, deep: true) }.value
            if found == nil { found = await self.patch(at: at, in: win) }
            self.finishPoint(n, found ?? quick, in: win)
        }
    }

    /// A drag that wasn't over text: everything inside it. If that is one thing, it is that thing.
    func pickRegion(_ box: CGRect) {
        guard let win = currentWin() else { return }
        let region = box.intersection(win.frame)
        guard !region.isEmpty else { return }
        let n = beginPoint(Found(rect: region, kind: "区域"), in: win, underline: false)
        Task { @MainActor in
            // A few looks across it say what is there; the words come from one small reading of the ring's inside.
            let things = await Task.detached { () -> [Found] in
                var seen: [Found] = []
                let columns = max(2, min(4, Int(region.width / 90))), rows = max(2, min(4, Int(region.height / 60)))
                for i in 0..<columns { for j in 0..<rows {
                    let spot = CGPoint(x: region.minX + region.width * (CGFloat(i) + 0.5) / CGFloat(columns), y: region.minY + region.height * (CGFloat(j) + 0.5) / CGFloat(rows))
                    if let found = Controller.thing(at: spot, pid: win.pid, in: win.frame, deep: false), !seen.contains(where: { $0.rect == found.rect }) { seen.append(found) }
                } }
                return seen
            }.value
            // A small ring on a big picture is a part of that picture: a label on a chart, one face in a photo.
            if let picture = things.first(where: { $0.kind == "图片" && overlapOf(region, within: $0.rect) > 0.9 && $0.rect.width * $0.rect.height > 2 * region.width * region.height }) {
                var part = Found(rect: region, kind: "图片局部", name: picture.name, url: picture.url)
                let x = (region.minX - picture.rect.minX) / picture.rect.width, y = (region.minY - picture.rect.minY) / picture.rect.height
                part.text = String(format: "在这张图里的位置：左 %.0f%%、上 %.0f%%，宽 %.0f%%、高 %.0f%%", x * 100, y * 100, region.width / picture.rect.width * 100, region.height / picture.rect.height * 100)
                let said = await self.read(region, in: win)
                if !said.isEmpty { part.text += "\n圈里的字：" + said }
                self.finishPoint(n, part, in: win)
                return
            }
            let inside = things.filter { overlapOf($0.rect, within: region) > 0.6 }
            if inside.count == 1, inside[0].rect.width * inside[0].rect.height > 0.35 * region.width * region.height,
               things.allSatisfy({ $0.rect == inside[0].rect || overlapOf($0.rect, within: region) < 0.15 }) {
                let centre = CGPoint(x: inside[0].rect.midX, y: inside[0].rect.midY)
                let whole = await Task.detached { Controller.thing(at: centre, pid: win.pid, in: win.frame, deep: true) }.value
                self.finishPoint(n, whole ?? inside[0], in: win)
                return
            }
            var counts: [String: Int] = [:]
            inside.forEach { counts[$0.kind, default: 0] += 1 }
            var found = Found(rect: region, kind: "区域")
            found.name = counts.isEmpty ? "" : "含 " + counts.sorted { $0.key < $1.key }.map { "\($0.value) 处\($0.key)" }.joined(separator: "、")
            let links = inside.filter { !$0.url.isEmpty }.map { [$0.kind, $0.name, $0.url].filter { !$0.isEmpty }.joined(separator: "｜") }
            found.text = await self.read(region, in: win)
            if found.text.isEmpty {   // no Screen Recording: ask the app for the words instead
                found.text = await Task.detached { inside.prefix(4).compactMap { Controller.thing(at: CGPoint(x: $0.rect.midX, y: $0.rect.midY), pid: win.pid, in: win.frame, deep: true)?.text }.joined(separator: "\n") }.value
            }
            if !links.isEmpty { found.text += (found.text.isEmpty ? "" : "\n") + links.joined(separator: "\n") }
            self.finishPoint(n, found, in: win)
        }
    }

    /// After a drag over text that the app selected: what it selected and where.
    func pickSelection(from start: CGPoint, to end: CGPoint) {
        guard let win = currentWin() else { return }
        Task { @MainActor in
            var (text, rect) = await Task.detached { Controller.selection(pid: win.pid) }.value
            let band = CGRect(x: min(start.x, end.x), y: min(start.y, end.y) - 10, width: abs(end.x - start.x), height: abs(end.y - start.y) + 20)
            if text.isEmpty { text = await self.read(band, in: win) }
            guard !text.isEmpty else { return }
            let n = self.beginPoint(Found(rect: rect ?? band, kind: "文字", text: text), in: win, underline: true)
            self.finishPoint(n, Found(rect: rect ?? band, kind: "文字", text: text), in: win)
        }
    }

    /// What the app has selected, through its focused element; Chrome and Safari answer in text markers.
    nonisolated static func selection(pid: pid_t) -> (String, CGRect?) {
        let app = AXUIElementCreateApplication(pid)
        guard let focus = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID() else { return ("", nil) }
        // swiftlint:disable:next force_cast
        let element = focus as! AXUIElement
        var text = words(element, kAXSelectedTextAttribute)
        var rect: CGRect?
        func bounds(_ name: String, _ argument: CFTypeRef) -> CGRect? {
            var found: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &found) == .success, let found,
                  CFGetTypeID(found) == AXValueGetTypeID() else { return nil }
            var r = CGRect.zero
            // swiftlint:disable:next force_cast
            AXValueGetValue(found as! AXValue, .cgRect, &r)
            return r.isEmpty ? nil : r
        }
        if let range = value(element, kAXSelectedTextRangeAttribute) { rect = bounds("AXBoundsForRange", range) }
        if let markers = value(element, "AXSelectedTextMarkerRange") {
            if text.isEmpty {
                var said: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, markers, &said) == .success {
                    text = (said as? String) ?? (said as? NSAttributedString)?.string ?? ""
                }
            }
            rect = rect ?? bounds("AXBoundsForTextMarkerRange", markers)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), rect)
    }

    /// One picture of the stuck window at twice its size, taken when ⌃ goes down; a scroll or a move makes it stale.
    func takeSnapshot() {
        guard let win = currentWin(), CGPreflightScreenCaptureAccess() else { return }
        if let shot = snapshot, shot.id == win.id, shot.frame == win.frame, CACurrentMediaTime() - shot.at < 10 { return }
        snapshot = (win.id, win.frame, CACurrentMediaTime(), Task { await Hands.captureLive(win, scale: 2) })
    }

    /// The part of the window inside a local rect, at twice its size: cut from the picture taken when ⌃ went down, or taken now.
    func picture(of local: CGRect, in win: Win) async -> CGImage? {
        if let shot = snapshot, shot.id == win.id, shot.frame == win.frame, let whole = await shot.image.value,
           let piece = whole.cropping(to: CGRect(x: local.minX * 2, y: local.minY * 2, width: local.width * 2, height: local.height * 2)) {
            return piece
        }
        return await Hands.captureLive(win, scale: 2, source: local)
    }

    /// Words read off the window inside a rect, for what Accessibility can't see. Needs Screen Recording.
    func read(_ rect: CGRect, in win: Win) async -> String {
        // Only the inside of the ring: a small fraction of the window to read.
        let local = rect.offsetBy(dx: -win.frame.minX, dy: -win.frame.minY).insetBy(dx: -4, dy: -4)
            .intersection(CGRect(origin: .zero, size: win.frame.size)).integral
        guard !local.isEmpty, CGPreflightScreenCaptureAccess(), let image = await picture(of: local, in: win) else { return "" }
        let size = local.size
        return await Task.detached { Hands.recognize(image, size: size).map(\.text).joined(separator: "\n") }.value
    }

    /// Where Accessibility sees nothing: the patch of one colour around the press, a chat bubble say, and its words.
    func patch(at point: CGPoint, in win: Win) async -> Found? {
        // The neighbourhood of the press is enough to find a bubble in, and far less to fill than the window.
        let local = CGPoint(x: point.x - win.frame.minX, y: point.y - win.frame.minY)
        let near = CGRect(x: local.x - 420, y: local.y - 260, width: 840, height: 520).intersection(CGRect(origin: .zero, size: win.frame.size)).integral
        guard !near.isEmpty, CGPreflightScreenCaptureAccess(), let image = await picture(of: near, in: win) else { return nil }
        let seed = CGPoint(x: local.x - near.minX, y: local.y - near.minY)
        let box = await Task.detached { Controller.flood(image, from: seed, size: near.size) }.value.map { $0.offsetBy(dx: near.minX, dy: near.minY) }
        let area = win.frame.width * win.frame.height
        var rect = CGRect(x: local.x - 100, y: local.y - 45, width: 200, height: 90)
        // Touching the edge of the neighbourhood means it ran into the window's own background: not a patch.
        if let box, box.width * box.height > 300, box.width * box.height < 0.6 * area,
           box.minX > near.minX + 1 || near.minX == 0, box.maxX < near.maxX - 1 || near.maxX >= win.frame.width - 1 { rect = box }
        let onScreen = rect.offsetBy(dx: win.frame.minX, dy: win.frame.minY).intersection(win.frame)
        var found = Found(rect: onScreen, kind: "区域")
        found.text = await read(onScreen, in: win)
        return found
    }

    /// The bounds of the run of near-identical colour around a point, in the picture's own points.
    nonisolated static func flood(_ image: CGImage, from seed: CGPoint, size: CGSize) -> CGRect? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let sx = Int(seed.x), sy = Int(seed.y)
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return nil }
        // Text on a bubble is a different colour: start from the most common colour near the press, not the pixel under it.
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2])) }
        var tally: [Int: Int] = [:]
        for dy in -6...6 { for dx in -6...6 {
            let x = min(w - 1, max(0, sx + dx)), y = min(h - 1, max(0, sy + dy)), p = pixel(x, y)
            tally[(p.0 >> 3) << 10 | (p.1 >> 3) << 5 | (p.2 >> 3), default: 0] += 1
        } }
        guard let key = tally.max(by: { $0.value < $1.value })?.key else { return nil }
        let base = ((key >> 10) << 3 + 4, ((key >> 5) & 31) << 3 + 4, (key & 31) << 3 + 4)
        func same(_ x: Int, _ y: Int) -> Bool { let p = pixel(x, y); return abs(p.0 - base.0) < 12 && abs(p.1 - base.1) < 12 && abs(p.2 - base.2) < 12 }
        // Starting on a letter, step to the nearest pixel of the patch's colour.
        var start: (Int, Int)?
        for r in 0...6 where start == nil {
            for dy in -r...r { for dx in -r...r where start == nil {
                let x = sx + dx, y = sy + dy
                if x >= 0, y >= 0, x < w, y < h, same(x, y) { start = (x, y) }
            } }
        }
        guard let first = start else { return nil }
        var seen = [Bool](repeating: false, count: w * h), stack = [first]
        var minX = first.0, maxX = first.0, minY = first.1, maxY = first.1, count = 0
        seen[first.1 * w + first.0] = true
        while let (x, y) = stack.popLast() {
            count += 1
            if count > 250_000 { return nil }   // the window's own background: no patch here
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h && !seen[ny * w + nx] {
                seen[ny * w + nx] = true
                if same(nx, ny) { stack.append((nx, ny)) }
            }
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    // MARK: the marks and the panel

    /// The ring and its tile, at once, from what is known so far. Returns its number.
    @discardableResult
    func beginPoint(_ found: Found, in win: Win, underline: Bool) -> Int {
        var n = 1
        while pointed.contains(where: { $0.n == n }) { n += 1 }
        let info = describe(found, n: n, in: win, pending: true)
        let mark = enchant.mark(found.rect, n: n, underline: underline)
        pointed.append(Pointed(n: n, rect: found.rect, info: info, mark: mark))
        goo.reachGoal = V(found.rect.maxX + 14, found.rect.midY)
        goo.armArrived = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.goo.reachGoal = nil }
        tellPanel(info)
        return n
    }

    /// What was found behind it, once gathered: the tile fills in, and the ring moves if the thing turned out bigger or smaller.
    func finishPoint(_ n: Int, _ found: Found?, in win: Win) {
        guard let index = pointed.firstIndex(where: { $0.n == n }) else { return }  // taken back meanwhile
        guard let found else {
            pointed[index].info["pending"] = nil
            tellPanel(pointed[index].info)
            return
        }
        var info = describe(found, n: n, in: win, pending: false)
        if pointed[index].info["spot"] != nil { info["spot"] = true }
        if overlap(pointed[index].rect, found.rect) < 0.85 || abs(pointed[index].rect.width - found.rect.width) > 24 {
            if let old = pointed[index].mark { enchant.unmark(old) }
            pointed[index].mark = enchant.mark(found.rect, n: n, underline: false)
            pointed[index].rect = found.rect
        }
        pointed[index].info = info
        tellPanel(info)
        log("point \(found.kind) filled in \(Int((CACurrentMediaTime() - pointed[index].began) * 1000))ms")
        // Which document it is in: a question to the app, asked after the ring is up.
        Task { @MainActor in
            guard let window = self.axWindow(pid: win.pid, frame: win.frame, id: win.id) else { return }
            let document = await Task.detached { Controller.words(window, "AXDocument") }.value
            guard let path = URL(string: document), path.isFileURL, let i = self.pointed.firstIndex(where: { $0.n == n }) else { return }
            self.pointed[i].info["document"] = path.path
            self.tellPanel(self.pointed[i].info)
        }
    }

    func describe(_ found: Found, n: Int, in win: Win, pending: Bool) -> [String: Any] {
        let local = found.rect.offsetBy(dx: -win.frame.minX, dy: -win.frame.minY)
        var info: [String: Any] = ["n": n, "kind": found.kind, "app": win.app, "title": win.title,
                                   "at": [Int(local.minX), Int(local.minY), Int(local.width), Int(local.height)]]
        if !found.name.isEmpty { info["name"] = String(found.name.prefix(200)) }
        if !found.text.isEmpty { info["text"] = String(found.text.prefix(2000)) }
        if !found.url.isEmpty { info[found.url.hasPrefix("/") ? "path" : "url"] = found.url }
        if pending { info["pending"] = true }
        return info
    }

    func tellPanel(_ info: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: info), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("addPoint(\(json))")
    }

    func unpoint(_ n: Int, tellPanel: Bool) {
        guard let index = pointed.firstIndex(where: { $0.n == n }) else { return }
        if let mark = pointed[index].mark { enchant.unmark(mark) }
        pointed.remove(at: index)
        if tellPanel { web.evaluateJavaScript("dropPoint(\(n))") }
    }

    /// Sent: the rings go back into Tako.
    func pointsSent() {
        enchant.gather(pointed.compactMap(\.mark), into: goo.c)
        pointed = []
    }

    /// On another window, or peeled off: rings on the old one mean nothing now. The panel keeps what was found.
    func forgetMarks() {
        pointed.compactMap(\.mark).forEach { $0.removeFromSuperlayer() }
        pointed = []
    }
}

/// How much of b lies inside a, as a share of the smaller.
func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    return i.width * i.height / max(1, min(a.width * a.height, b.width * b.height))
}

/// How much of a thing lies within a region, as a share of the thing.
func overlapOf(_ thing: CGRect, within region: CGRect) -> CGFloat {
    let i = thing.intersection(region)
    guard !i.isNull else { return 0 }
    return i.width * i.height / max(1, thing.width * thing.height)
}
