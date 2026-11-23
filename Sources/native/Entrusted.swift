// The hand-over loop. No model and no window contents: app + title (and, for a chat place, the open chat's name) are matched here,
// compared locally; only matching ids leave this process. Whether it may hand anything over now is Attention's (quiet).
// Stuck to a window it keeps to that window: only matches there count, and the body never goes elsewhere to hand something over.
import AppKit
import QuartzCore
import UserNotifications

final class Entrusted: NSObject, UNUserNotificationCenterDelegate {
    unowned let host: Controller
    var busy = false, pollAgain = false
    var items: [[String: Any]] = []
    private var recentlyPutDown: [[String: Any]] = []
    private var frontChatItems: [String] = []
    var lastMatched: [String] = []
    var offerID: String? {
        didSet {
            if oldValue != offerID { shownOffer = nil; touchedOffer = nil; softHovered = false }
            if (oldValue == nil) != (offerID == nil) { host.attention.rewatch() }
        }
    }
    var notificationNeeded = false
    var revision = -1.0, syncing = false
    var dueTimer: Timer?
    var wakeAt: Double?   // the next meeting's ten-minutes-before, when something is held for someone (`ladder.py`): the same one timer
    // While a promise is held, the app in front tells when its window or title changes (Accessibility); nothing is polled for it.
    var titleObserver: AXObserver?, titleApp: pid_t = 0, titleSoon: DispatchWorkItem?
    var chatBand = 0, chatWindow = 0, chatListEnd: CGFloat = 0, chatName = "", chatGeneration = 0
    var chatScans = 0, chatStable = 0
    var chatNotBefore: CFTimeInterval = 0
    var notificationActions: [(String, String)] = []
    var peeledOff = false   // just taken off a window: an occasion for what waited while it was stuck
    private var softHovered = false
    private var placeOffer = false
    private var shownOffer: String?, touchedOffer: String?
    private var respondingToTap: Set<String> = []
    let prefix = "tako.entrusted."

    init(_ host: Controller) { self.host = host; super.init() }

    func prepare() {
        guard !host.selfTest else { return }
        host.attention.load()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() {
        guard !host.selfTest else { return }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.items.isEmpty || self.revision < 0 else { return }
            if NSWorkspace.shared.frontmostApplication != NSRunningApplication.current { self.setFrontChatItems([]) }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != weChatBundle {
                self.chatGeneration += 1; self.chatBand = 0; self.chatWindow = 0; self.chatName = ""; self.chatListEnd = 0
            }
            self.watchTitles()
            self.poll()  // Also recheck notifications after returning from System Settings.
        }
        poll()
    }

    var quiet: Bool { host.attention.quiet }

    func observeHand(at point: V) {
        let goo = host.goo!
        guard let id = offerID, goo.handPhase == "offer", !quiet, !goo.handRect.isEmpty else { return }
        let near = goo.handSoft && goo.handRect.insetBy(dx: -5, dy: -5).contains(goo.L(point))
        let entered = near && !softHovered
        // Keep the request until the brain sees it, even if the pointer crosses the label between ticks.
        if near { softHovered = true }
        // Use the same reveal point as the buttons. Keep a brief touch until the brain sees it.
        let shown = placeOffer && !goo.handSoft && goo.handProgress > 0.95
        let touched = placeOffer && (near || (shown && goo.handHit(point) != nil))
        let changed = (shown && shownOffer != id) || (touched && touchedOffer != id)
        if shown { shownOffer = id }
        if touched { touchedOffer = id }
        if entered || changed {
            DispatchQueue.main.async { [weak self] in self?.wake() }
        }
    }

    func wake() {
        host.systemSources.refresh()
        guard !items.isEmpty else { return }
        if busy { pollAgain = true; return }
        busy = true
        host.attention.freshen()
        tick()
    }

    var holdsChatPlace: Bool { items.contains { item in (item["place"] as? [String: String]).map { $0["chat"]?.isEmpty == false || $0["project"]?.isEmpty == false } ?? false } }

    /// Stuck to the chat app in front, the chat is the one the panel settled on (`Controller.openChat`): one answer, read once, and nothing captured here.
    var stuckChatApp: Bool {
        let attached = host.goo.mode == .attached || host.goo.mode == .open
        return attached && (host.isWeChat || host.isDingTalk) && NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid
    }

