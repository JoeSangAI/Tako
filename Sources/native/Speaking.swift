// The owner's speaking key. Audio stays in memory and Speech is explicitly on-device.
import AppKit
import AVFoundation
import Speech

// Hand-drawn ink rather than a system text-field bezel.
final class SpeakingInk: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 14, y: 4))
        path.curve(to: NSPoint(x: w - 13, y: 5), controlPoint1: NSPoint(x: w * 0.32, y: 1), controlPoint2: NSPoint(x: w * 0.72, y: 7))
        path.curve(to: NSPoint(x: w - 5, y: h - 15), controlPoint1: NSPoint(x: w + 2, y: 8), controlPoint2: NSPoint(x: w - 3, y: h * 0.55))
        path.curve(to: NSPoint(x: 15, y: h - 5), controlPoint1: NSPoint(x: w - 7, y: h + 1), controlPoint2: NSPoint(x: w * 0.3, y: h - 3))
        path.curve(to: NSPoint(x: 14, y: 4), controlPoint1: NSPoint(x: 1, y: h - 7), controlPoint2: NSPoint(x: 2, y: 13))
        path.close()
        NSColor(calibratedWhite: 0.98, alpha: 0.98).setFill(); path.fill()
        NSColor(calibratedWhite: 0.13, alpha: 0.95).setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}

