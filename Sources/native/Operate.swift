// Using any app for the owner: seeing what can be pressed, pressing it, typing, scrolling, in whichever
// window the request is about, not only the one the goo sits on. The owner may be anywhere else meanwhile, so it works
// behind their back: through Accessibility and events sent to that app alone, never their focus, pointer or clipboard.
// The few things only the real pointer can do wait until the owner is back on that window and idle. Sending a message
// stays the owner's; anything else that can't be taken back waits for their approval on a card.
import ApplicationServices
import AppKit
import Carbon.HIToolbox

private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

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
    var value = ""     // what a text field holds now: truer than the picture of a window nobody is looking at
}

// Enter sends in these, so it is never pressed there.
let messagingNames = ["微信", "wechat", "飞书", "lark", "feishu", "qq", "telegram", "slack", "discord", "信息", "messages", "钉钉", "dingtalk", "whatsapp", "企业微信", "wecom"]
// A wrong click here can cost the owner their network or their machine: every step asks first.
let askFirstBundles: Set<String> = ["com.liguangming.Shadowrocket", "com.apple.systempreferences", "com.apple.keychainaccess",
                                    "com.apple.Terminal", "com.googlecode.iterm2"]
// Browsers that don't run on Chrome's engine: what looks like a text area there may be a web chat.
let webBundles: Set<String> = ["com.apple.Safari", "org.mozilla.firefox", "com.apple.SafariTechnologyPreview"]
let sendWords = ["发送", "发出", "寄出", "send", "reply all"]
// Only what can't be taken back asks first (Joe 2026-11-04: keep the cards that matter). Stop, remove from a list, disconnect: undone with one more click.
let riskyWords = ["提交", "submit", "支付", "付款", "pay", "购买", "buy", "下单", "checkout", "删除", "delete",
                  "清空", "发布", "publish", "post", "注销", "退出登录", "sign out", "log out", "卸载", "uninstall", "格式化", "erase",
                  "抹掉", "重置", "reset", "转账", "transfer"]
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

    func openWindows(anywhere: Bool = false) -> [Win] {
        guard let list = CGWindowListCopyWindowInfo(anywhere ? [.excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
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
        // A task is tied to its window by id, and the owner may have moved on to another desktop or hidden the app.
        if let id = Int(wanted) { return openWindows(anywhere: true).first { $0.id == id } }
        let key = wanted.lowercased()
        func find(_ all: [Win]) -> Win? {
            let hits = all.filter { $0.app.lowercased().contains(key) || $0.bundle.lowercased().contains(key) || $0.title.lowercased().contains(key) }
            return hits.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        return find(openWindows()) ?? find(openWindows(anywhere: true).filter { !$0.title.isEmpty })
    }

    func currentTitle(id: Int) -> String {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first?[kCGWindowName as String] as? String ?? ""
    }

    func listWindows() -> [String: Any] {
        ["ok": true, "windows": openWindows().map { ["id": $0.id, "app": $0.app, "title": $0.title, "stuck": $0.id == target?.id] as [String: Any] }]
    }

    // MARK: what can be pressed

    /// Electron and Chromium hide their contents from Accessibility until somebody asks. Electron takes the first request; Chrome refuses it
    /// and answers only to the second (which also returns an error, seen 2026-11-01), and other apps animate oddly under it, so it comes only after a refusal.
    @MainActor
    func askForAccessibleContent(_ win: Win) async {
        let app = AXUIElementCreateApplication(win.pid)
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            guard askedForContent.insert(win.pid).inserted else { return }
            // Chrome takes a moment to build what it has just been asked for, and it can be several: a first look without the page can't press anything in it (seen 2026-11-02).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard drawsLikeChrome(win.pid), let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) else { return }
            for _ in 0..<14 {
                if await Task.detached(operation: { Controller.holdsPage(window) }).value { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Whether the page has reached Accessibility yet. It sits a few levels down, in front of everything else in the window.
    nonisolated static func holdsPage(_ element: AXUIElement, depth: Int = 0) -> Bool {
        var role: CFTypeRef?, children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if role as? String == "AXWebArea" { return true }
        guard depth < 12, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { return false }
        return list.contains { holdsPage($0, depth: depth + 1) }
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
                        let held = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) ? string(element, kAXValueAttribute) ?? "" : ""
                        elements.append(Element(ax: element, role: role, label: String(label.prefix(60)), frame: local, value: String(held.prefix(200))))
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
        // The owner is working in this app, so the window can't be raised past them, and what Chrome last drew would pass for now.
        if isFront(win), coveredByItsOwn(win), drawsLikeChrome(win.pid) {
            return ["ok": false, "needsFront": true, "why": "covered", "id": win.id, "app": win.app, "error": "\(win.app) 的另一个窗口正盖在这个窗口上，它不更新被盖住的窗口，也不给里面的控件，现在看不到真实内容"]
        }
        if win.id == target?.id { goo.state = "reading"; enchant.setMood("reading") } else if isFront(win) { flash(win) }
        await askForAccessibleContent(win)
        await surface(win)
        let size = win.frame.size
        guard let image = await Hands.captureLive(win, scale: 2) else {
            return ["ok": false, "error": "这个窗口现在截不到（可能最小化了、应用被隐藏，或不在当前桌面）"]
        }
        let wide = max(size.width, 1), shrink = wide > 1600 ? 1600 / wide : 1
        let read = await Task.detached { (Hands.recognize(image, size: size), Hands.jpeg(image, scale: shrink / 2, quality: 0.72)) }.value
        var surveyed: (text: String, elements: [Element]) = ("", [])
        if trusted, let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) {
            let origin = win.frame.origin
            surveyed = await Task.detached { Controller.survey(window: window, origin: origin, size: size) }.value
        }
        elements[win.id] = surveyed.elements
        var result: [String: Any] = ["ok": true, "id": win.id, "app": win.app, "title": win.title, "imageScale": shrink]
        result["text"] = surveyed.text.count > 300 ? surveyed.text : read.0.map(\.text).joined(separator: "\n")
        result["lines"] = read.0.prefix(220).map { "(\(Int($0.box.minX)),\(Int($0.box.minY)),\(Int($0.box.width)),\(Int($0.box.height))) \($0.text)" }.joined(separator: "\n")
        result["elements"] = surveyed.elements.enumerated().map { "[\($0.offset)] \($0.element.role.dropFirst(2)) \"\($0.element.label)\"\($0.element.value.isEmpty || $0.element.value == $0.element.label ? "" : " = \"\($0.element.value)\"") (\(Int($0.element.frame.minX)),\(Int($0.element.frame.minY)),\(Int($0.element.frame.width)),\(Int($0.element.frame.height)))" }.joined(separator: "\n")
        // Accessibility only knows the windows on this desktop.
        if surveyed.elements.isEmpty, !openWindows().contains(where: { $0.id == win.id }) { result["note"] = "这个窗口不在当前桌面：只看得到画面，里面的东西按不了，换条路或先做别的。" }
        if let document = await documentPath(win) { result["document"] = document }
        if let picture = read.1 { result["image"] = picture }
        return result
    }

    // MARK: acting

    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func endSteps() {
        goo.reachGoal = nil
    }

    /// Chrome stops drawing a window that lies under its own windows, and takes away what is inside it. Under another app's it carries on (both seen 2026-11-01).
    /// Raised while the app is in the background, it only moves up among the app's own: what the owner has in front stays in front.
    @MainActor
    func surface(_ win: Win) async {
        var value: CFTypeRef?
        guard !isFront(win), let mine = axWindow(pid: win.pid, frame: win.frame, id: win.id),
              AXUIElementCopyAttributeValue(AXUIElementCreateApplication(win.pid), kAXWindowsAttribute as CFString, &value) == .success,
              let top = (value as? [AXUIElement])?.first, !CFEqual(top, mine) else { return }
        AXUIElementPerformAction(mine, kAXRaiseAction as CFString)
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    func isFront(_ win: Win) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid }

    /// Another window of the same app lies wholly over this one.
    func coveredByItsOwn(_ win: Win) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        // Front to back, so only what lies above it is looked at.
        for info in list {
            if info[kCGWindowNumber as String] as? Int == win.id { return false }
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? Int == Int(win.pid),
                  let raw = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { continue }
            if rect.contains(win.frame) { return true }
        }
        return false
    }

    /// Chrome and whatever runs on its engine, Electron too: they all carry a "<name> Framework.framework".
    func drawsLikeChrome(_ pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let parts = try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents/Frameworks").path) else { return false }
        return parts.contains { $0.hasSuffix(" Framework.framework") }
    }

    /// The real pointer and keyboard belong to the owner: only with this window in front and them idle may anything else touch them.
    func ownerIsAway(from win: Win) -> Bool {
        isFront(win) && !coveredByItsOwn(win) && [CGEventType.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel, .keyDown].allSatisfy {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) > 1
        }
    }

    /// The window may well be in front with only their hand moving: that is a moment, not a reason to go back to the model.
    @MainActor
    func ownerSettles(on win: Win) async -> Bool {
        for _ in 0..<30 {
            if ownerIsAway(from: win) { return true }
            guard isFront(win), !coveredByItsOwn(win) else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Three different things: saying "not in front" for all of them told the owner something false.
    func waitForFront(_ win: Win) -> [String: Any] {
        let why = !isFront(win) ? "not_front" : coveredByItsOwn(win) ? "covered" : "hand_moving"
        let said = ["not_front": "这一步后台做不了：要真键鼠，\(win.app) 不在前台",
                    "covered": "这一步后台做不了：\(win.app) 自己的另一个窗口盖着它",
                    "hand_moving": "这一步后台做不了：要真键鼠，\(win.app) 在前台但用户的手一直在动"][why] ?? ""
        return ["ok": false, "needsFront": true, "why": why, "id": win.id, "app": win.app, "error": said]
    }

    /// What sits at a point of this window, asked of its own app, which knows whatever else covers that spot on the screen.
    func element(at screen: CGPoint, in win: Win) -> AXUIElement? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(win.pid), Float(screen.x), Float(screen.y), &found) == .success, let found else { return nil }
        // Two windows of one app can overlap: the answer has to be from this one.
        var owner: CFTypeRef?
        if AXUIElementCopyAttributeValue(found, kAXWindowAttribute as CFString, &owner) == .success, let owner, let mine = axWindow(pid: win.pid, frame: win.frame, id: win.id), !CFEqual(owner, mine) { return nil }
        return found
    }

    func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent) == .success else { return nil }
        var at = CGPoint.zero, dimension = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &at)
        AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
        return CGRect(origin: at, size: dimension)
    }

    /// The smallest pressable thing at a point, as of the last look at this window: it holds even with something lying over that spot on the screen.
    func knownElement(at screen: CGPoint, in win: Win) -> AXUIElement? {
        (elements[win.id] ?? []).compactMap { known -> (AXUIElement, CGFloat)? in
            guard let box = frame(of: known.ax), box.contains(screen) else { return nil }
            return (known.ax, box.width * box.height)
        }.min { $0.1 < $1.1 }?.0
    }

    func menuItems(under element: AXUIElement, depth: Int = 0) -> [(ax: AXUIElement, label: String)] {
        var children: CFTypeRef?
        guard depth < 4, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { return [] }
        return list.flatMap { child -> [(ax: AXUIElement, label: String)] in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard role as? String == "AXMenuItem" else { return menuItems(under: child, depth: depth + 1) }
            // Apps put an option's words in any of these; Chrome leaves the title empty.
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].lazy.compactMap { name -> String? in
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(child, name as CFString, &value)
                return value as? String
            }.first { !$0.isEmpty }
            return label.map { [(child, $0)] } ?? []
        }
    }

    /// Presses what is at a point without touching the pointer. A press lands on the middle of an element, so a big one (a canvas, a whole page) can't take it.
    func pressBehindTheOwner(_ given: AXUIElement?, at screen: CGPoint, in win: Win) -> Bool {
        guard var current = given ?? knownElement(at: screen, in: win) ?? element(at: screen, in: win) else { return false }
        let tooBig = win.frame.width * win.frame.height / 4
        typingInto[win.id] = nil
        for _ in 0..<4 {
            guard let box = frame(of: current), box.width * box.height <= tooBig else { return false }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if textRoles.contains(role as? String ?? "") {
                AXUIElementSetAttributeValue(current, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                typingInto[win.id] = current
            }
            if AXUIElementPerformAction(current, kAXPressAction as CFString) == .success { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success, let parent else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    /// Keys sent to an app land in whichever of its windows holds the keyboard. Behind the owner's back this window can be made that one; with them in another window of the same app it can't.
    func keysLandIn(_ win: Win) -> Bool {
        guard let mine = axWindow(pid: win.pid, frame: win.frame, id: win.id) else { return false }
        let app = AXUIElementCreateApplication(win.pid)
        func holding() -> Bool {
            var focused: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success && focused.map { CFEqual($0, mine) } == true
        }
        if holding() { return true }
        if isFront(win) { return false }
        AXUIElementSetAttributeValue(mine, kAXMainAttribute as CFString, kCFBooleanTrue)
        return holding()
    }

    /// With the owner typing in this very window, words must not get mixed into theirs.
    func letTheOwnerFinishTyping(in win: Win) async {
        guard isFront(win) else { return }
        for _ in 0..<30 where CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Where words for this window go: the field last pressed there, or what holds the keyboard if that is in this window.
    func textField(of win: Win) -> AXUIElement? {
        if let known = typingInto[win.id], frame(of: known) != nil { return known }
        guard keysLandIn(win) else { return nil }
        var found: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(win.pid), kAXFocusedUIElementAttribute as CFString, &found) == .success, let found else { return nil }
        return (found as! AXUIElement)
    }

    func isPasswordField(of win: Win) -> Bool {
        guard let field = textField(of: win) else { return focusedSubrole(win.pid).subrole == "AXSecureTextField" }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == "AXSecureTextField"
    }

    func textValue(of field: AXUIElement) -> String? {
        var current: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &current) == .success ? current as? String : nil
    }

    /// Words of any length directly into the field, without the clipboard or Return, and read back. False: it doesn't let anyone.
    @MainActor
    func insertBehindTheOwner(_ text: String, in win: Win) async -> Bool {
        // An empty field in Chrome has no value to read at all.
        guard let field = textField(of: win) else { return false }
        let before = textValue(of: field) ?? ""
        // Chrome answers after the fact, so a read straight away says nothing has changed.
        func settles(on wanted: (String?) -> Bool) async -> Bool {
            for _ in 0..<8 {
                if wanted(textValue(of: field)) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        // A page with no cursor in it says yes to all of this too. Only a real text field can be believed without reading the words back (seen 2026-11-02).
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        let isTextField = textRoles.contains(role as? String ?? "")
        let probe = String(text.prefix(12))
        if AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           await settles(on: { isTextField ? ($0 ?? "") != before : ($0 ?? "").contains(probe) }) { return true }
        // Chrome says yes to that and does nothing; it does take a new value, with the selection worked out here.
        var range = CFRange(location: (before as NSString).length, length: 0), selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selected) == .success, let selected {
            AXValueGetValue(selected as! AXValue, .cfRange, &range)
        }
        let after = (before as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, after as CFString) == .success else { return false }
        // Taken, even if it can't be read back yet: typing it again would write it twice (seen 2026-11-01).
        return await settles(on: { $0 == after }) || isTextField
    }

    /// By key events to that app alone, read back where the app can say: some apps quietly ignore keys while in the background.
    func typeBehindTheOwner(_ text: String, in win: Win) async -> Bool {
        guard !win.isWeChat, keysLandIn(win) else { return false }
        let field = textField(of: win), before = field.flatMap { textValue(of: $0) }
        typeShort(text, to: win.pid)
        try? await Task.sleep(nanoseconds: 150_000_000)
        return before == nil || field.flatMap { textValue(of: $0) } != before
    }

    /// Scrolls what is at a point: by its scroll bar, or inside a web page by bringing the next thing out of view into view, which also works in a
    /// scrolling box within the page, and with the arrow keys as a last try. True only if something really moved.
    @MainActor
    func scrollBehindTheOwner(at screen: CGPoint, lines: Int, in win: Win) async -> Bool {
        guard var current = knownElement(at: screen, in: win) ?? element(at: screen, in: win) ?? axWindow(pid: win.pid, frame: win.frame, id: win.id) else { return false }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var found: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &found) == .success ? found as? [AXUIElement] ?? [] : []
        }
        func webArea(under element: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { return element }
            guard depth < 12 else { return nil }
            return children(element).lazy.compactMap { webArea(under: $0, depth + 1) }.first
        }
        var web: AXUIElement?
        for _ in 0..<24 {
            var role: CFTypeRef?, bar: CFTypeRef?, parent: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { web = current; break }
            if AXUIElementCopyAttributeValue(current, kAXVerticalScrollBarAttribute as CFString, &bar) == .success, let bar {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, &value) == .success, let now = value as? Double else { return false }
                return AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, max(0, min(1, now - Double(lines) * 0.01)) as CFNumber) == .success
            }
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success, let parent else { break }
            current = parent as! AXUIElement
        }
        guard let page = web ?? axWindow(pid: win.pid, frame: win.frame, id: win.id).flatMap({ webArea(under: $0) }), let seen = frame(of: page) else { return false }
        // The nearest thing out of view in that direction, and something to tell by whether anything moved.
        var next: (element: AXUIElement, distance: CGFloat)?, marker: (element: AXUIElement, y: CGFloat)?, visited = 0
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 40, visited < 4000 else { return }
            visited += 1
            if let box = frame(of: element), box.height > 0, box.width > 0, box.height < seen.height {
                if marker == nil { marker = (element, box.minY) }
                let distance = lines < 0 ? box.minY - seen.maxY : seen.minY - box.maxY
                if distance >= 0, distance < (next?.distance ?? .greatestFiniteMagnitude) { next = (element, distance) }
            }
            children(element).forEach { walk($0, depth + 1) }
        }
        walk(page, 0)
        func moved() async -> Bool {
            guard let marker else { return false }
            for _ in 0..<8 {
                if let box = frame(of: marker.element), abs(box.minY - marker.y) > 1 { return true }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            return false
        }
        if let next, AXUIElementPerformAction(next.element, "AXScrollToVisible" as CFString) == .success, await moved() { return true }
        guard keysLandIn(win) else { return false }
        AXUIElementSetAttributeValue(page, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        press(lines < 0 ? 121 : 116, flags: [], to: win.pid)
        return await moved()
    }

    // MARK: looking at what is under a click

    /// The label on whatever sits at a point in the window: from Accessibility, or else read off the picture.
    @MainActor
    func labelAt(_ point: CGPoint, in win: Win) async -> String {
        let screenPoint = CGPoint(x: win.frame.minX + point.x, y: win.frame.minY + point.y)
        var parts: [String] = []
        if var element = element(at: screenPoint, in: win) {
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
            // A search box or address bar is fine; so is Return on a dropdown or a button whose name says it is harmless,
            // and a new line in a document. Anywhere else, Enter may submit or send something: a text area in a web page can be a chat.
            let label = focusedLabel(win.pid)
            let inADocument = focus.role == "AXTextArea" && !drawsLikeChrome(win.pid) && !webBundles.contains(win.bundle)
            let harmless = flags.isEmpty && (["AXTextField", "AXComboBox", "AXSearchField", "AXPopUpButton", "AXMenuItem", "AXCheckBox", "AXRadioButton"].contains(focus.role)
                || inADocument || (focus.role == "AXButton" && !label.isEmpty && hits(label, riskyWords) == nil))
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

    /// To one app, past whatever is in front, or else (`to` left out) to the real keyboard. What the owner is holding down doesn't mix into the former.
    func press(_ key: CGKeyCode, flags: CGEventFlags, to pid: pid_t? = nil) {
        let source = pid == nil ? CGEventSource(stateID: .combinedSessionState) : CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = []   // so no modifier stays held for whatever comes next
        if let pid {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
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
        let ours = board.changeCount
        press(9, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 420_000_000)
        // The owner copied something meanwhile: that is what the clipboard should hold now.
        guard board.changeCount == ours else { return }
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
    }

    func typeShort(_ text: String, to pid: pid_t? = nil) {
        let source = pid == nil ? CGEventSource(stateID: .combinedSessionState) : CGEventSource(stateID: .privateState)
        func post(_ units: [UInt16]) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            if let pid {
                down?.postToPid(pid)
                up?.postToPid(pid)
            } else {
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            usleep(12000)
        }
        // By whole characters: an emoji cut in half types as garbage. To an app in the background, one each: Chrome drops anything more (seen 2026-11-01).
        let most = pid == nil ? 16 : 1
        var units: [UInt16] = []
        for character in text {
            let next = Array(String(character).utf16)
            if !units.isEmpty, units.count + next.count > most { post(units); units = [] }
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
        await surface(win)
        if win.id == target?.id { goo.state = "working"; enchant.setMood("working") }
        switch action {
        case "click", "double_click", "right_click":
            var point: CGPoint?, label = "", element: Element?
            if let ref = step["ref"] as? Int {
                guard let known = elements[win.id], known.indices.contains(ref) else { return ["ok": false, "error": "编号 \(ref) 已过期，重新看一下窗口"] }
                element = known[ref]
                label = known[ref].label
                point = CGPoint(x: known[ref].frame.midX, y: known[ref].frame.midY)
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
            // Only what the owner can see gets the show.
            if isFront(win) {
                reach(screen, in: win)
                if win.id == target?.id {
                    // It may have to hop over first: the press lands when the limb does.
                    for _ in 0..<55 where !goo.armArrived { try? await Task.sleep(nanoseconds: 20_000_000) }
                }
                tapMark(screen, in: win)
            }
            if action == "click", pressBehindTheOwner(element?.ax, at: screen, in: win) {
                // pressed without moving the pointer at all
            } else if action == "right_click", let found = element?.ax ?? self.element(at: screen, in: win),
                      AXUIElementPerformAction(found, kAXShowMenuAction as CFString) == .success {
                // the same menu, also without the pointer
            } else {
                guard await ownerSettles(on: win) else { return waitForFront(win) }
                await withRealPointer {
                    if action == "right_click" {
                        mouse(.rightMouseDown, at: screen, button: .right)
                        mouse(.rightMouseUp, at: screen, button: .right)
                    } else {
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
                }
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            return ["ok": true, "did": "点了 \(label.isEmpty ? "(\(Int(at.x)),\(Int(at.y)))" : label)"]
        case "type":
            let text = step["text"] as? String ?? ""
            if isPasswordField(of: win) { return refusal("这是密码框，密码由用户自己输入") }
            if !confirmed && askFirstBundles.contains(win.bundle) { return ["needs": "在 \(win.app) 里输入：\(text.prefix(80))"] }
            // A control character typed key by key can act as Return; pasted it is only text.
            let plain = !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
            await letTheOwnerFinishTyping(in: win)
            if await !insertBehindTheOwner(text, in: win) {
                if !plain { return await realPaste(text, in: win) }
                if await !typeBehindTheOwner(text, in: win) { return await realPaste(text, in: win) }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            return ["ok": true, "did": "输入了 \(text.prefix(30))"]
        case "key":
            let keys = (step["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if let stop = gateKey(keys, in: win, confirmed: confirmed) { return stop }
            let (flags, key) = chord(keys)
            guard let code = keyCodes[key] else { return ["ok": false, "error": "不认识这个键：\(keys)"] }
            await letTheOwnerFinishTyping(in: win)
            if keysLandIn(win) {
                press(code, flags: flags, to: win.pid)
            } else {
                guard await ownerSettles(on: win) else { return waitForFront(win) }
                await withRealPointer { press(code, flags: flags) }
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            return ["ok": true, "did": "按了 \(keys)"]
        case "scroll":
            let x = step["x"] as? Double ?? win.frame.width / 2, y = step["y"] as? Double ?? win.frame.height / 2
            guard CGRect(origin: .zero, size: win.frame.size).contains(CGPoint(x: x, y: y)) else { return ["ok": false, "error": "这个位置在窗口外面"] }
            let screen = CGPoint(x: win.frame.minX + x, y: win.frame.minY + y)
            let amount = Int32(max(-100, min(100, step["amount"] as? Double ?? -5)))
            if await !scrollBehindTheOwner(at: screen, lines: Int(amount), in: win) {
                // Sending the wheel to that window alone doesn't move WeChat or WPS (tried 2026-11-03): only with the owner already here and idle.
                guard await ownerSettles(on: win) else { return waitForFront(win) }
                await withRealPointer {
                    mouse(.mouseMoved, at: screen)
                    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                }
            }
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
            guard await ownerSettles(on: win) else { return waitForFront(win) }
            let from = CGPoint(x: win.frame.minX + x1, y: win.frame.minY + y1), to = CGPoint(x: win.frame.minX + x2, y: win.frame.minY + y2)
            await withRealPointer {
                mouse(.leftMouseDown, at: from)
                for k in 1...12 {
                    let t = CGFloat(k) / 12
                    mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                    usleep(14000)
                }
                mouse(.leftMouseUp, at: to)
            }
            return ["ok": true, "did": "拖动了"]
        case "choose":
            // A dropdown in one go, behind the owner's back. Its options only exist once it is open, and opening it renumbers everything after it, so this can't be two clicks in a batch.
            let wanted = step["text"] as? String ?? ""
            guard let ref = step["ref"] as? Int, !wanted.isEmpty else { return ["ok": false, "error": "choose 要给下拉框的 ref 和选项文字 text"] }
            guard let known = elements[win.id], known.indices.contains(ref) else { return ["ok": false, "error": "编号 \(ref) 已过期，重新看一下窗口"] }
            if let stop = gateClick(label: wanted, at: CGPoint(x: known[ref].frame.midX, y: known[ref].frame.midY), in: win, confirmed: confirmed) { return stop }
            guard AXUIElementPerformAction(known[ref].ax, kAXPressAction as CFString) == .success else { return ["ok": false, "error": "这个下拉框在后台打不开，换条路或先做别的"] }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let options = menuItems(under: known[ref].ax)
            guard let option = options.first(where: { $0.label == wanted }) ?? options.first(where: { $0.label.contains(wanted) }) else {
                AXUIElementPerformAction(known[ref].ax, kAXCancelAction as CFString)
                return ["ok": false, "error": "下拉框里没有“\(wanted)”。选项有：\(options.map(\.label).joined(separator: "、"))"]
            }
            guard AXUIElementPerformAction(option.ax, kAXPressAction as CFString) == .success else { return ["ok": false, "error": "“\(wanted)”在后台按不下去，换条路或先做别的"] }
            return ["ok": true, "did": "选了 \(option.label)"]
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(step["seconds"] as? Double ?? 1, 8)) * 1e9))
            return ["ok": true, "did": "等了一下"]
        default:
            return ["ok": false, "error": "不认识的动作：\(action)"]
        }
    }

    @MainActor
    func realPaste(_ text: String, in win: Win) async -> [String: Any] {
        guard await ownerSettles(on: win) else { return waitForFront(win) }
        await withRealPointer { await paste(text, files: []) }
        return ["ok": true, "did": "输入了 \(text.prefix(30))"]
    }

    /// While the real pointer is in use: the panel lets it through, the keyboard isn't left in the panel, and the pointer goes home after.
    @MainActor
    func withRealPointer(_ work: () async -> Void) async {
        operating = true
        if side.isKeyWindow { side.resignKey() }
        let home = cursor()
        await work()
        CGWarpMouseCursorPosition(home)
        operating = false
    }

    @MainActor
    func findText(_ text: String, in win: Win) async -> (text: String, box: CGRect)? {
        let want = Hands.normalize(text)
        if let hit = elements[win.id]?.first(where: { Hands.normalize($0.label) == want }) { return (hit.label, hit.frame) }
        guard let image = await Hands.captureLive(win, scale: 2) else { return nil }
        let size = win.frame.size
        let lines = await Task.detached { Hands.recognize(image, size: size) }.value
        return lines.first { Hands.normalize($0.text) == want } ?? lines.first { Hands.normalize($0.text).contains(want) }
    }

    // MARK: WeChat: opening a conversation for filling, without ever pressing Enter

    @MainActor
    func openChat(_ name: String, in win: Win) async -> [String: Any] {
        guard trusted else { return ["ok": false, "error": "没有辅助功能权限"] }
        // WeChat shows little to Accessibility, so this takes the real pointer, and waits for it.
        guard await ownerSettles(on: win) else { return waitForFront(win) }
        if side.isKeyWindow { side.resignKey() }
        let home = cursor()
        var left = home
        defer { if hypot(cursor().x - left.x, cursor().y - left.y) <= 6 { CGWarpMouseCursorPosition(home) } }
        // Typing a name and clicking a result must land in WeChat. If the owner took the pointer or switched away, it stops.
        func stillOurs() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid && hypot(cursor().x - left.x, cursor().y - left.y) <= 6
        }
        // Not a failure: it goes again when they let go. Whatever it typed in the search box must not be there for that.
        var typed = false
        var takenOver: [String: Any] {
            if typed { press(53, flags: [], to: win.pid) }
            return ["ok": false, "needsFront": true, "id": win.id, "app": win.app, "error": "用户 动了鼠标或切走了窗口，已停下，没有填"]
        }
        guard stillOurs() else { return takenOver }
        let want = Hands.normalize(name)
        // Already showing it: nothing to do.
        if let shown = await Controller.headerTitles(windowID: win.id, width: win.frame.width, previous: 0, listEnd: listEnd), shown.lines.contains(where: { Hands.sameChat(name, $0) }) {
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
            typed = true
            typeShort(name)
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let image = await Hands.captureLive(win, scale: 2, source: area) else { return ["ok": false, "error": "看不到搜索结果"] }
            lines = await Task.detached { Hands.recognize(image, size: area.size) }.value
            if lines.contains(where: { $0.box.minY < 40 && $0.box.minX < 260 && Hands.normalize($0.text).contains(want) }) { break }
        }
        // The first rows suggest web searches; real chats come under a section heading.
        let headings = ["功能", "联系人", "群聊", "最常使用", "最近使用", "聊天记录"]
        let below = lines.first { line in headings.contains { Hands.normalize(line.text) == $0 } }?.box.maxY ?? 0
        // Chats only: what comes under 聊天记录 is messages that mention the name.
        let history = lines.first { $0.box.minY >= below && Hands.normalize($0.text) == "聊天记录" }?.box.minY ?? .greatestFiniteMagnitude
        let rows = lines.filter { $0.box.minY >= below && $0.box.minY < history && Hands.sameChat(name, $0.text) }
        let exact = rows.first { Hands.normalize($0.text) == want }
        let names = Array(Set(rows.map(\.text)))
        // A short name that fits several people is not ours to choose between.
        if exact == nil, names.count > 1 {
            press(53, flags: [])
            return ["ok": false, "error": "微信里有几个“\(name)”：\(names.prefix(5).joined(separator: "、"))。问 用户 是哪一个，再填，chat 写全名"]
        }
        guard below > 0, let hit = exact ?? rows.first else {
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

    /// The owner got to the window a waiting step is for: the goo goes along, and nothing else moves. A panel they had open follows once the step is done,
    /// because opening it can shift the window under the click, and quietly, because their next key belongs to that input box.
    func followTo(_ win: Win) -> [String: Any] {
        guard win.id != target?.id, goo.mode == .attached || goo.mode == .open, !blockedOwners.contains(win.app) else { return ["ok": false] }
        reopenAfterFollow = sideOpen
        closeSide()
        goo.sleeping = false
        goo.puddle = false
        goo.peekSide = 0
        goo.splatUntil = 0
        goo.stick(to: win.frame.maxX, window: win.id)
        gooPanel.orderFront(nil)
        return ["ok": true]
    }

    /// The owner pressed a line about a job on another window: the goo leaps over and the window comes up as it lands, then the panel opens there.
    /// A WeChat job also opens its chat: the press is the owner asking for exactly that, and the panel follows the chat WeChat shows.
    func goTo(_ spec: String, chat: String) {
        Task { @MainActor in
            guard let win = await resolve(spec), !blockedOwners.contains(win.app) else {
                goo.fumble()
                web.evaluateJavaScript("wentNowhere('那个窗口已经关了')", completionHandler: nil)
                return
            }
            let reopen = sideOpen
            closeSide()
            goo.sleeping = false
            goo.puddle = false
            goo.peekSide = 0
            goo.splatUntil = 0
            let flight = win.id == target?.id ? 0 : goo.leap(to: win.id, frame: win.frame)
            // The window comes up as the goo comes down onto it.
            try? await Task.sleep(nanoseconds: UInt64(flight * 0.6 * 1e9))
            _ = await run(["command": "bringForward", "window": String(win.id)])
            try? await Task.sleep(nanoseconds: UInt64(max(0, flight * 0.4 - 0.25) * 1e9))
            if !chat.isEmpty, win.bundle == weChatBundle {
                // Already showing it is nothing to do; otherwise its search box, the pointer put back after. Not opened is only not opened: WeChat is in front either way.
                _ = await openChat(chat, in: win)
            }
            guard reopen, goo.mode == .attached, target?.id == win.id else { return }
            openQuietly = true
            web.evaluateJavaScript("setOpen(true)", completionHandler: nil)
        }
    }

    func followDone() {
        guard reopenAfterFollow else { return }
        reopenAfterFollow = false
        guard goo.mode == .attached else { return }
        openQuietly = true
        web.evaluateJavaScript("setOpen(true)")
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
