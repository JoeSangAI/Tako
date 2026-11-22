// Which conversation a chat app is showing: WeChat's read off the top strip of its window, DingTalk's asked through Accessibility (DingTalk.swift).
import AppKit
import ScreenCaptureKit
import Vision
import QuartzCore

extension Controller {
    // MARK: which conversation is open
    //
    // WeChat exposes nothing through Accessibility, so the only thing read is the top strip of its
    // window, on this Mac, and only the title in it leaves this function. The chat itself is never captured
    // unless the owner asks it to look.
    //
    // Which chat is open has one answer, the brain's (`Chats._confirm`), for the panel, a fill's check and the promises compared here.
    // A click on the stuck chat app's window, or the app coming forward, may change it: the brain hears `looking` at once and nothing goes under the
    // chat before. Then the strip is read until two reads agree (WeChat may still be drawing the chat just clicked), at most 2.5 s; a read that already
    // names a chat the brain knows is sent straight away. Each read is one-shot and follows an event: no timer runs while nothing happens.
    func noteHeaderActivity(switching: Bool = false) {
        let front = NSWorkspace.shared.frontmostApplication
        guard [weChatBundle, dingTalkBundle].contains(front?.bundleIdentifier) else { return }
        entrusted.noteChatActivity()
        guard isWeChat || isDingTalk, (goo.mode == .attached || goo.mode == .open), front?.processIdentifier == pid, !desktopPanel else { return }
        let now = CACurrentMediaTime()
        if switching { tellChat(["looking": true, "bundle": bundle]) }
        if isDingTalk {
            // DingTalk tells through Accessibility, in milliseconds: look right after the click and once more when its pane has redrawn.
            headerClickAt = now
            for delay in [0.12, 0.6] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.followDingTalk(last: delay > 0.5) } }
            return
        }
        // Typing or scrolling only starts a round when none is under way; a click starts a new one, and reads from before it don't count.
        guard switching || now >= headerUntil else { return }
        headerClickAt = now; headerStable = 0; headerUntil = now + 2.5; headerRoundBand = 0
        if switching { headerLooking = true }
        scheduleHeaderRead(after: 0.12)
    }

    /// Whether the pointer is over the window it is stuck to: a click anywhere else (the panel, another app) changes no chat.
    var pointerOnTarget: Bool {
        guard let id = target?.id else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == id
    }

    func scheduleHeaderRead(after delay: Double) {
        let due = CACurrentMediaTime() + delay
        guard headerDue == 0 || due < headerDue else { return }
        headerDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.headerDue == due else { return }
            self.headerDue = 0
            self.headerLate = Int((CACurrentMediaTime() - due) * 1000)   // how long the main thread kept the read waiting
            self.readHeaderIfDue(title: false)
        }
    }

    /// Tells the brain which chat a chat app shows, numbered so a late answer never overrides a newer one. The reply carries the brain's answer:
    /// kept for the promises compared here, and the panel redrawn at once. The timing line holds only milliseconds.
    func tellChat(_ body: [String: Any], timing: String = "") {
        headerSeq += 1
        let seq = headerSeq, window = target?.id
        let looking = body["looking"] as? Bool == true, sent = CACurrentMediaTime()
        if looking { openChat = "" }
        post(path: "/current", body: body.merging(["seq": [headerRun, seq]]) { a, _ in a }) { [weak self] data in
            let answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async {
                guard let self, self.headerSeq == seq, self.target?.id == window else { return }
                // Past half a second unconfirmed the panel says 正在看…; under it, it goes straight from one name to the next.
                self.web.evaluateJavaScript(looking ? "window.tickSoon && tickSoon(550)" : "window.tickSoon && tickSoon(0)", completionHandler: nil)
                if answer["looking"] as? Bool != true, let name = answer["chat"] as? String, name != self.openChat {
                    self.openChat = name
                    self.entrusted.wake()
                }
                let brainMs = answer["ms"] as? Int ?? -1
                if !timing.isEmpty { self.log("\(timing) brain=\(brainMs)ms total=\(Int((CACurrentMediaTime() - sent) * 1000))ms") }
            }
        }
    }

    /// The chat open in the DingTalk window it is stuck to; the brain hears of a change, and of a name it can't read once the pane has settled.
    func followDingTalk(last: Bool = false) {
        guard isDingTalk, goo.mode == .attached || goo.mode == .open, !desktopPanel else { return }
        let began = CACurrentMediaTime()
        let name = DingTalk.openChat(pid: pid) ?? ""
        // The first look says a name it reads (the same one too: that settles a click inside the chat); the last one says whatever it found, nothing included.
        guard last || !name.isEmpty else { return }
        tellChat(["bundle": dingTalkBundle, "chat": name],
                 timing: "chat dingtalk since-click=\(Int((began - headerClickAt) * 1000))ms read=\(Int((CACurrentMediaTime() - began) * 1000))ms")
    }

    /// `title`: the time has come to look at an ordinary window's title again (every couple of seconds while stuck on).
    func readHeaderIfDue(title: Bool) {
        guard !desktopPanel else { return }
        // Any other window: its title is all that changes, and the system already tells us that.
        if title, !isWeChat, (goo.mode == .attached || goo.mode == .open), let id = target?.id,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first {
            reportStuck(title: info[kCGWindowName as String] as? String ?? "")
        }
        guard isWeChat, goo.mode == .attached || goo.mode == .open, let current = target,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            // WeChat left the front mid-round: nothing was read that says the chat changed, so the brain stops waiting.
            if headerLooking, !title { headerLooking = false; tellChat(["titles": NSNull(), "left": true]) }
            return
        }
        guard canCapture else { return }
        if headerBusy { scheduleHeaderRead(after: 0.1); return }
        headerBusy = true
        let id = current.id, width = current.frame.width, listEnd = listEnds[current.id] ?? 0, previous = headerRoundBand, frontPID = pid
        let capture = headerCapture, began = CACurrentMediaTime(), clickAt = headerClickAt, late = headerLate
        Task.detached { [weak self] in
            let titles = await capture.read(windowID: id, width: width, listEnd: listEnd, frontPID: frontPID, notBefore: clickAt)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.headerBusy = false
                let now = CACurrentMediaTime()
                // The goo moved to another window while this one was read: its title is not that window's.
                guard self.target?.id == id, !self.desktopPanel, NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else {
                    if self.headerLooking, self.target?.id == id { self.headerLooking = false; self.tellChat(["titles": NSNull(), "left": true]) }
                    return
                }
                guard let titles, clickAt == self.headerClickAt else {
                    // Failed, or started before the latest click: read again while the round lasts; at its end, the brain hears nothing could be read.
                    if now < self.headerUntil { self.scheduleHeaderRead(after: 0.2) }
                    else if self.headerLooking { self.headerLooking = false; self.tellChat(["titles": [String](), "settled": true]) }
                    return
                }
                self.headerStable = titles.band == previous ? self.headerStable + 1 : 0
                self.headerRoundBand = titles.band
                if titles.listEnd > 0 { self.listEnds[id] = titles.listEnd }
                let settled = self.headerStable >= 1 || now >= self.headerUntil
                let changed = titles.band != self.sentBand
                if (changed && !titles.lines.isEmpty) || (settled && (self.headerLooking || changed)) {
                    self.sentBand = titles.band
                    if settled { self.headerLooking = false }
                    self.tellChat(["titles": titles.lines + titles.others, "settled": settled],
                                  timing: "chat wechat since-click=\(Int((began - clickAt) * 1000))ms wait=\(late)ms read=\(Int((now - began) * 1000))ms settled=\(settled ? 1 : 0)")
                }
                if !settled { self.scheduleHeaderRead(after: 0.2) }
            }
        }
    }

    static func headerTitles(windowID: Int, width: CGFloat, previous: Int, listEnd known: CGFloat, onlyFrontPid: pid_t? = nil) async -> (band: Int, lines: [String], others: [String], listEnd: CGFloat)? {
        do {
            if let pid = onlyFrontPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return nil }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: width, height: 62)
            config.width = Int(width * 2)
            config.height = 124
            config.showsCursor = false
            // A WeChat window closed or hidden mid-read never answers; waiting on it left every later read "busy" until a restart.
            if let pid = onlyFrontPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return nil }
            guard let image = await Hands.shot(SCContentFilter(desktopIndependentWindow: window), config) else { return nil }
            if let pid = onlyFrontPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return nil }
            guard let bytes = image.dataProvider?.data as Data? else { return nil }
            // Data's own hash only looks at its first bytes, which never change here: hash all of it.
            let band = bytes.withUnsafeBytes { raw -> Int in
                var value: UInt64 = 14695981039346656037
                for byte in raw { value = (value ^ UInt64(byte)) &* 1099511628211 }
                return Int(truncatingIfNeeded: value)
            }
            if band == previous { return (band, [], [], known) }   // same pixels: no OCR, the caller retains its current title

            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results ?? []).compactMap { o -> (x: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, text: String, others: [String])? in
                let guesses = o.topCandidates(3).map(\.string)
                return guesses.first.map { (o.boundingBox.minX * width, o.boundingBox.maxX * width, 1 - o.boundingBox.maxY, 1 - o.boundingBox.minY, $0, Array(guesses.dropFirst())) }
            }
            // Everything left of the end of the search box is the chat list, not the title. While the owner types a search the box
            // shows their words instead of 搜索, and those would be read as the title: the list keeps its width, so the last edge seen holds.
            let searchEnd = found.first(where: { $0.text.contains("搜索") })?.right ?? 0
            let edge = searchEnd > 0 ? searchEnd : known
            let right = found.filter { $0.x > edge && !$0.text.contains("搜索") }
            // The strip also catches the top of the first message, half its height cut off, which reads as a long string of nonsense: longer than
            // the title, so it came first and an unnamed group was matched by it. The title is the top row; messages are always below it.
            let row = right.min { $0.top < $1.top }
            let title = right.filter { row != nil && ($0.top + $0.bottom) / 2 < row!.bottom }.sorted { $0.text.count > $1.text.count }
            // A misread character is often right in the reader's second guess, kept apart: only following the chat may lean on it.
            return (band, title.map(\.text), title.flatMap(\.others), searchEnd)
        } catch {
            return nil
        }
    }

    func setWatching(_ on: Bool) {
        if on { panelPlace = .window }
        if !on { listener?.stop(); listener = nil }  // peeled off, it stops listening too; the server files what it heard
        if on { sentBand = 0; openChat = ""; noteHeaderActivity(switching: true) }
        post(path: "/watching", body: ["on": on])
    }
}