private final class SpeakingPlaceholder: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class Speaking: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    unowned let host: Controller
    private var session = false, listening = false, tapInstalled = false, finishing = false
    private var gesture = SpeakingKey()
    private var idleTimer: Timer?, lastActivity = CACurrentMediaTime()
    private var generation = 0
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var draft = ""
    /// What the recognizer gave this time (Heard.swift); one line of numbers about it goes to panel.log when it ends.
    private var heard = Heard(), reporting = false, localeID = "-"
    private let buffers = BufferCount()
    private var transcript: String { heard.text }
    private var handing: String?
    private var panel: SideWindow?
    private var hinting = false
    private var field: NSTextField?
    private var placeholder: NSTextField?
    private var hearing: ListeningView?
    private var heardLevel: CGFloat = 0, lastTrack = CACurrentMediaTime(), meter = VoiceMeter()
    /// The answer in this same bubble (desktop, panel closed). `replyToken` makes every one-shot fade belong to one showing.
    private var reply: ReplyView?
    private var replyToken = 0, replyHover = false, replyDue = false
    private let key = "speakingKeyEnabled"
    /// Speaking now: the frame loop runs at full pace for the bars and the lean. An answer sitting in the bubble needs no frames.
    var animating: Bool { session || listening || finishing }
    /// The bubble is up for the owner (speaking, or an answer in it): hints, idle play and a promise held out keep away.
    var active: Bool { animating || (!hinting && panel?.isVisible == true) }
    var replying: Bool { reply != nil && !hinting && panel?.isVisible == true }
    var usingMicrophone: Bool { engine?.isRunning == true }
    var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    init(_ host: Controller) { self.host = host }
    func toggle() { UserDefaults.standard.set(!enabled, forKey: key); if !enabled { cancel(nil) } }

    // The right Option key is only a tap after it is released without any chord.
    func flags(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let rightIsDown = (flags.rawValue & 0x40) != 0 // NX_DEVICERALTKEYMASK
        let other = (flags.rawValue & 0x20) != 0 || flags.contains(.maskControl)
            || flags.contains(.maskCommand) || flags.contains(.maskShift) || flags.contains(.maskSecondaryFn)
        if gesture.modifier(code: keyCode, rightIsDown: rightIsDown, otherModifiers: other, enabled: enabled) {
            if session { finishEntry() } else { startEntry() }
        }
    }

    func pointerActivity() { _ = gesture.keyDown() }
    func keyDown(_ event: CGEvent) -> Bool {
        let chord = gesture.keyDown()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if session && code == 53 { cancel("取消了。"); return true }
        if code == 53, replying { endReply() }   // esc puts an answer away; the key still goes on to the app in front
        if chord { return false }
        guard session else { return false }
        if !listening { return false } // The input field receives its own keys and IME events.
        if code == 36 || code == 76 { finishEntry(); return true }
        guard !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl),
              !event.flags.contains(.maskAlternate), let original = NSEvent(cgEvent: event),
              let characters = original.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !((0xF700...0xF8FF).contains($0.value)) }) else { return false }
        // Move the first typed key into the new input field, not into the app behind it.
        let initial = [draft, transcript].filter { !$0.isEmpty }.joined(separator: " ")
        report("typed")
        generation += 1; listening = false; finishing = false; stopAudio()
        draft = initial; showInput(); lastActivity = CACurrentMediaTime()
        guard let panel, let forwarded = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: original.modifierFlags, timestamp: original.timestamp, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: original.charactersIgnoringModifiers ?? characters,
                isARepeat: original.isARepeat, keyCode: original.keyCode) else { return true }
        NSApp.postEvent(forwarded, atStart: false)
        return true
    }

    /// The bubble comes up in the same moment as the key, saying it is getting ready; it says 在听 only once the microphone
    /// is really running, so nothing is said into a microphone that is not on.
    private func startEntry() {
        host.teaching.hide()
        if let text = handing { handing = nil; hand(text) }   // still showing what was heard: it goes now, not lost
        if listening || finishing { cancel(nil) }
        session = true; generation += 1; lastActivity = CACurrentMediaTime()
        let current = generation
        listening = true; heard = Heard(); heardLevel = 0; meter = VoiceMeter()
        showListening(.opening)
        host.goo.kick(18)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.session else { return }
            if CACurrentMediaTime() - self.lastActivity >= 60 { self.cancel("好一会儿没听到声音，先收起了。") }
        }
        begin(current)
    }
    private func finishEntry() {
        guard session else { return }
        if listening, engine != nil { finish(); return }
        if listening { cancel("麦克风还没打开，这次没录到。"); return }
        let text = ((field?.currentEditor() as? NSTextView)?.string ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1; session = false; idleTimer?.invalidate(); idleTimer = nil
        guard !text.isEmpty else { close(nil); return }
        host.learn("type"); draft = ""; field?.isEditable = false
        hand(text)
    }
    private func begin(_ current: Int) {
        // Already allowed (every time after the first): straight on, a turn of the run loop later so the bubble is drawn first.
        if SFSpeechRecognizer.authorizationStatus() == .authorized, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.session, self.listening else { return }
                self.startAudio(current)
            }
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                guard status == .authorized else { self.fallback("没有语音识别权限，打字跟我说吧。"); return }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, self.generation == current else { return }
                        guard allowed else { self.fallback("没有麦克风权限，打字跟我说吧。"); return }
                        guard self.session, self.listening else { return }
                        self.startAudio(current)
                    }
                }
            }
        }
    }
    /// The owner's own language, as Speech lists it, that this Mac can hear without the network (SpeechLocale).
    private func onDeviceRecognizer() -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        for id in SpeechLocale.candidates(preferred: Locale.preferredLanguages, supported: supported) {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        if let r = SFSpeechRecognizer(), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        return nil
    }
    private func startAudio(_ current: Int) {
        guard let recognizer = onDeviceRecognizer() else {
            host.log("speech unavailable ondevice=0")
            fallback("这台 Mac 还不能在本机听写（系统设置 › 键盘 › 听写），打字跟我说吧。"); return
        }
        self.recognizer = recognizer
        localeID = recognizer.locale.identifier
        let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.engine = engine; self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { host.log("speech microphone none"); fallback("麦克风用不了，打字跟我说吧。"); return }
        var lastLevel = 0.0
        let buffers = self.buffers
        buffers.reset()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            buffers.add()
            let now = CACurrentMediaTime()
            guard now - lastLevel > 0.05, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            lastLevel = now
            var energy: Float = 0
            for i in 0..<Int(buffer.frameLength) { energy += samples[i] * samples[i] }
            let rms = sqrt(energy / Float(buffer.frameLength))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.listening, !self.finishing else { return }
                let (level, voice) = self.meter.hear(rms: rms)
                if voice { self.lastActivity = CACurrentMediaTime() }
                self.heard.voice(loud: voice, at: CACurrentMediaTime())
                self.heardLevel = max(self.heardLevel, level)
            }
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                if let failure = error as NSError? { self.heard.error = "\(failure.domain):\(failure.code)" }
                if let result {
                    self.heard.take(result.bestTranscription.formattedString, final: result.isFinal, at: CACurrentMediaTime())
                    if !self.transcript.isEmpty { self.lastActivity = CACurrentMediaTime() }
                    self.hearing?.words = self.transcript
                    self.refit()
                }
                if self.finishing && (result?.isFinal == true || error != nil) { self.complete() }
                else if error != nil && self.session {
                    self.draft = self.transcript   // what was heard so far is kept for typing on
                    self.fallback("本机听写出了点问题，打字跟我说吧。")
                }
            }
        }
        do {
            engine.prepare(); try engine.start()
            heard.start(at: CACurrentMediaTime()); reporting = true
            hearing?.phase = .listening; refit()
            host.goo.pop = max(host.goo.pop, 0.25)
        } catch { host.log("speech microphone failed"); fallback("麦克风用不了，打字跟我说吧。") }
    }
    /// One line when a speaking ends, so a "no words while I spoke" can be told apart from the log: numbers and fixed words
    /// (`Heard.line`), never what was heard.
    private func report(_ end: String) {
        guard reporting else { return }
        reporting = false
        heard.buffers = buffers.count
        host.log(heard.line(locale: localeID, end: end, at: CACurrentMediaTime()))
    }
    private func stopAudio() {
        if let engine { engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false } }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; engine = nil; recognizer = nil
    }
    private func finish() {
        guard !finishing else { return }
        finishing = true
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        hearing?.phase = .heard; refit()
        let current = generation
        // Words already in the bubble: the last of them is a moment away. None yet: this recognizer keeps them for the end,
        // and that end is given more time, so they aren't lost to the wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + (transcript.isEmpty ? 4 : 1.5)) { [weak self] in
            guard let self, self.generation == current, self.finishing else { return }
            self.complete()
        }
    }
    private func complete() {
        guard finishing else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let unseen = heard.firstPartial == nil   // the words came only now: show them before they go
        report(heard.final ? "done" : "waited")
        generation += 1; session = false; idleTimer?.invalidate(); idleTimer = nil; listening = false; finishing = false; stopAudio()
        guard text.count >= 2 else { close("没听清，再按一下右 ⌥ 重说。"); return }
        host.learn("speak")
        guard unseen, let hearing else { hand(text); return }
        // They see what was heard, under 听到了, for a moment, then it goes to the panel.
        hearing.words = text; refit()
        handing = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.handing == text else { return }
            self.handing = nil; self.hand(text)
        }
    }
    /// The words go where typed ones go, by the panel's own send, as its newest line. On the desktop with the panel closed the
    /// panel stays closed and this bubble goes on: what was said, 收到，在想…, the step, then the answer.
    /// Stuck to a window, or with the panel already open, the panel shows it as before.
    private func hand(_ text: String) {
        host.goo.kick(25)
        let failed = { [weak self] in
            // Tako's own side did not answer: the words come back into the bubble to send again, never lost.
            guard let self, !self.session else { return }
            self.session = true; self.draft = text; self.showInput("没交出去，按回车再试一次。")
        }
        if host.answersAside {
            showReply(said: text)
            stay(ReplyLayout.progressStay)
            host.sayAside(text, failed: failed)
        } else {
            hideBubble()
            host.sayInPanel(text, failed: failed)
        }
    }
    private func cancel(_ why: String?) {
        let open = session || listening || finishing
        report("cancel")
        generation += 1; session = false; gesture.reset(); idleTimer?.invalidate(); idleTimer = nil; listening = false; finishing = false; stopAudio()
        if open { close(why) }
    }
    private func fallback(_ message: String) { report("fallback"); generation += 1; listening = false; finishing = false; stopAudio(); showInput(message) }

    private func bubble() -> SideWindow {
        if let panel {
            if reply != nil { dropReply() }
            if panel.styleMask != [.borderless] { panel.styleMask = [.borderless] }
            panel.ignoresMouseEvents = false
            if hinting {
                hinting = false
                panel.orderOut(nil); panel.styleMask = [.borderless]
                panel.ignoresMouseEvents = false; panel.hasShadow = true
                panel.contentView = SpeakingInk(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
                panel.contentView?.autoresizingMask = [.width, .height]
                field = nil; placeholder = nil; hearing = nil
            }
            panel.alphaValue = 1
            if panel.frame.height < 50 { panel.setContentSize(NSSize(width: 300, height: 62)) }
            return panel
        }
        let panel = SideWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 62), styleMask: [.borderless], backing: .buffered, defer: false)
        // A panel hides itself whenever its app is not the active one, and the owner speaks and reads from inside another
        // app: without this the bubble was up only when Tako happened to be frontmost.
        BubbleLayout.prepare(panel)
        panel.delegate = self
        panel.contentView = SpeakingInk(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        panel.contentView?.autoresizingMask = [.width, .height]
        self.panel = panel
        return panel
    }
    func showHint(_ text: String, size: CGSize) -> NSPanel? {
        guard !active else { return nil }
        let p = bubble()
        hinting = true
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.hasShadow = false; p.ignoresMouseEvents = true
        let ink = TeachingInk(frame: NSRect(origin: .zero, size: size))
        ink.text = text; ink.onDark = host.goo.onDark
        p.contentView = ink; p.setContentSize(size)
        return p
    }
    func hideHint() {
        guard hinting else { return }
        panel?.orderOut(nil)
    }
    private func fit(_ text: String, in panel: NSPanel) {
        let size = BubbleLayout.size(text, font: .systemFont(ofSize: 14))
        panel.setContentSize(size)
        field?.frame = NSRect(x: 13, y: 5, width: size.width - 26, height: size.height - 10)
        placeholder?.frame = NSRect(x: 22, y: 5, width: size.width - 35, height: size.height - 10)
        place(panel)
    }
    /// The listening bubble grows to its words; it keeps its bottom by the body, so it grows upward.
    private func refit() {
        guard let panel, let hearing else { return }
        let size = hearing.wanted.size
        if panel.frame.size != size { panel.setContentSize(size); hearing.frame = NSRect(origin: .zero, size: size) }
        hearing.needsDisplay = true
        place(panel)
    }
    private func place(_ panel: NSPanel) {
        guard let primary = NSScreen.screens.first else { return }
        let point = NSPoint(x: host.goo.c.x, y: primary.frame.maxY - host.goo.c.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let frame = BubbleLayout.frame(size: panel.frame.size, point: point, visible: screen.visibleFrame, radius: host.goo.radius)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }
    /// Every frame while it is up (the frame loop runs at full pace while `active`): the bubble follows the body, the bars
    /// follow the voice, and the body leans to the bubble. Nothing of this runs when no one is speaking.
    func track() {
        guard !hinting, let panel, panel.isVisible, let primary = NSScreen.screens.first else {
            if host.goo.earTo != nil { host.goo.earTo = nil; host.goo.earLevel = 0 }
            return
        }
        place(panel)
        let now = CACurrentMediaTime(), dt = CGFloat(min(0.1, now - lastTrack)); lastTrack = now
        if let hearing {
            // Up fast, down slowly, like a meter: the bars catch a word and let it go gently.
            let target = listening && !finishing ? heardLevel : 0
            hearing.level += (target - hearing.level) * min(1, dt * (target > hearing.level ? 22 : 5))
            heardLevel = max(0, heardLevel - dt * 3)
            hearing.clock += dt
            if listening && !finishing { hearing.late = heard.late(at: now) }
            hearing.needsDisplay = true
        }
        if session {
            host.goo.earTo = V(panel.frame.midX, primary.frame.maxY - panel.frame.midY)
            host.goo.earLevel = hearing?.level ?? 0
        } else if host.goo.earTo != nil { host.goo.earTo = nil; host.goo.earLevel = 0 }
    }
    private func hideBubble() {
        panel?.orderOut(nil); panel?.alphaValue = 1
        host.goo.earTo = nil; host.goo.earLevel = 0
    }

    // MARK: the answer, in the same bubble

    private func showReply(said: String, phase: ReplyView.Phase = .working("收到，在想…")) {
        let p = bubble()
        p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        field = nil; placeholder = nil; hearing = nil
        host.goo.earTo = nil; host.goo.earLevel = 0   // done listening: the body is itself again
        // Pressed for the panel, never taking the owner's app from the front.
        p.styleMask = [.borderless, .nonactivatingPanel]
        let view = ReplyView(frame: .zero)
        view.said = said; view.phase = phase
        view.onClick = { [weak self] in self?.expand() }
        view.onHover = { [weak self] inside in self?.hovered(inside) }
        p.contentView?.addSubview(view); reply = view
        fitReply(); p.orderFrontRegardless()
        host.entrusted.wake()   // a promise held out goes back in: the answer comes first (Entrusted `replying`)
    }
    private func fitReply() {
        guard let panel, let reply else { return }
        let size = reply.wanted
        if panel.frame.size != size { panel.setContentSize(size) }
        reply.frame = NSRect(origin: .zero, size: size); reply.needsDisplay = true
        place(panel)
    }
    /// What the panel's page read for the bubble from its own state (side.html `asideNews`): the step it is on, the answer,
    /// or that the owner has to see the panel (a card, an error, words that did not go out).
    func aside(_ news: [String: Any]) {
        if news["open"] != nil { endReply(); host.openDesktop(); return }
        guard !session else { return }   // speaking again: what comes meanwhile is in the panel
        if news["end"] != nil {   // over with nothing to say (stopped): no step is left hanging
            if let reply, case .working = reply.phase { endReply() }
            return
        }
        if let step = news["step"] as? String {
            // Once folded away the body's own working look carries it; the bubble comes back with the answer.
            guard let reply, case .working = reply.phase, replying else { return }
            reply.phase = .working(step); fitReply(); return
        }
        guard let answer = news["answer"] as? String else { return }
        let kind = ReplyLayout.judge(answer, rich: news["rich"] as? Bool ?? false)
        if let reply, replying { reply.phase = .answer(answer, kind); fitReply() }
        else { showReply(said: news["said"] as? String ?? "", phase: .answer(answer, kind)) }
        stay(ReplyLayout.stay(kind, text: answer))
    }
    /// One fade, scheduled once; while the pointer rests on the bubble it waits for the pointer to leave.
    private func stay(_ seconds: Double) {
        replyToken += 1; replyDue = false
        let token = replyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.replyToken == token, self.reply != nil else { return }
            if self.replyHover { self.replyDue = true; return }
            self.fadeReply()
        }
    }
    private func hovered(_ inside: Bool) {
        replyHover = inside
        if !inside && replyDue { stay(1.5) }
    }
    private func fadeReply() {
        guard let panel, reply != nil else { return }
        let token = replyToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.replyToken == token else { return }
            self.endReply()
        }
    }
    /// A press on it, or a double click on the body: the panel grows out with this answer in view (side.html `setOpen`).
    private func expand() { endReply(); host.openDesktop() }
    /// A press anywhere but on the bubble or the body puts it away. Whatever Tako is doing goes on.
    func pressed(at point: CGPoint) {
        guard replying, let panel, let primary = NSScreen.screens.first else { return }
        if panel.frame.contains(NSPoint(x: point.x, y: primary.frame.maxY - point.y)) { return }
        if (V(point.x, point.y) - host.goo.c).length < host.goo.radius * 1.6 { return }
        endReply()
    }
    /// Gone: faded, put away, or the panel opened. A promise that waited for it may come now.
    func endReply() {
        guard reply != nil else { return }
        dropReply()
        if !session { hideBubble() }
        host.entrusted.wake()
    }
    private func dropReply() {
        reply?.removeFromSuperview(); reply = nil
        replyToken += 1; replyHover = false; replyDue = false
    }
    /// Ended without words to hand over: a short line says why, then the bubble fades. Nothing is left hanging.
    private func close(_ why: String?) {
        guard let panel, panel.isVisible, !hinting else { hideBubble(); return }
        host.goo.earTo = nil; host.goo.earLevel = 0
        let current = generation
        if let why {
            if hearing == nil { showListening(.ended(why)) } else { hearing?.phase = .ended(why); refit() }
            field = nil; placeholder = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (why == nil ? 0 : 1.4)) { [weak self] in
            guard let self, self.generation == current, !self.session else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.generation == current, !self.session else { return }
                self.hideBubble()
            }
        }
    }
    private func showListening(_ phase: ListeningView.Phase) {
        let p = bubble(); field = nil; placeholder = nil; p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let view = ListeningView(frame: NSRect(origin: .zero, size: ListeningLayout.size(lines: 1)))
        view.phase = phase; view.words = transcript
        p.contentView?.addSubview(view); hearing = view
        refit(); p.orderFrontRegardless()
    }
    func showInput(_ message: String = "") {
        let p = bubble(); p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        hearing = nil
        let input = NSTextField(frame: NSRect(x: 13, y: 5, width: 180, height: 22))
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.cell?.wraps = true; input.cell?.isScrollable = false; input.maximumNumberOfLines = 2
        input.placeholderString = nil
        input.stringValue = draft; input.delegate = self; input.font = .systemFont(ofSize: 15)
        let ghost = SpeakingPlaceholder(labelWithString: message.isEmpty ? "跟我说…" : message)
        ghost.font = .systemFont(ofSize: 15); ghost.textColor = .placeholderTextColor; ghost.isHidden = !draft.isEmpty
        p.contentView?.addSubview(input); p.contentView?.addSubview(ghost)
        field = input; placeholder = ghost; fit(draft.isEmpty ? ghost.stringValue : draft, in: p)
        NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil); p.makeFirstResponder(input)
        if let editor = input.currentEditor() as? NSTextView { editor.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0)) }
    }
    func controlTextDidChange(_ obj: Notification) {
        lastActivity = CACurrentMediaTime()
        draft = (field?.currentEditor() as? NSTextView)?.string ?? field?.stringValue ?? draft
        placeholder?.isHidden = !draft.isEmpty
        if let panel { fit(draft.isEmpty ? placeholder?.stringValue ?? "" : draft, in: panel) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel("取消了。"); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if textView.hasMarkedText() { return false }
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { draft = text; finishEntry() }
            return true
        }
        return false
    }
    func windowDidResignKey(_ notification: Notification) { if field != nil && session { cancel("收起了，想说再按右 ⌥。") } }
}

/// Buffers handed to the recognizer, counted on the audio thread and read on the main one.
private final class BufferCount {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
