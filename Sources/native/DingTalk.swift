// DingTalk, read through Accessibility (read only): which chat is open, and the messages its window shows with who said each.
// Nothing is captured, recognised from pixels, kept or logged. The chat name is compared on this Mac for a promise's place, or sent to the
// brain while stuck on DingTalk so the panel follows the chat; the messages go to the brain only when the owner speaks there.
// Found in DingTalk's own tree: the chat pane is the split view `ChatSplitView`; its messages are
// one table, each begun by the sender's avatar, the owner's on the right with a read receipt under it, everyone else's on the left; a
// full-width line is the time. When the tree is not like that any more it reads nothing: no match and an honest "couldn't read", never a screenshot.
import AppKit

let dingTalkBundle = "com.alibaba.DingTalkMac"

enum DingTalk {
    struct Node { let role: String; let frame: CGRect; let text: String }
    struct Message { let me: Bool; let who: String; let time: String; let text: String }

    /// The open chat's name, nil when the window can't be read.
    static func openChat(pid: pid_t) -> String? { read(pid: pid, messages: false)?.chat }

    /// The chat's name and the messages its window shows, top to bottom.
    static func read(pid: pid_t, messages: Bool) -> (chat: String, messages: [Message])? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let window = (attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute)).map { $0 as! AXUIElement }
            ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window, let split = find(in: window, depth: 4, where: { identifier($0) == "ChatSplitView" }, through: ["AXSplitGroup", "AXGroup"]),
              let table = find(in: split, depth: 4, where: { role($0) == "AXTable" }, through: ["AXSplitGroup", "AXGroup", "AXScrollArea"]),
              let scroller = attr(table, kAXParentAttribute).map({ $0 as! AXUIElement }) else { return nil }
        let pane = frame(scroller)
        // The chat's name: the topmost line of the pane's own header, above the messages and not over the chat list on the left.
        let header = children(split).compactMap { e -> (CGRect, String)? in
            guard role(e) == "AXStaticText", let text = attr(e, kAXValueAttribute) as? String, !text.isEmpty else { return nil }
            let f = frame(e)
            return f.minX >= pane.minX && f.maxY <= pane.minY + 2 ? (f, text) : nil
        }.min { ($0.0.minY, $0.0.minX) < ($1.0.minY, $1.0.minX) }
        guard let name = header?.1.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard messages else { return (name, []) }
        let nodes = children(table).map { e -> Node in
            let r = role(e)
            let text = (r == "AXButton" ? attr(e, kAXTitleAttribute) : attr(e, kAXValueAttribute)) as? String ?? ""
            return Node(role: r, frame: frame(e), text: text)
        }
        return (name, Self.messages(nodes, pane: pane))
    }

    /// Who said what, from the table's nodes alone: pure, so the test can hold it (tests/test_guards.py).
    /// Each message starts at its sender's avatar, a square picture at the pane's edge: on the right the owner's, on the left anyone else's.
    /// In a group the sender's name is a small button just right of their avatar, with the message's time beside it.
    /// A text is a message of its own; a card's lines, a file and a picture make one message of what that avatar sent.
    static func messages(_ nodes: [Node], pane: CGRect) -> [Message] {
        var out: [Message] = []
        var mine: Bool?, who = "", time = "", avatar = CGRect.null, extra: [String] = []
        func flush() {
            if let me = mine, !extra.isEmpty { out.append(Message(me: me, who: me ? "" : who, time: time, text: extra.joined(separator: "｜"))) }
            extra = []
        }
        let clock = try! NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}$")
        for node in nodes.filter({ $0.frame.width > 1 && $0.frame.height > 1 }).sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            let f = node.frame, text = node.text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let atEdge = f.minX - pane.minX < 40 || pane.maxX - f.maxX < 40
            if node.role == "AXImage", abs(f.width - f.height) < 2, (24...48).contains(f.width), atEdge {
                // The avatar, drawn as a picture and its ring: one message's sender.
                let side = f.midX > pane.midX
                if side == mine, f.minY - avatar.minY < 12 { continue }
                flush()
                mine = side; who = ""; avatar = f
            } else if node.role == "AXStaticText", f.width >= pane.width * 0.8 {
                flush()
                if !text.isEmpty { time = text }   // the time line across the pane
                mine = nil
            } else if node.role == "AXImage", f.width >= 60, f.height >= 40, mine != nil {
                extra.append("〔图片〕")   // a picture has no words to read; it is still something said
            } else if text.isEmpty {
                continue
            } else if node.role == "AXButton", f.height <= 22, f.width >= 10 {
                // Beside someone's avatar: their name, then the time. Below the owner's: the read receipt. Neither is a message.
                guard mine == false, abs(f.minY - avatar.minY) < 14 else { continue }
                if clock.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { time = text }
                else if who.isEmpty, f.minX - avatar.maxX < 30 { who = text }
            } else if node.role == "AXTextArea" {
                flush()
                let me = mine ?? (f.midX > pane.midX)
                out.append(Message(me: me, who: me ? "" : who, time: time, text: text))
            } else if mine != nil, node.role == "AXButton", f.height >= 30, f.width >= 60 {
                extra.append("〔文件或卡片〕\(text)")
            } else if mine != nil, node.role == "AXStaticText", f.width >= 40 {
                extra.append(text)   // a line of a card
            }
        }
        flush()
        return out
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
    private static func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
    private static func identifier(_ e: AXUIElement) -> String { attr(e, "AXIdentifier") as? String ?? "" }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let a = attr(e, kAXPositionAttribute), let b = attr(e, kAXSizeAttribute), CFGetTypeID(a) == AXValueGetTypeID(), CFGetTypeID(b) == AXValueGetTypeID() {
            AXValueGetValue(a as! AXValue, .cgPoint, &p); AXValueGetValue(b as! AXValue, .cgSize, &s)
        }
        return CGRect(origin: p, size: s)
    }
    /// Breadth first, only down through containers of the given roles: a few dozen Accessibility calls, not the whole window.
    private static func find(in root: AXUIElement, depth: Int, where wanted: (AXUIElement) -> Bool, through: Set<String>) -> AXUIElement? {
        var level = children(root)
        for _ in 0..<depth {
            if let hit = level.first(where: wanted) { return hit }
            level = level.filter { through.contains(role($0)) }.flatMap(children)
            if level.isEmpty { return nil }
        }
        return nil
    }
}
