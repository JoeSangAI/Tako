// Using any app for the owner: seeing what can be pressed, pressing it, typing, scrolling, in whichever
// window the request is about, not only the one the goo sits on. The real keyboard and pointer are
// used, so it stops as soon as the owner moves the pointer. Sending a message stays the owner's; anything else
// that can't be taken back waits for their approval on a card.
import ApplicationServices
import AppKit
import Carbon.HIToolbox

struct Win {
    let id: Int
    var frame: CGRect
    let pid: pid_t
    let bundle: String
    let app: String
    var title: String
    var isWeChat: Bool { bundle == weChatBundle }
}

struct Element {
    let ax: AXUIElement
    let role: String
    let label: String
    let frame: CGRect  // in window coordinates
}

// Enter sends in these, so it is never pressed there.
let messagingNames = ["微信", "wechat", "飞书", "lark", "feishu", "qq", "telegram", "slack", "discord", "信息", "messages", "钉钉", "dingtalk", "whatsapp", "企业微信", "wecom"]
// A wrong click here can cost the owner their network or their machine: every step asks first.
let askFirstBundles: Set<String> = ["com.liguangming.Shadowrocket", "com.apple.systempreferences", "com.apple.keychainaccess",
                                    "com.apple.Terminal", "com.googlecode.iterm2"]
let sendWords = ["发送", "发出", "寄出", "send", "reply all"]
let riskyWords = ["提交", "submit", "支付", "付款", "pay", "购买", "buy", "下单", "checkout", "删除", "delete", "移除", "remove",
                  "清空", "发布", "publish", "post", "注销", "退出登录", "sign out", "log out", "卸载", "uninstall", "格式化", "erase",
                  "抹掉", "重置", "reset", "断开", "disconnect", "停止", "stop", "关闭连接", "转账", "transfer"]
let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "forwarddelete": 117, "esc": 53, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "/": 44, "-": 27, "=": 24,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]

/// A button says one short thing. A long line that merely contains the word ("不要发送") is not a button.
func hits(_ text: String, _ words: [String]) -> String? {
    let lowered = text.lowercased()
    let pieces = [lowered] + lowered.components(separatedBy: .whitespacesAndNewlines)
    for piece in pieces where !piece.isEmpty && piece.count <= 14 {
        for word in words {
            if word.allSatisfy({ $0.isASCII }) {
                // English words whole only: "post" must not catch "poster".
                if piece.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil { return word }
            } else if piece.contains(word) { return word }
        }
    }
    return nil
}

extension Controller {
    // MARK: windows

