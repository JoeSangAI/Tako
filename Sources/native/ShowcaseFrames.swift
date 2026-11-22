// Render the actual Goo layers, no screen capture, window, server, permissions or
// real user data. `Tako --showcase-frames=/tmp/frames [--showcase=none,real]`.
import AppKit
import QuartzCore
import WebKit

func renderShowcaseFrames(to directory: String) throws {
    guard let home = ProcessInfo.processInfo.environment["TAKO_HOME"], !home.isEmpty else {
        throw NSError(domain: "Tako.Showcase", code: 1, userInfo: [NSLocalizedDescriptionKey: "出帧请设置隔离的 TAKO_HOME，例如 TAKO_HOME=/tmp/tako-preview-home。"])
    }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let host = Controller(selfTest: true)
    let size = CGSize(width: 960, height: 500)
    let view = GooView(frame: CGRect(origin: .zero, size: size))
    host.gooView = view
    host.goo = Goo(host: host, view: view)
    let goo = host.goo!
    goo.visible = CGRect(origin: .zero, size: size)
    goo.screenRect = goo.visible
    goo.mode = .free
    goo.radius = CommandLine.arguments.contains(where: { $0.contains(",real") }) ? 15 : 30
    let outfit = CommandLine.arguments.first(where: { $0.hasPrefix("--showcase=") })?.split(separator: "=").last?.split(separator: ",").first.map(String.init) ?? "none"
    goo.costume.outfit = Outfit.all.first { $0.id == outfit }
    goo.costume.pinned = true
    goo.stuck = [false, false, false]; goo.reach = [0, 0, 0]
    goo.place(at: V(800, 280))
    goo.armTip = goo.armRest()
    host.fakeMouse = V(400, 20)
    goo.nextAct = 10000; goo.nextWander = 10000; goo.nextBlink = 10000
    func advance(_ seconds: Double) {
        for _ in 0..<Int(seconds * 240) {
            goo.handHome = V(800, 280)  // Stage the body at the window edge, including the empty poses.
            goo.step(1.0 / 240)
            goo.draw()
        }
    }
    func stage(_ point: V) {
        goo.stopIdleScene(); goo.handPhase = ""; goo.carrying = false; goo.silenced = false
        goo.mode = .free; goo.standingID = nil; goo.peekSide = 0; goo.handHome = nil
        goo.happyUntil = 0; goo.oopsUntil = 0; goo.guiltyUntil = 0; goo.smirkUntil = 0; goo.pop = 0; goo.blink = 0; goo.heavy = 0; goo.lid = 1
        goo.stuck = [false, false, false]; goo.reach = [0, 0, 0]; goo.ink = []
        goo.reachGoal = nil; goo.armOut = 0; goo.armTipV = V(); goo.surface = point.y + goo.radius * goo.stance
        goo.place(at: point); goo.armTip = goo.armRest(); goo.settled = true
    }
    var panelFrame = CGRect.zero   // where the desktop panel is drawn (top-left coordinates, as `placeSide` puts it)
    func save(_ name: String, dark: Bool = false, speaking: String? = nil, hint: String? = nil, hearing: ListeningView? = nil, reply: ReplyView? = nil, panel: NSImage? = nil) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(NSColor(white: dark ? 0.13 : 0.94, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // A quiet edge to make the hand-over's direction legible; no real window.
        // `--showcase-bare`: the open desktop, no window to go to.
        if !CommandLine.arguments.contains("--showcase-bare") {
            context.setFillColor((dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).cgColor)
            context.fill(CGRect(x: 36, y: 36, width: 730, height: 415))
        }
        goo.onDark = dark
        let point = CGPoint(x: goo.c.x, y: size.height - goo.c.y)
        let content = speaking ?? hint
        let font = NSFont.systemFont(ofSize: hint == nil ? 14 : 10.5)
        let visible = CGRect(origin: .zero, size: size)
        var frame = content.map { BubbleLayout.frame(size: BubbleLayout.size($0, font: font, maximum: hint == nil ? 260 : 180), point: point, visible: visible, radius: goo.radius) }
        if hint != nil, var f = frame { f.size.height = f.height > 32 ? 38 : 24; frame = f }
        if let hearing { frame = BubbleLayout.frame(size: hearing.wanted.size, point: point, visible: visible, radius: goo.radius) }
        if let reply { frame = BubbleLayout.frame(size: reply.wanted, point: point, visible: visible, radius: goo.radius) }
        if let panel {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            panel.draw(in: CGRect(x: panelFrame.minX, y: size.height - panelFrame.maxY, width: panelFrame.width, height: panelFrame.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        // The hint is held by the body; while listening nothing goes out, the body leans and looks (Speaking.track).
        goo.bubbleGoal = hint != nil ? frame.map { BubbleLayout.goal(frame: $0, point: point, primaryTop: size.height) } : nil
        goo.earTo = (speaking != nil || hearing != nil) ? frame.map { V($0.midX, size.height - $0.midY) } : nil
        goo.earLevel = hearing?.level ?? 0
        if let ear = goo.earTo {
            // Where a second of `updateMoods`/`updateFace` settles, without moving the body off its spot.
            goo.lean = 0; goo.gaze = (ear - goo.c).unit
            for i in 0..<Goo.count { goo.ring[i] = goo.target(i) }   // the even swell the voice gives it, settled
        }
        goo.draw()
        view.layer!.render(in: context)
        if let speaking, let frame {
            context.saveGState(); context.translateBy(x: frame.minX, y: frame.minY)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let ink = SpeakingInk(frame: CGRect(origin: .zero, size: frame.size)); ink.draw(ink.bounds)
            (speaking as NSString).draw(in: CGRect(x: name == "20-typing" ? 22 : 13, y: 5, width: frame.width - 26, height: frame.height - 10), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
            if name == "20-typing" { context.setStrokeColor(NSColor.darkGray.cgColor); context.setLineWidth(1); context.move(to: CGPoint(x: 13, y: 7)); context.addLine(to: CGPoint(x: 13, y: 22)); context.strokePath() }
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
        }
        if let hearing, let frame {
            context.saveGState(); context.translateBy(x: frame.minX, y: frame.minY)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let ink = SpeakingInk(frame: CGRect(origin: .zero, size: frame.size)); ink.draw(ink.bounds)
            hearing.frame = CGRect(origin: .zero, size: frame.size); hearing.draw(hearing.bounds)
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
        }
        if let reply, let frame {
            context.saveGState(); context.translateBy(x: frame.minX, y: frame.minY)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let ink = SpeakingInk(frame: CGRect(origin: .zero, size: frame.size)); ink.draw(ink.bounds)
            reply.frame = CGRect(origin: .zero, size: frame.size); reply.draw(reply.bounds)
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
        }
        if let hint, let frame {
            context.saveGState(); context.translateBy(x: frame.minX, y: frame.minY)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let ink = TeachingInk(frame: CGRect(origin: .zero, size: frame.size)); ink.text = hint; ink.onDark = dark; ink.draw(ink.bounds)
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
        }
        if goo.earTo != nil { goo.earTo = nil; goo.earLevel = 0; for i in 0..<Goo.count { goo.ring[i] = goo.target(i) } }
        goo.bubbleGoal = nil
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    }
    // `--showcase-walk=<steps.json>`: only the frames a walkthrough asks for, in order, each the body on the open desktop with
    // what is in front of the owner at that moment: the desktop panel as the page draws it from a brain started for this with a
    // temporary home (`panel`, with `js` run first for what the app tells the page: switches, what was learned), a hint the body
    // holds (`hint`), or a line held out (`carry`). Nothing is captured and nothing is asked of the system.
    if let walk = CommandLine.arguments.first(where: { $0.hasPrefix("--showcase-walk=") }).map({ String($0.dropFirst("--showcase-walk=".count)) }) {
        struct WalkStep: Decodable {
            let name: String
            let panel: String?, js: String?, hint: String?, carry: String?
            let held: Int?, hover: Bool?, quiet: Bool?, soft: Bool?
        }
        for step in try JSONDecoder().decode([WalkStep].self, from: Data(contentsOf: URL(fileURLWithPath: walk))) {
            stage(V(800, 280))
            if let held = step.held {
                goo.carrying = true; goo.heldCount = held; goo.heldPreview = "见到联系人，核对排期"; goo.handHovered = step.hover ?? false
                goo.silenced = step.quiet ?? false
                goo.handHome = V(800, 280); advance(1); try save(step.name)
                goo.silenced = false
            } else if let address = step.panel {
                let card = CGSize(width: min(480, size.width - 32), height: min(560, size.height - 48))
                panelFrame = PanelPlace.desktop(near: CGPoint(x: 800, y: 280), size: card, visible: CGRect(origin: .zero, size: size), remembered: nil, bar: 52)
                let seat = PanelPlace.seat(of: panelFrame, bar: 52)
                guard let image = panelSnapshot(address, size: card, origin: CGPoint(x: seat.x - panelFrame.minX, y: seat.y - panelFrame.minY), at: nil, script: step.js ?? "") else {
                    throw NSError(domain: "Tako.Showcase", code: 2, userInfo: [NSLocalizedDescriptionKey: "Panel frame was not rendered"])
                }
                stage(V(seat.x, seat.y))
                try save(step.name, panel: image)
            } else if let hint = step.hint {
                goo.reachGoal = goo.c + V(goo.radius * 1.2, -goo.radius * 0.5); advance(0.4)
                try save(step.name, hint: hint)
                goo.reachGoal = nil
            } else if let carry = step.carry {
                goo.carrying = true; goo.handHome = V(800, 280)
                goo.silenced = step.quiet ?? false
                goo.presentHand(text: carry, soft: step.soft ?? false)
                advance(1.6); try save(step.name)
                goo.takeHandBack("done"); advance(1.2)
            } else {
                advance(0.3); try save(step.name)
            }
        }
        print("Rendered the walk to \(directory)")
        return
    }
    advance(0.3); try save("01-empty")
    goo.carrying = true
    advance(1); try save("02-holding")
    goo.presentHand(text: "草稿备好了，交给你。")
    advance(0.3); try save("03-hesitating")
    advance(0.38); try save("04-reaching")
    advance(0.9); try save("05-offering")
    goo.sayThenTuck("好，半小时后再说。")
    advance(0.3); try save("06-later-saying")
    goo.takeHandBack("later")
    advance(0.3); try save("06-later")
    advance(1.1); try save("07-tucked")
    goo.handHome = V(800, 280)
    goo.presentHand(text: "草稿备好了，交给你。")
    advance(1.4)
    goo.takeHandBack("ignored")
    advance(0.6); try save("08-ignored")
    advance(0.8)
    goo.handHome = V(800, 280)
    goo.presentHand(text: "草稿备好了，交给你。")
    advance(1.4)
    goo.takeHandBack("done")
    advance(0.16); try save("09-done")
    advance(1.2); try save("10-empty-again")
    // A real attached-body pose, on a synthetic window: no system window is opened.
    host.target = (id: 1, frame: CGRect(x: 36, y: 49, width: 730, height: 415))
    goo.mode = .attached
    goo.handHome = nil
    goo.place(at: V(789, 155))
    goo.armTip = goo.armRest()
    goo.stuck = [true, true, true]
    goo.anchor = [V(766, 135), V(766, 155), V(766, 175)]
    goo.carrying = true
    goo.presentHand(text: "草稿备好了，交给你。")
    for _ in 0..<360 { goo.step(1.0 / 240); goo.draw() }
    try save("12-attached-offering")
    try save("14-dark-window", dark: true)
    goo.handPhase = ""; goo.mode = .free
    goo.place(at: V(800, 280)); goo.armTip = goo.armRest()
    goo.carrying = true; goo.silenced = true
    advance(0.8); try save("16-muted-tape")
    goo.silenced = false
    advance(0.08); try save("17-removing-tape")
    goo.carrying = true; goo.presentHand(text: "会议还等着你呢")
    advance(1.9); try save("18-repeat")
    goo.carrying = false; goo.handPhase = ""; goo.stuck = [false, false, false]; goo.armTip = goo.armRest()
    // The speaking key: getting ready, listening in a quiet room, listening to words, the words handed on, an ending.
    func hearing(_ phase: ListeningView.Phase, _ words: String = "", level: CGFloat = 0, clock: CGFloat = 1.3, late: Bool = false) -> ListeningView {
        let view = ListeningView(frame: .zero); view.phase = phase; view.words = words; view.level = level; view.clock = clock; view.late = late
        return view
    }
    let said = "下午三点提醒我给设计组回邮件，顺便把上周那版稿子找出来"
    let longer = said + "。还有，明天上午的会改到十点半了，帮我记一下，到时候提前十分钟叫我"
    stage(V(800, 280))   // standing at the window's edge, as when the key is pressed
    try save("19-opening", hearing: hearing(.opening))
    try save("19-listening-quiet", hearing: hearing(.listening))
    try save("19-listening-words", hearing: hearing(.listening, said, level: 0.7))
    try save("19-listening-loudest", hearing: hearing(.listening, said, level: 1))
    try save("19-listening-late", hearing: hearing(.listening, level: 0.6, late: true))
    try save("19-listening-long", hearing: hearing(.listening, longer + longer, level: 0.45))
    try save("19-heard", hearing: hearing(.heard, said))
    try save("19-ended", hearing: hearing(.ended("没听清，再按一下右 ⌥ 重说。")))
    try save("20-typing", speaking: "跟我说…")
    try save("22-listening-dark", dark: true, hearing: hearing(.listening, said, level: 0.5))
    goo.reachGoal = goo.c + V(-goo.radius, -goo.radius); advance(0.4)
    try save("23-hint", hint: "下次按右 ⌥，直接跟我说。")
    goo.reachGoal = nil; advance(0.3)
    for (name, point) in [("25-edge-left", V(18, 250)), ("26-edge-right", V(942, 250)), ("27-edge-top", V(480, 18)), ("28-edge-bottom", V(480, 482))] {
        goo.handHome = nil; goo.place(at: point); goo.armTip = goo.armRest(); goo.draw()
        try save(name, hearing: hearing(.listening, said, level: 0.4))
    }
    host.fakeMouse = V(400, 20)
    stage(V(800, 280)); goo.startIdleScene("highfive"); goo.idleAt = goo.clock - 0.8
    goo.idleGoal = goo.c + V(-goo.radius * 1.6, -goo.radius * 0.9); goo.reachGoal = goo.idleGoal; goo.armTip = goo.idleGoal!; goo.armOut = 26
    goo.draw(); try save("31-highfive")
    stage(V(800, 280)); goo.idleShape = 1; goo.startIdleScene("doodle"); goo.idleAt = goo.clock - 1.4
    goo.idleGoal = goo.idleDoodlePoints().last; goo.reachGoal = goo.idleGoal; goo.armTip = goo.idleGoal!; goo.armOut = 30
    goo.draw(); try save("32-doodle")
    stage(V(size.width + goo.radius * 0.25, 280)); goo.startPeek(); goo.draw(); try save("33-peeking")
    stage(V(789, 155)); host.target = (id: 1, frame: CGRect(x: 36, y: 49, width: 730, height: 415))
    goo.mode = .attached; goo.stuck = [true, true, true]; goo.anchor = [V(766, 135), V(766, 155), V(766, 175)]
    goo.armTip = goo.armRest()
    goo.draw(); try save("34-attached-listening", hearing: hearing(.listening, said, level: 0.6))
    goo.reachGoal = goo.c + V(-goo.radius, -goo.radius)
    try save("35-attached-hint", hint: "下次按右 ⌥，直接跟我说。")
    goo.reachGoal = nil
    // The squeeze it gives as a panel opens (`kick(42)`, SidePanel), caught where the skin is furthest from its round
    // place, eyes on the card: it must still read as one round body.
    func squeeze() {
        goo.lean = 0; goo.lookAt = V(-1, 0.1); goo.lookTime = 1
        func away() -> CGFloat { (0..<Goo.count).map { (goo.ring[$0] - goo.target($0)).length }.max()! / goo.radius }
        goo.kick(42)
        var widest: CGFloat = 0, frames = 0
        for _ in 0..<120 {
            goo.handHome = goo.mode == .free ? V(800, 280) : nil; goo.step(1.0 / 240); frames += 1
            let now = away()
            if now < widest { break }
            widest = now
        }
        goo.draw()
        FileHandle.standardError.write(Data("squeeze furthest=\(String(format: "%.3f", Double(widest))) radius after \(frames) frames\n".utf8))
    }
    stage(V(800, 280)); squeeze(); try save("36-squeeze-widest")
    // After speaking on the desktop with the panel closed, the same bubble goes on (Speaking `showReply`): the step it is on,
    // then a short answer whole, or a long one's start with how to see the rest. The body's working look is the panel's own.
    func answer(_ phase: ReplyView.Phase, _ said: String) -> ReplyView {
        let view = ReplyView(frame: .zero); view.said = said; view.phase = phase
        return view
    }
    stage(V(800, 280)); goo.state = "working"; advance(0.4)
    try save("38-reply-step", reply: answer(.working("看了文件的版面"), "把上周那版稿子找出来，看看第三页的数字对不对"))
    goo.state = "idle"; stage(V(800, 280))
    let short = "下午三点，在三楼大会议室。"
    try save("39-reply-short", reply: answer(.answer(short, ReplyLayout.judge(short, rich: false)), "明天的会几点，在哪儿？"))
    let long = "数字对不上：第三页写的是 1,280 万，附件表里是 1,208 万，差了 72 万。我把两处都标出来了，改好的副本在 产出文件 里。· 第三页 第二段 · 附表 B 列"
    try save("40-reply-long", reply: answer(.answer(long, ReplyLayout.judge(long, rich: true)), "把上周那版稿子找出来，看看第三页的数字对不对"))
    goo.handHome = nil
    // `--showcase-panel=<page address>`: after speaking, the desktop panel open beside the body, as the real page draws it
    // (a brain started for this with a temporary home; the page is rendered off screen, nothing is captured).
    if let address = CommandLine.arguments.first(where: { $0.hasPrefix("--showcase-panel=") }).map({ String($0.dropFirst("--showcase-panel=".count)) }) {
        stage(V(800, 280))
        // Where `placeSide` puts it: from the body, inside the screen; the body then sits at its corner (`PanelPlace.seat`).
        let card = CGSize(width: min(480, size.width - 32), height: min(560, size.height - 48))
        panelFrame = PanelPlace.desktop(near: CGPoint(x: 800, y: 280), size: card, visible: CGRect(origin: .zero, size: size), remembered: nil, bar: 52)
        let seat = PanelPlace.seat(of: panelFrame, bar: 52)
        let origin = CGPoint(x: 800 - panelFrame.minX, y: 280 - panelFrame.minY)   // the body on the page: the card grows out of it
        // Growing out of the body, a little past halfway (the body squeezed as it lets go), then settled with the body at its corner.
        if let growing = panelSnapshot(address, size: card, origin: origin, at: 0.035) {
            squeeze()
            try save("36-panel-growing", panel: growing)
        }
        if let image = panelSnapshot(address, size: card, origin: CGPoint(x: seat.x - panelFrame.minX, y: seat.y - panelFrame.minY), at: nil) {
            stage(V(seat.x, seat.y))
            try save("37-panel-open", panel: image)
        }
        // A long answer in the bubble, pressed: the panel opens with that answer in view (side.html `setOpen`, `asideAt`).
        if let image = panelSnapshot(address, size: card, origin: origin, at: nil, atLastAnswer: true) {
            stage(V(seat.x, seat.y))
            try save("41-reply-expanded", panel: image)
        }
    }
    // Sample the real body state at evenly spaced points; no window or recording permission.
    func sequence(_ name: String, duration: Double, prepare: () -> Void, perFrame: (Int, Double) -> Void = { _, _ in }) throws {
        let point = V(480, 500 - goo.radius * goo.stance)
        stage(point)
        host.fakeMouse = V(390, 440); goo.mouseAt = host.fakeMouse!; goo.nextAct = goo.clock + 1000; goo.nextWander = goo.clock + 1000
        prepare()
        var elapsed = 0.0
        for i in 0..<8 {
            let time = duration * Double(i) / 7
            while elapsed + 1.0 / 240 <= time + 0.000001 { goo.step(1.0 / 240); elapsed += 1.0 / 240 }
            perFrame(i, time)
            let label = String(format: "%02d-%.2fs", i + 1, time)
            try save("seq-\(name)-\(label)")
        }
    }
    try sequence("doodle", duration: 5.6, prepare: { goo.idleShape = 1; goo.startIdleScene("doodle") })
    try sequence("highfive-hit", duration: 5, prepare: { goo.startIdleScene("highfive") }, perFrame: { i, _ in
        if i == 2 { host.fakeMouse = goo.c + V(goo.idleSide * goo.radius * 1.6, -goo.radius * 0.9) }
    })
    try sequence("highfive-miss", duration: 5.8, prepare: { goo.startIdleScene("highfive") })
    for shape in 0..<4 {
        stage(V(480, 500 - goo.radius * goo.stance)); goo.idleShape = shape; goo.startIdleScene("doodle"); goo.idleAt = goo.clock - 2.1
        try save("doodle-finished-\(shape)")
    }
    // `--showcase-ladder`: the ladder's lines as the body says them (`ladder.py`, `entrusted.py`): the first try's two hints, and
    // hand-overs for a promise about someone from days ago, a reminder in their chat and a meeting about to start.
    if CommandLine.arguments.contains("--showcase-ladder") {
        for (name, line) in [("L1-first-chat", "双击我，说：见到某某，提醒我某事。"), ("L1-first-time", "双击我，说：一分钟后提醒我喝水。"), ("L1-first-open", "记下了。去打开和TA的聊天看看。")] {
            stage(V(800, 280)); goo.reachGoal = goo.c + V(goo.radius * 1.2, -goo.radius * 0.5); advance(0.4)
            try save(name, hint: line)
            goo.reachGoal = nil
        }
        for (name, line) in [("L2-days-ago", "你 5 天前问过他排期"), ("L3-reminder", "提醒事项里写着：给王小明寄样品"), ("L3-meeting", "等下要见王小明。你答应周四给他报价")] {
            stage(V(800, 280)); goo.carrying = true; goo.handHome = V(800, 280)
            goo.presentHand(text: line)
            advance(1.6); try save(name)
            goo.takeHandBack("done"); advance(1.2)
        }
    }
    print("Rendered frames and sequences to \(directory)")
}

/// The panel page as WebKit draws it, in a window that is never shown.
/// `at`: the card's opening animation held at that many seconds; nil, settled.
private func panelSnapshot(_ address: String, size: CGSize, origin: CGPoint, at: Double?, atLastAnswer: Bool = false, script: String = "") -> NSImage? {
    guard let url = URL(string: address) else { return nil }
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let web = WKWebView(frame: CGRect(origin: .zero, size: size))
    web.setValue(false, forKey: "drawsBackground")   // as the app's own panel: only the card is drawn
    window.contentView = web
    web.load(URLRequest(url: url))
    func wait(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    wait(8) { !web.isLoading }
    // A window that is never shown gets no display frames: transitions are drawn settled, and the card's own animation is
    // held at the moment asked for (a paused animation with a negative delay is drawn at that point of it).
    let hold = at.map { "body.open #card{animation-play-state:paused!important;animation-delay:-\($0)s!important}" } ?? "body.open #card{animation:none!important}"
    web.evaluateJavaScript("document.head.insertAdjacentHTML('beforeend', '<style>*{transition:none!important}*:not(#card){animation:none!important}\(hold)</style>'); setFloating(true); setGeometry(0,\(Int(size.width))); setWidth(\(Int(size.width))); setOrigin(\(Int(origin.x)),\(Int(origin.y))); \(script) \(atLastAnswer ? "tick().then(() => { const r = [...document.querySelectorAll('#log .tako')].pop(); asideAt = r ? Number(r.dataset.at) : 0; openFresh(); })" : "openFresh()")")
    wait(2.5)
    var image: NSImage?, finished = false
    web.takeSnapshot(with: nil) { picture, _ in image = picture; finished = true }
    wait(5) { finished }
    return image
}

/// `Tako --seat-check`: the body's physics stepped off screen (no window, server or permission), from each state it can be
/// in when the desktop panel opens, on to its seat at the panel's corner. One line each: the furthest the skin, the legs
/// and the reaching limb got from the middle, in radii, and whether it arrived (tests/test_guards.py `TheDesktopPanel`).
func seatCheck() -> String {
    let host = Controller(selfTest: true)
    let size = CGSize(width: 1200, height: 800)
    let view = GooView(frame: CGRect(origin: .zero, size: size))
    host.gooView = view
    host.goo = Goo(host: host, view: view)
    let goo = host.goo!
    goo.visible = CGRect(origin: .zero, size: size); goo.screenRect = goo.visible
    goo.radius = 15
    host.fakeMouse = V(900, 700)
    var lines: [String] = []
    let seat = V(300, 60)
    for state in ["floor", "puddle", "asleep", "reaching", "wandering", "hopping"] {
        goo.seat = nil; goo.mode = .free; goo.place(at: V(900, 800 - goo.radius * goo.stance)); goo.v = V()
        goo.puddle = false; goo.splatUntil = 0; goo.sleeping = false; goo.reachGoal = nil; goo.wanderTo = nil; goo.peekSide = 0
        goo.nextAct = goo.clock + 1000; goo.nextWander = goo.clock + 1000; goo.nextIdleScene = goo.clock + 1000; goo.lastMoved = goo.clock
        for _ in 0..<240 { goo.step(1.0 / 240) }          // landed and settled on the floor
        switch state {
        case "puddle": goo.startPuddle()
        case "asleep": goo.startSleep()
        case "reaching": goo.reachGoal = goo.c + V(-260, -40)
        case "wandering": goo.wanderTo = goo.c.x - 300
        case "hopping": goo.v.y = -210; goo.settled = false
        default: break
        }
        for _ in 0..<(state == "hopping" ? 12 : 120) { goo.step(1.0 / 240) }   // well into it (a hop: just off the floor)
        if state == "reaching" { goo.reachGoal = nil }  // the idle reach is let go of when the panel opens (seated, nothing of its own)
        let reachedAtStart = (goo.armTip - goo.c).length / goo.radius
        let skinAtStart = goo.ring.map { ($0 - goo.c).length / goo.radius }.max() ?? 0   // a puddle is wide to begin with
        goo.seat = seat
        var skin: CGFloat = 0, legs: CGFloat = 0, arm: CGFloat = 0
        for frame in 0..<(240 * 3) {
            goo.step(1.0 / 240)
            for p in goo.ring { skin = max(skin, (p - goo.c).length / goo.radius) }
            for k in 0..<4 { legs = max(legs, (goo.leg(k)[2] - goo.c).length / goo.radius) }
            if frame > 240 / 2 { arm = max(arm, (goo.armTip - goo.c).length / goo.radius) }   // given half a second to draw the limb in
        }
        let arrived = (goo.c - seat).length < 3 && goo.v.length < 20
        lines.append(String(format: "%@ skin=%.2f legs=%.2f arm=%.2f start-skin=%.2f start-arm=%.2f arrived=%d", state, skin, legs, arm, skinAtStart, reachedAtStart, arrived ? 1 : 0))
    }
    return lines.joined(separator: "\n")
}