    func noteChatActivity() {
        guard holdsChatPlace, !stuckChatApp else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == dingTalkBundle {
            // A click in DingTalk may have opened another chat: ask its name once the pane has changed. No capture, no timer.
            for delay in [0.15, 0.8] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.wake() } }
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == weChatBundle else { return }
        chatGeneration += 1
        chatNotBefore = CACurrentMediaTime()
        chatScans = 3; chatStable = 0
        for delay in [0.15, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.chatScans > 0, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == weChatBundle else { return }
                self.wake()
            }
        }
    }

    func schedule() {
        dueTimer?.invalidate(); dueTimer = nil
        host.attention.rewatch()
        watchTitles()
        guard !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if let due = (items.compactMap({ $0["due"] as? Double }) + [wakeAt].compactMap { $0 }).filter({ $0 > now }).min() {
            dueTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, due - now), repeats: false) { [weak self] _ in
                self?.schedule()
                self?.wake()
            }
        }
    }

    /// The front app's focused window and its title, told by the app through Accessibility while something is held.
    func watchTitles() {
        let front = NSWorkspace.shared.frontmostApplication
        let wanted = !items.isEmpty && host.trusted && front != nil && front != NSRunningApplication.current
        let pid = wanted ? front!.processIdentifier : 0
        guard pid != titleApp || (wanted && titleObserver == nil) else { return }
        if let observer = titleObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        titleObserver = nil; titleApp = pid
        guard wanted else { return }
        var made: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Entrusted>.fromOpaque(refcon).takeUnretainedValue().titleChanged()
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let observer = made else { return }
        let app = AXUIElementCreateApplication(pid), me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        titleObserver = observer
    }

    private func titleChanged() {
        titleSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.wake() }
        titleSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func poll() {
        guard host.url != nil, host.goo != nil else { return }
        if busy { pollAgain = true; return }
        busy = true
        host.post(path: "/entrusted/state", body: [:]) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = state["items"] as? [[String: Any]] else { self.busy = false; self.flushPoll(); return }
                self.wakeAt = state["wake"] as? Double
                Task { @MainActor in
                    _ = await self.sync(items, revision: state["revision"] as? Double ?? 0, ask: false,
                                        recent: state["recently_put_down"] as? [[String: Any]])
                    self.host.attention.freshen()
                    self.tick()
                }
            }
        }
    }

    // Front app and window metadata; the separate conditional WeChat path reads only its header.
    func frontPlace() -> (app: String, title: String, frame: CGRect?, fullscreen: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else {
            return ("", "", nil, true)
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.15)
        var value: CFTypeRef?
        var title = "", full = true, frame: CGRect?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            let window = value as! AXUIElement
            title = attr(window, kAXTitleAttribute) as? String ?? ""
            if let position = attr(window, kAXPositionAttribute), let size = attr(window, kAXSizeAttribute),
               CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var p = CGPoint.zero, s = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &p)
                AXValueGetValue(size as! AXValue, .cgSize, &s)
                frame = CGRect(origin: p, size: s)
            }
            full = host.attention.fullScreen(window, frame: frame)
        }
        return (app.localizedName ?? "", title, frame, full)
    }

    private func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func matches(_ place: [String: String], app: String, title: String, chat: String = "") -> Bool {
        // `names` and `project` only widen who or what a chat is about: by themselves they are no place.
        guard place.keys.contains(where: { $0 != "names" && $0 != "project" }) else { return false }
        return place.allSatisfy { key, word in
            // A person the hub knows by several names (`names`, one a line) is the same person under any of them.
            if key == "names" || key == "project" { return true }
            if key == "chat" { return ([word] + (place["names"] ?? "").split(separator: "\n").map(String.init)).contains { sameChatName($0, chat) } }
            let haystack = key == "app" ? app : title
            return !word.isEmpty && haystack.localizedStandardContains(word)
        }
    }

    /// Taken off the window it was stuck to: what waited for the desktop may come now.
    func peeled() {
        guard !items.isEmpty else { return }
        peeledOff = true
        wake()
    }

    func tick() {
        let front = items.isEmpty ? (app: "", title: "", frame: Optional<CGRect>.none, fullscreen: false) : frontPlace()
        let frontApp = NSWorkspace.shared.frontmostApplication
        if !quiet, holdsChatPlace, stuckChatApp {
            tick(front: front, chat: host.openChat)
            return
        }
        // DingTalk names its open chat through Accessibility: read only while a chat place is held and it is in front, compared here, never kept.
        if !quiet, holdsChatPlace, frontApp?.bundleIdentifier == dingTalkBundle, let pid = frontApp?.processIdentifier {
            tick(front: front, chat: DingTalk.openChat(pid: pid) ?? "")
            return
        }
        let needsChat = !quiet && frontApp?.bundleIdentifier == weChatBundle && holdsChatPlace
        guard needsChat, CGPreflightScreenCaptureAccess(), let app = NSWorkspace.shared.frontmostApplication else {
            chatBand = 0; chatWindow = 0; chatName = ""; chatListEnd = 0; chatScans = 0
            tick(front: front, chat: "")
            return
        }
        guard chatScans > 0 else { tick(front: front, chat: chatName); return }
        guard
              let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.width ?? 0) > 300
              }), let window = info[kCGWindowNumber as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else {
            chatBand = 0; chatWindow = 0; chatName = ""; chatListEnd = 0
            tick(front: front, chat: "")
            return
        }
        if window != chatWindow { chatWindow = window; chatBand = 0; chatName = ""; chatListEnd = 0 }
        let generation = chatGeneration, previous = chatBand, listEnd = chatListEnd, notBefore = chatNotBefore
        chatScans -= 1
        Task { [weak self] in
            guard let self else { return }
            let found = await self.host.headerCapture.read(windowID: window, width: frame.width, listEnd: listEnd, frontPID: app.processIdentifier, notBefore: notBefore)
            await MainActor.run {
                guard self.chatGeneration == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      self.holdsChatPlace, !self.quiet, !self.stuckChatApp else {
                    self.busy = false
                    self.flushPoll()
                    return
                }
                if let found {
                    self.chatStable = found.band == previous ? self.chatStable + 1 : 0
                    if self.chatStable >= 2 { self.chatScans = 0 }
                    self.chatBand = found.band; self.chatListEnd = found.listEnd > 0 ? found.listEnd : self.chatListEnd
                    if found.band != previous { self.chatName = found.lines.first ?? "" }
                } else { self.chatBand = 0; self.chatName = "" }
                self.tick(front: front, chat: self.chatName)
            }
        }
    }

    private func tick(front: (app: String, title: String, frame: CGRect?, fullscreen: Bool), chat: String) {
        let goo = host.goo!
        let attached = goo.mode == .attached || goo.mode == .open
        if !front.app.isEmpty {
            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let appNames: Set<String> = bundle == weChatBundle ? ["微信", "wechat", weChatBundle.lowercased()]
                : bundle == dingTalkBundle ? ["钉钉", "dingtalk", dingTalkBundle.lowercased()] : []
            setFrontChatItems(items.compactMap { item in
                guard var place = item["place"] as? [String: String], place["chat"] != nil else { return nil }
                if let app = place["app"], appNames.contains(app.lowercased()) { place.removeValue(forKey: "app") }
                return Self.matches(place, app: front.app, title: front.title, chat: chat) ? item["id"] as? String : nil
            })
        }
        // Stuck to a window, only that window is a place: an app the owner went to meanwhile waits for the desktop.
        let here = !attached || NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid
        let currentMatches = !here ? [] : items.compactMap { item -> String? in
            guard let place = item["place"] as? [String: String], Self.matches(place, app: front.app, title: front.title, chat: chat) else { return nil }
            return item["id"] as? String
        }
        let near = !here ? [] : items.compactMap { item -> String? in
            guard let place = item["place"] as? [String: String], groupConcerns(place, chat: chat) else { return nil }
            return item["id"] as? String
        }
        let departed = front.app.isEmpty ? [] : lastMatched.filter { !currentMatches.contains($0) }
        let arriving = currentMatches.contains { !lastMatched.contains($0) }
        if !front.app.isEmpty { lastMatched = currentMatches }
        let matched = front.app.isEmpty ? lastMatched : currentMatches
        let returned = host.attention.takeReturned("entrusted")
        let peeled = peeledOff && !attached
        if peeled { peeledOff = false }
        host.post(path: "/entrusted/tick", body: ["matched": matched, "near": near, "departed": departed, "returned": returned, "peeled": peeled, "attached": attached,
                                                 "fullscreen": front.fullscreen, "muted": quiet,
                                                 "typing": CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5,
                                                 "arriving": arriving || returned || peeled,
                                                 "away": host.attention.away, "hovered": goo.handSoft ? softHovered : goo.handHit(host.pointer()) != nil,
                                                 "shown": shownOffer ?? "", "touched": touchedOffer ?? "",
                                                 "replying": host.speaking.replying]) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                defer { self.flushPoll() }
                guard let data, let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                self.apply(state, frame: front.frame)
                let actions = self.notificationActions
                self.notificationActions = []
                for (id, action) in actions { self.respond(id, action: action) }
            }
        }
    }

    private func flushPoll() {
        guard !busy, pollAgain else { return }
        pollAgain = false
        poll()
    }

    func apply(_ state: [String: Any], frame: CGRect?) {
        let goo = host.goo!
        goo.carrying = state["holding"] as? Bool ?? false
        // The hub's to-dos are matched here but never listed or counted: they live in the hub, and come up only as a bubble.
        let listed = items.filter { $0["quiet"] as? Bool != true }
        goo.heldCount = state["count"] as? Int ?? listed.count
        goo.heldPreview = listed.first?["text"] as? String ?? ""
        // The same set the count counts, in the panel's order (`native_state`).
        goo.heldItems = listed.compactMap { item in (item["id"] as? String).map { (id: $0, text: item["text"] as? String ?? "") } }
        if quiet {
            if offerID != nil { offerID = nil; goo.takeHandBack("ignored") }
            return
        }
        // A small group about something it has: no bubble, only a little hop by the count.
        if state["nudge"] as? Bool == true, offerID == nil { goo.kick(40); goo.pop = 0.5; host.wakeLoop() }
        if let offer = state["offer"] as? [String: Any], let id = offer["id"] as? String {
            placeOffer = offer["reason"] as? String == "place"
            goo.handChoice = offer["choice"] as? String ?? ""
            let soft = offer["soft"] as? Bool ?? false
            let newOffer = id != offerID
            if newOffer {
                offerID = id
                goo.handHome = nil
                // Stuck or free, it hands things over where it is. Free, it used to fly to the window in front and hang
                // there in mid-air until answered, which is not how a pet on the floor behaves.
                goo.presentHand(text: offer["text"] as? String ?? "", soft: soft)
                if soft {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in
                        guard let self, self.offerID == id, self.host.goo.handSoft else { return }
                        self.wake()
                    }
                }
                host.wakeLoop()
            } else if !soft && goo.handSoft {
                goo.expandHand()
                host.wakeLoop()
            }
            goo.handText = offer["text"] as? String ?? ""
        } else if offerID != nil {
            offerID = nil
            goo.takeHandBack("ignored")
        }
    }

    func tapped(_ action: String) {
        // The count is about what it holds: a press opens the list where it is. Talking to it is the body's double click.
        if action == "held" { host.goo.showHeld(!host.goo.heldOpen); return }
        if action == "list" { return }
        for answer in ["done", "later"] where action.hasPrefix(answer + ":") {
            answerTap(String(action.dropFirst(answer.count + 1)), answer)
            return
        }
        guard let id = offerID else { return }
        // Something that has stood still is a question with three answers: 今天做, 改天, 不做了.
        if host.goo.handChoice == "stalled", action == "done" { respondToTap(id, action: "today"); return }
        if action == "expand" {
            softHovered = true
            wake()
            return
        }
        respondToTap(id, action: action)
    }

    /// A press anywhere but on the open list puts it away. The press itself goes on to whatever it was meant for.
    func pressed(at point: V) {
        guard let goo = host.goo, goo.heldOpen, goo.handHit(point) == nil else { return }
        goo.showHeld(false)
    }

    /// What a row's button sends. The scenes replace it to see the id and the answer; nothing else does.
    lazy var answerTap: (String, String) -> Void = { [unowned self] id, action in self.respondToTap(id, action: action) }

    func respondToTap(_ id: String, action: String) {
        guard host.url != nil, respondingToTap.insert(id).inserted else { return }
        respond(id, action: action) { [weak self] in
            self?.respondingToTap.remove(id)
        }
    }

    /// Mark a to-do complete, open its destination, or put it off until the next occasion.
    func respond(_ id: String, action: String, finished: (() -> Void)? = nil) {
        if action == "look" {
            host.lookAtEntrusted(id, finished: finished)
            return
        }
        host.post(path: "/entrusted/respond", body: ["id": id, "action": action]) { [weak self] data in
            DispatchQueue.main.async {
                defer { finished?() }
                guard let self, let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true else { return }
                if action != "restore" { self.withdrawNotification(id) }
                if self.offerID == id {
                    self.offerID = nil
                    if let line = reply["say"] as? String { self.host.goo.sayThenTuck(line) } else { self.host.goo.takeHandBack(action == "cancel" ? "later" : action) }
                }
                else if action == "later", self.host.goo.heldOpen, let line = reply["say"] as? String {
                    // 稍后 on a row of the list keeps that row held, so nothing would seem to happen: the list goes in and it
                    // says when the thing comes back, as the card does.
                    self.host.goo.showHeld(false)
                    self.host.goo.sayThenTuck(line)
                }
                _ = self.host.attention.takeReturned("entrusted")  // The tap itself doesn't count as a return from being away.
                self.poll()
            }
        }
    }

    func withdrawNotification(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prefix + id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [prefix + id])
    }

    @MainActor
    func sync(_ items: [[String: Any]], revision incoming: Double, ask: Bool, recent: [[String: Any]]? = nil) async -> [String: Any] {
        guard !host.selfTest else { return ["ok": true, "scheduled": []] }
        while syncing { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard incoming >= revision else { return ["ok": false, "scheduled": []] }
        syncing = true
        defer { syncing = false }
        revision = incoming; self.items = items
        if let recent { recentlyPutDown = recent }
        if holdsChatPlace && chatWindow == 0 { noteChatActivity() }
        if !items.isEmpty { host.teaching.hide(keepingFirst: true); host.learn("entrust") }
        tellHeldItems()
        schedule()
        if ask && !items.isEmpty { DispatchQueue.main.async { [weak self] in self?.wake() } }
        let center = UNUserNotificationCenter.current()
        if ask, items.contains(where: { $0["due"] is Double }) {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert]) }
        }
        let settings = await center.notificationSettings()
        let allowed = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && settings.alertSetting != .disabled
        notificationNeeded = !allowed && items.contains { $0["due"] is Double }
        tellNotification()
        let actions = [UNNotificationAction(identifier: "done", title: "✓ 做完了"), UNNotificationAction(identifier: "look", title: "打开", options: [.foreground]),
                       UNNotificationAction(identifier: "later", title: "稍后")]
        center.setNotificationCategories([UNNotificationCategory(identifier: "entrusted", actions: actions, intentIdentifiers: [])])
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let timed = items.filter { $0["due"] is Double }
        let wanted = Set(timed.compactMap { ($0["id"] as? String).map { prefix + $0 } })
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !wanted.contains($0) })
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) && !wanted.contains($0) })
        var scheduled: [String] = []
        for item in timed {
            guard allowed, let id = item["id"] as? String, let due = item["due"] as? Double else { continue }
            let key = prefix + id
            let text = item["text"] as? String ?? ""
            if let old = pending.first(where: { $0.identifier == key }), old.content.userInfo["due"] as? Double == due, old.content.body == text {
                scheduled.append(id); continue
            }
            if delivered.contains(where: { $0.request.identifier == key && $0.request.content.userInfo["due"] as? Double == due && $0.request.content.body == text }) {
                scheduled.append(id); continue
            }
            guard AttentionPolicy.shouldSchedule(due: due, now: Date().timeIntervalSince1970) else {
                // The held item remains eligible in the next safe foreground tick.
                center.removePendingNotificationRequests(withIdentifiers: [key])
                center.removeDeliveredNotifications(withIdentifiers: [key])
                continue
            }
            center.removeDeliveredNotifications(withIdentifiers: [key])
            let content = UNMutableNotificationContent()
            content.title = "Tako"
            content.body = text
            content.categoryIdentifier = "entrusted"
            content.userInfo = ["id": id, "due": due]
            content.interruptionLevel = .active  // Respect the owner's Focus settings; no critical/time-sensitive bypass.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due - Date().timeIntervalSince1970), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
                scheduled.append(id)
            } catch { /* Report the actual result; a persisted promise is not proof of a scheduled notification. */ }
        }
        return ["ok": true, "scheduled": scheduled, "allowed": allowed]
    }

    func tellNotification() {
        guard host.loaded else { return }
        host.web.evaluateJavaScript("setNotificationNeeded(\(notificationNeeded))")
    }

    private func setFrontChatItems(_ ids: [String]) {
        guard ids != frontChatItems else { return }
        frontChatItems = ids
        tellHeldItems()
    }

    func tellHeldItems() {
        guard host.loaded, let data = try? JSONSerialization.data(withJSONObject: [items.filter { $0["quiet"] as? Bool != true }, recentlyPutDown, frontChatItems]),
              let json = String(data: data, encoding: .utf8) else { return }
        host.web.evaluateJavaScript("setHeldItems(...\(json))", completionHandler: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix(prefix) { completionHandler([.banner, .list]) }
        else { host.updater.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.identifier.hasPrefix(prefix) else {
            host.updater.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }
        if let id = response.notification.request.content.userInfo["id"] as? String {
            let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "look" : response.actionIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.host.url == nil { self.notificationActions.append((id, action)) }
                else { self.respond(id, action: action) }
            }
        }
        completionHandler()
    }
}