    func openWindows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info -> Win? in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let id = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerName as String] as? String, !blockedOwners.contains(owner),
                  let raw = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw),
                  rect.width > 200, rect.height > 80, let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            let bundle = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? owner
            return Win(id: id, frame: rect, pid: pid_t(pid), bundle: bundle, app: owner, title: info[kCGWindowName as String] as? String ?? "")
        }
    }

    /// The window a request means: by id, app name or title; nothing at all means the one it is stuck to.
    func resolve(_ spec: String?) async -> Win? {
        let wanted = (spec ?? "").trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            guard let current = target else { return nil }
            return Win(id: current.id, frame: current.frame, pid: pid, bundle: bundle, app: appName, title: currentTitle(id: current.id))
        }
        func find() -> Win? {
            let all = openWindows()
            if let id = Int(wanted), let hit = all.first(where: { $0.id == id }) { return hit }
            let key = wanted.lowercased()
            let hits = all.filter { $0.app.lowercased().contains(key) || $0.bundle.lowercased().contains(key) || $0.title.lowercased().contains(key) }
            return hits.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        if let hit = find() { return hit }
        // Running but with no window in view (hidden, or behind another Space): bring it forward once.
        let key = wanted.lowercased()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && (($0.localizedName ?? "").lowercased().contains(key) || ($0.bundleIdentifier ?? "").lowercased().contains(key))
        }), !blockedOwners.contains(app.localizedName ?? "") else { return nil }
        app.unhide()
        app.activate()
        try? await Task.sleep(nanoseconds: 700_000_000)
        return find()
    }

    func currentTitle(id: Int) -> String {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first?[kCGWindowName as String] as? String ?? ""
    }

    func listWindows() -> [String: Any] {
        ["ok": true, "windows": openWindows().map { ["id": $0.id, "app": $0.app, "title": $0.title, "stuck": $0.id == target?.id] as [String: Any] }]
    }

    // MARK: what can be pressed

    /// Electron and Chromium hide their contents from Accessibility until somebody asks for it.
    func askForAccessibleContent(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Everything readable and everything pressable in the window. Runs off the main thread: some apps answer slowly.
    nonisolated static func survey(window: AXUIElement, origin: CGPoint, size: CGSize) -> (text: String, elements: [Element]) {
        let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXMenuButton",
                                      "AXPopUpButton", "AXComboBox", "AXTab", "AXCell", "AXRow", "AXSlider", "AXSwitch", "AXSearchField", "AXDisclosureTriangle"]
        var lines: [String] = [], used = 0, visited = 0, elements: [Element] = []
        let began = CACurrentMediaTime()
        func string(_ element: AXUIElement, _ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 40, visited < 6000, CACurrentMediaTime() - began < 2.5 else { return }
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXPlaceholderValue"].lazy.compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
            if label.count > 1, used < 9000 { lines.append(label); used += label.count }
            if pressable.contains(role), elements.count < 300 {
                var position: CFTypeRef?, extent: CFTypeRef?
                var at = CGPoint.zero, dimension = CGSize.zero
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent) == .success {
                    AXValueGetValue(position as! AXValue, .cgPoint, &at)
                    AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
                    let local = CGRect(x: at.x - origin.x, y: at.y - origin.y, width: dimension.width, height: dimension.height)
                    if dimension.width > 2, dimension.height > 2, local.intersects(CGRect(origin: .zero, size: size)) {
                        elements.append(Element(ax: element, role: role, label: String(label.prefix(60)), frame: local))
                    }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                for child in list { walk(child, depth + 1) }
            }
        }
        walk(window, 0)
        return (lines.joined(separator: "\n"), elements)
    }

    /// Looks at a window: a picture where one pixel is one window point, its text with positions, and what can be pressed.
    @MainActor
    func look(_ win: Win) async -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "error": "没有屏幕录制权限，看不到窗口"] }
        if win.id == target?.id { goo.state = "reading"; enchant.setMood("reading") } else { flash(win) }
        askForAccessibleContent(pid: win.pid)
        let size = win.frame.size
        guard let image = await Hands.captureLive(win, scale: 2) else {
            return ["ok": false, "error": "这个窗口现在截不到（可能不在当前桌面）"]
        }
        let wide = max(size.width, 1), shrink = wide > 1600 ? 1600 / wide : 1
        let read = await Task.detached { (Hands.recognize(image, size: size), Hands.jpeg(image, scale: shrink / 2, quality: 0.72)) }.value
        var surveyed: (text: String, elements: [Element]) = ("", [])
        if trusted, let window = axWindow(pid: win.pid, frame: win.frame) {
            let origin = win.frame.origin
            surveyed = await Task.detached { Controller.survey(window: window, origin: origin, size: size) }.value
        }
        elements = surveyed.elements
        elementsWindow = win.id
        var result: [String: Any] = ["ok": true, "id": win.id, "app": win.app, "title": win.title, "imageScale": shrink]
        result["text"] = surveyed.text.count > 300 ? surveyed.text : read.0.map(\.text).joined(separator: "\n")
        result["lines"] = read.0.prefix(220).map { "(\(Int($0.box.minX)),\(Int($0.box.minY)),\(Int($0.box.width)),\(Int($0.box.height))) \($0.text)" }.joined(separator: "\n")
        result["elements"] = surveyed.elements.enumerated().map { "[\($0.offset)] \($0.element.role.dropFirst(2)) \"\($0.element.label)\" (\(Int($0.element.frame.minX)),\(Int($0.element.frame.minY)),\(Int($0.element.frame.width)),\(Int($0.element.frame.height)))" }.joined(separator: "\n")
        if let document = await documentPath(win) { result["document"] = document }
        if let picture = read.1 { result["image"] = picture }
        return result
    }

    // MARK: acting

    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Starts a run of steps on a window: brings it forward and remembers where the pointer was.
    @MainActor
    func beginSteps(_ win: Win) async {
        operating = true
        lastStep = CACurrentMediaTime()
        await frontTarget(win)
        pointerHome = cursor()
        pointerLeft = pointerHome
        if win.id != target?.id { flash(win) }
    }

    func endSteps() {
        // The owner has taken the pointer: it stays where they have it.
        if let home = pointerHome, let left = pointerLeft, hypot(cursor().x - left.x, cursor().y - left.y) <= 6 { CGWarpMouseCursorPosition(home) }
        pointerHome = nil
        operating = false
        goo.reachGoal = nil
    }

    /// The label on whatever sits at a point in the window: from Accessibility, or else read off the picture.
    @MainActor
    func labelAt(_ point: CGPoint, in win: Win) async -> String {
        var found: AXUIElement?
        let screenPoint = CGPoint(x: win.frame.minX + point.x, y: win.frame.minY + point.y)
        var parts: [String] = []
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(screenPoint.x), Float(screenPoint.y), &found) == .success, var element = found {
            for _ in 0..<3 {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let text = value as? String, !text.isEmpty, text.count < 80 { parts.append(text) }
                }
                var parent: CFTypeRef?
                guard parts.isEmpty, AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let next = parent else { break }
                element = next as! AXUIElement
            }
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let box = CGRect(x: max(0, point.x - 70), y: max(0, point.y - 20), width: 140, height: 40)
        guard let image = await Hands.captureLive(win, scale: 2, source: box) else { return "" }
        return await Task.detached { Hands.recognize(image, size: box.size).map(\.text).joined(separator: " ") }.value
    }

    func refusal(_ text: String) -> [String: Any] { ["ok": false, "refused": true, "error": text] }

    /// Whether this press has to stop: never for the owner to do, or needs them to say yes first.
    func gateClick(label: String, at point: CGPoint, in win: Win, confirmed: Bool) -> [String: Any]? {
        if let word = hits(label, sendWords) { return refusal("这是“\(word)”，发送留给用户自己按，已停下") }
        if win.isWeChat, point.y > win.frame.height - 48, point.x > win.frame.width - 110 { return refusal("这里是微信的发送键，留给用户自己按") }
        if confirmed { return nil }
        if askFirstBundles.contains(win.bundle) { return ["needs": "在 \(win.app) 里点“\(label.isEmpty ? "(\(Int(point.x)),\(Int(point.y)))" : label)”"] }
        if let word = hits(label, riskyWords) { return ["needs": "在 \(win.app) 里点“\(label)”（\(word)，可能收不回来）"] }
        return nil
    }

    func focusedSubrole(_ pid: pid_t) -> (role: String, subrole: String) {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return ("", "") }
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (role as? String ?? "", subrole as? String ?? "")
    }

    /// The name on whatever holds the keyboard: pressing Return or Space on a button presses that button.
    func focusedLabel(_ pid: pid_t) -> String {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return "" }
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element as! AXUIElement, name as CFString, &value) == .success, let text = value as? String, !text.isEmpty { return text }
        }
        return ""
    }

    /// One reading of a key combination, shared by what is checked and what is pressed.
    func chord(_ keys: String) -> (flags: CGEventFlags, key: String) {
        var flags: CGEventFlags = [], key = ""
        for part in keys.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: key = part
            }
        }
        return (flags, key)
    }

    func gateKey(_ keys: String, in win: Win, confirmed: Bool) -> [String: Any]? {
        let (flags, key) = chord(keys)
        let enter = key == "return" || key == "enter"
        if enter || key == "space", let word = hits(focusedLabel(win.pid), sendWords) { return refusal("键盘正落在“\(word)”上，发送留给用户自己按") }
        if enter {
            let lowered = (win.app + " " + win.bundle).lowercased()
            if messagingNames.contains(where: { lowered.contains($0) }) { return refusal("\(win.app) 里回车就是发送，这个键留给用户") }
            // Command-Return sends in mail and most web apps, whatever holds the keyboard.
            if !flags.subtracting(.maskShift).isEmpty { return refusal("\(keys) 通常就是发送，留给用户自己按") }
            let focus = focusedSubrole(win.pid)
            // A search box or address bar is fine; so is Return on a dropdown or a button whose name says it is harmless.
            // Anywhere else, Enter may submit or send something.
            let label = focusedLabel(win.pid)
            let harmless = flags.isEmpty && (["AXTextField", "AXComboBox", "AXSearchField", "AXPopUpButton", "AXMenuItem", "AXCheckBox", "AXRadioButton"].contains(focus.role)
                || (focus.role == "AXButton" && !label.isEmpty && hits(label, riskyWords) == nil))
            if !harmless && !confirmed {
                log("return asks first: \(focus.role)")
                return ["needs": "在 \(win.app) 里按回车（可能会提交或发送）"]
            }
        }
        if win.bundle == "com.apple.mail", flags.contains(.maskCommand), flags.contains(.maskShift), key == "d" { return refusal("这是 Mail 的发送键，留给用户自己按") }
        if confirmed { return nil }
        if askFirstBundles.contains(win.bundle) { return ["needs": "在 \(win.app) 里按 \(keys)"] }
        if flags.contains(.maskCommand) && ["q", "delete", "backspace"].contains(key) { return ["needs": "在 \(win.app) 里按 \(keys)"] }
        return nil
    }

    func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = []   // so no modifier stays held for whatever comes next
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Pasting is the only safe way to enter several lines, and the fastest way to enter long ones.
    @MainActor
    func paste(_ text: String, files: [String]) async {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        board.clearContents()
        var objects: [NSPasteboardWriting] = files.map { URL(fileURLWithPath: $0) as NSURL }
        if !text.isEmpty { objects.append(text as NSString) }
        board.writeObjects(objects)
        press(9, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 420_000_000)
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
    }

    func typeShort(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        func post(_ units: [UInt16]) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
            usleep(12000)
        }
        // By whole characters: an emoji cut in half types as garbage.
        var units: [UInt16] = []
        for character in text {
            let next = Array(String(character).utf16)
            if units.count + next.count > 16 { post(units); units = [] }
            units += next
        }
        if !units.isEmpty { post(units) }
    }

    /// Some apps ignore a click that arrives with no hover before it and no time between down and up.
    func click(at point: CGPoint) {
        mouse(.mouseMoved, at: point)
        usleep(50000)
        mouse(.leftMouseDown, at: point)
        usleep(45000)
        mouse(.leftMouseUp, at: point)
    }

    func mouse(_ kind: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .combinedSessionState), mouseType: kind, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        event?.post(tap: .cghidEventTap)
    }

    /// One step of a run. Everything it may refuse is decided before anything is posted.
    @MainActor
    func step(_ step: [String: Any], in win: Win, confirmed: Bool) async -> [String: Any] {
        lastStep = CACurrentMediaTime()
        let action = step["action"] as? String ?? ""
        if confirmed {
            // The owner just used the pointer and the panel to say yes: that is not taking over. Back to the window, and the pointer goes home to where they left it.
            await frontTarget(win)
            pointerHome = cursor()
            pointerLeft = pointerHome
        } else if let left = pointerLeft, hypot(cursor().x - left.x, cursor().y - left.y) > 6 {
            // The owner has taken the pointer back: hands off at once.
            return refusal("用户 动了鼠标，已停下")
        }
        // The checks below were made for this window; a key or click posted now goes to whatever is in front.
        if ["click", "double_click", "right_click", "type", "key", "drag"].contains(action),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != win.pid {
            return refusal("\(win.app) 不在最前面了，可能是用户切走了，已停下")
        }
        if win.id == target?.id { goo.state = "working"; enchant.setMood("working") }
        switch action {
        case "click", "double_click", "right_click":
            var point: CGPoint?, label = "", element: Element?
            if let ref = step["ref"] as? Int {
                guard elementsWindow == win.id, elements.indices.contains(ref) else { return ["ok": false, "error": "编号 \(ref) 已过期，重新看一下窗口"] }
                element = elements[ref]
                label = elements[ref].label
                point = CGPoint(x: elements[ref].frame.midX, y: elements[ref].frame.midY)
            } else if let text = step["text"] as? String, !text.isEmpty {
                guard let hit = await findText(text, in: win) else { return ["ok": false, "error": "窗口上没找到“\(text)”"] }
                point = CGPoint(x: hit.box.midX, y: hit.box.midY)
                // What is actually there decides: "确认" may have matched "确认发送".
                label = hit.text
            } else if let x = step["x"] as? Double, let y = step["y"] as? Double {
                point = CGPoint(x: x, y: y)
            }
            guard let at = point else { return ["ok": false, "error": "click 要给 ref、text 或 x,y"] }
            guard CGRect(origin: .zero, size: win.frame.size).contains(at) else { return ["ok": false, "error": "这个位置在窗口外面"] }
            label = [label, await labelAt(at, in: win)].filter { !$0.isEmpty }.joined(separator: " ")
            if let stop = gateClick(label: label, at: at, in: win, confirmed: confirmed) { return stop }
            let screen = CGPoint(x: win.frame.minX + at.x, y: win.frame.minY + at.y)
            reach(screen, in: win)
            if win.id == target?.id {
                // It may have to hop over first: the press lands when the limb does.
                for _ in 0..<55 where !goo.armArrived { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            tapMark(screen, in: win)
            if action == "click", let element, AXUIElementPerformAction(element.ax, kAXPressAction as CFString) == .success {
                // pressed without moving the pointer at all
            } else if action == "right_click" {
                pointerLeft = screen
                mouse(.rightMouseDown, at: screen, button: .right)
                mouse(.rightMouseUp, at: screen, button: .right)
            } else {
                // Only where it put the pointer itself counts as its own; any other position is the owner.
                pointerLeft = screen
                mouse(.mouseMoved, at: screen)
                usleep(50000)
                let times = action == "double_click" ? 2 : 1
                for k in 1...times {
                    mouse(.leftMouseDown, at: screen, clicks: k)
                    usleep(40000)
                    mouse(.leftMouseUp, at: screen, clicks: k)
                    if times > 1 { usleep(70000) }
                }
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            return ["ok": true, "did": "点了 \(label.isEmpty ? "(\(Int(at.x)),\(Int(at.y)))" : label)"]
        case "type":
            let text = step["text"] as? String ?? ""
            if focusedSubrole(win.pid).subrole == "AXSecureTextField" { return refusal("这是密码框，密码由用户自己输入") }
            if !confirmed && askFirstBundles.contains(win.bundle) { return ["needs": "在 \(win.app) 里输入：\(text.prefix(80))"] }
            // A control character typed key by key can act as Return; pasted it is only text.
            let plain = !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
            if plain && text.count <= 40 { typeShort(text) } else { await paste(text, files: []) }
            try? await Task.sleep(nanoseconds: 120_000_000)
            return ["ok": true, "did": "输入了 \(text.prefix(30))"]
        case "key":
            let keys = (step["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if let stop = gateKey(keys, in: win, confirmed: confirmed) { return stop }
            let (flags, key) = chord(keys)
            guard let code = keyCodes[key] else { return ["ok": false, "error": "不认识这个键：\(keys)"] }
            press(code, flags: flags)
            try? await Task.sleep(nanoseconds: 220_000_000)
            return ["ok": true, "did": "按了 \(keys)"]
        case "scroll":
            let x = step["x"] as? Double ?? win.frame.width / 2, y = step["y"] as? Double ?? win.frame.height / 2
            guard CGRect(origin: .zero, size: win.frame.size).contains(CGPoint(x: x, y: y)) else { return ["ok": false, "error": "这个位置在窗口外面"] }
            let screen = CGPoint(x: win.frame.minX + x, y: win.frame.minY + y)
            pointerLeft = screen
            mouse(.mouseMoved, at: screen)
            let amount = Int32(max(-100, min(100, step["amount"] as? Double ?? -5)))
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 260_000_000)
            return ["ok": true, "did": "滚动了"]
        case "drag":
            guard let x1 = step["x"] as? Double, let y1 = step["y"] as? Double, let x2 = step["x2"] as? Double, let y2 = step["y2"] as? Double else { return ["ok": false, "error": "drag 要给 x,y,x2,y2"] }
            let bounds = CGRect(origin: .zero, size: win.frame.size)
            guard bounds.contains(CGPoint(x: x1, y: y1)), bounds.contains(CGPoint(x: x2, y: y2)) else { return ["ok": false, "error": "拖动的起点和终点都要在窗口里"] }
            if !confirmed && askFirstBundles.contains(win.bundle) { return ["needs": "在 \(win.app) 里拖动"] }
            for point in [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)] {
                if let stop = gateClick(label: await labelAt(point, in: win), at: point, in: win, confirmed: confirmed) { return stop }
            }
            let from = CGPoint(x: win.frame.minX + x1, y: win.frame.minY + y1), to = CGPoint(x: win.frame.minX + x2, y: win.frame.minY + y2)
            mouse(.leftMouseDown, at: from)
            for k in 1...12 {
                let t = CGFloat(k) / 12
                mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                usleep(14000)
            }
            mouse(.leftMouseUp, at: to)
            pointerLeft = to
            return ["ok": true, "did": "拖动了"]
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(step["seconds"] as? Double ?? 1, 8)) * 1e9))
            return ["ok": true, "did": "等了一下"]
        default:
            return ["ok": false, "error": "不认识的动作：\(action)"]
        }
    }

    @MainActor
    func findText(_ text: String, in win: Win) async -> (text: String, box: CGRect)? {
        let want = Hands.normalize(text)
        if elementsWindow == win.id, let hit = elements.first(where: { Hands.normalize($0.label) == want }) { return (hit.label, hit.frame) }
        guard let image = await Hands.captureLive(win, scale: 2) else { return nil }
        let size = win.frame.size
        let lines = await Task.detached { Hands.recognize(image, size: size) }.value
        return lines.first { Hands.normalize($0.text) == want } ?? lines.first { Hands.normalize($0.text).contains(want) }
    }

    // MARK: WeChat: opening a conversation for filling, without ever pressing Enter

    @MainActor
    func openChat(_ name: String, in win: Win) async -> [String: Any] {
        guard trusted else { return ["ok": false, "error": "没有辅助功能权限"] }
        await frontTarget(win)
        // A window just brought forward can swallow the first click.
        try? await Task.sleep(nanoseconds: 450_000_000)
        let home = cursor()
        var left = home
        defer { if hypot(cursor().x - left.x, cursor().y - left.y) <= 6 { CGWarpMouseCursorPosition(home) } }
        // Typing a name and clicking a result must land in WeChat. If the owner took the pointer or switched away, it stops.
        func stillOurs() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid && hypot(cursor().x - left.x, cursor().y - left.y) <= 6
        }
        let takenOver = ["ok": false, "error": "用户 动了鼠标或切走了窗口，已停下，没有填"] as [String: Any]
        guard stillOurs() else { return takenOver }
        let want = Hands.normalize(name)
        // Already showing it: nothing to do.
        if let shown = await Controller.headerTitles(windowID: win.id, width: win.frame.width, previous: 0), shown.lines.contains(where: { Hands.normalize($0) == want }) {
            return ["ok": true]
        }
        // The search box sits at the top of the chat list; results open on a click, so Enter is never needed.
        let box = CGPoint(x: win.frame.minX + 200, y: win.frame.minY + 28)
        left = box
        click(at: box)
        // The box takes a moment to open its list; anything typed before that is lost.
        // Nothing here selects or deletes: if focus were still in the chat input, the owner's draft must survive.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let area = CGRect(x: 0, y: 0, width: min(460, win.frame.width), height: win.frame.height)
        var lines: [(text: String, box: CGRect)] = []
        // The box sometimes drops what is typed while it is still opening: check it arrived, and type again if not.
        for _ in 0..<3 {
            guard stillOurs() else { return takenOver }
            typeShort(name)
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let image = await Hands.captureLive(win, scale: 2, source: area) else { return ["ok": false, "error": "看不到搜索结果"] }
            lines = await Task.detached { Hands.recognize(image, size: area.size) }.value
            if lines.contains(where: { $0.box.minY < 40 && $0.box.minX < 260 && Hands.normalize($0.text).contains(want) }) { break }
        }
        // The first rows suggest web searches; real chats come under a section heading.
        let headings = ["功能", "联系人", "群聊", "最常使用", "最近使用", "聊天记录"]
        let below = lines.first { line in headings.contains { Hands.normalize(line.text) == $0 } }?.box.maxY ?? 0
        guard below > 0, let hit = lines.first(where: { $0.box.minY >= below && Hands.normalize($0.text).hasPrefix(want) }) else {
            press(53, flags: [])
            return ["ok": false, "error": "微信里没搜到“\(name)”"]
        }
        guard stillOurs() else { return takenOver }
        let spot = CGPoint(x: win.frame.minX + hit.box.midX, y: win.frame.minY + hit.box.midY)
        left = spot
        click(at: spot)
        try? await Task.sleep(nanoseconds: 700_000_000)
        return ["ok": true]
    }

    // MARK: being seen to do it

    func reach(_ screen: CGPoint, in win: Win) {
        guard win.id == target?.id else { return }
        goo.reachGoal = V(screen.x, screen.y)
        goo.armArrived = false
    }

    func tapMark(_ screen: CGPoint, in win: Win) {
        inkFlash.tap(at: screen, over: win)
    }

    func flash(_ win: Win) {
        inkFlash.outline(win)
        goo.pop = max(goo.pop, 0.4)
    }

    // MARK: the panel's keyboard

    /// Command-C and Command-V in the panel become editing actions only through these, even while another app is in front.
    func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 Tako", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdate), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Tako", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let holder = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                     ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        holder.submenu = edit
        main.addItem(holder)
        NSApp.mainMenu = main
    }

    // MARK: the shortcut: from any window, right now

    func installHotKey() {
        var id = EventHotKeyID(signature: OSType(0x54414B4F), id: 1)  // 'TAKO'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { controller.summon() }
            return noErr
        }, 1, &spec, nil, nil)
        // Control-Option-T
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        _ = id
        id.id = 1
        // Some apps (Chrome, seen 2026-10-30) keep the combination from reaching a hot key; the monitor still sees it.
        let isShortcut = { (event: NSEvent) -> Bool in
            event.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option] && event.keyCode == UInt16(kVK_ANSI_T)
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if isShortcut(event), !event.isARepeat { DispatchQueue.main.async { controller.summon() } }
        }
        // And while the panel itself holds the keyboard, keys come to this app, past both of the above.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isShortcut(event) else { return event }
            if !event.isARepeat { controller.summon() }
            return nil
        }
    }

    /// Jumps to the frontmost window and opens the panel; on the window it is already on, opens or closes it.
    func summon() {
        // The hot key and the monitor can both fire for one press.
        let now = CACurrentMediaTime()
        guard now - lastSummon > 0.3 else { return }
        lastSummon = now
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // A system dialog can be the frontmost app without a window of its own to stick to: use the window behind it.
        let large = openWindows().filter { $0.frame.width > 300 && $0.frame.height > 200 }
        log("summoned over \(large.first(where: { $0.pid == front })?.bundle ?? "nothing")")
        guard let win = large.first(where: { $0.pid == front }) ?? large.first else {
            goo.fumble()
            return
        }
        let already = win.id == target?.id && (goo.mode == .attached || goo.mode == .open)
        if already {
            toggleSide()
            return
        }
        closeSide()
        goo.sleeping = false
        goo.puddle = false
        goo.peekSide = 0
        goo.splatUntil = 0
        goo.stick(to: win.frame.maxX, window: win.id)
        gooPanel.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.goo.mode == .attached else { return }
            self.web.evaluateJavaScript("setOpen(true)")
        }
    }
}

/// Brief marks on any window: an ink outline when TAKO reaches into a window it isn't sitting on, a ripple where it presses.
final class InkFlash {
    let panel: SideWindow
    let root = CALayer()
    var hideWork: DispatchWorkItem?

    init() {
        panel = SideWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view
    }

    func place(over win: Win, for seconds: Double) {
        guard let primary = NSScreen.screens.first else { return }
        let outer = win.frame.insetBy(dx: -8, dy: -8)
        panel.setFrame(NSRect(x: outer.minX, y: primary.frame.maxY - outer.maxY, width: outer.width, height: outer.height), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: outer.size)
        CATransaction.commit()
        panel.orderFront(nil)
        panel.order(.above, relativeTo: win.id)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.root.sublayers?.removeAll()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func ink() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1).cgColor
        layer.lineCap = .round
        // Dark or light under it, the line needs to show.
        layer.shadowColor = NSColor.white.cgColor
        layer.shadowOpacity = 0.7
        layer.shadowRadius = 1.5
        layer.shadowOffset = .zero
        root.addSublayer(layer)
        return layer
    }

    /// A line of ink runs once round the window.
    func outline(_ win: Win) {
        place(over: win, for: 2.2)
        let line = ink()
        line.lineWidth = 2.6
        line.path = CGPath(roundedRect: root.bounds.insetBy(dx: 7.5, dy: 7.5), cornerWidth: 11, cornerHeight: 11, transform: nil)
        let start = CABasicAnimation(keyPath: "strokeEnd")
        start.fromValue = 0
        start.toValue = 1
        start.duration = 0.55
        start.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.2
        fade.duration = 0.8
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        line.add(start, forKey: "draw")
        line.add(fade, forKey: "fade")
    }

    /// A ring of ink spreading from where it pressed.
    func tap(at screen: CGPoint, over win: Win) {
        place(over: win, for: 1.2)
        let centre = CGPoint(x: screen.x - win.frame.minX + 8, y: win.frame.maxY - screen.y + 8)
        let ring = ink()
        ring.lineWidth = 2
        ring.path = CGPath(ellipseIn: CGRect(x: centre.x - 16, y: centre.y - 16, width: 32, height: 32), transform: nil)
        ring.frame = root.bounds
        ring.anchorPoint = CGPoint(x: centre.x / max(1, root.bounds.width), y: centre.y / max(1, root.bounds.height))
        ring.position = centre
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 1
        grow.duration = 0.4
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.55
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ring.add(grow, forKey: "grow")
        ring.add(fade, forKey: "fade")
    }
}
