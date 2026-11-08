// `--selftest`: the whole life cycle of the goo, driven through the same press and release paths, with its numbers in the log.
import AppKit
import QuartzCore

extension Controller {
    // MARK: self-test: the whole life cycle, driven through the same press/release paths

    func runSelfTest() {
        func at(_ t: Double, _ work: @escaping () -> Void) {
            let timer = Timer(timeInterval: t, repeats: false) { _ in work() }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
        }
        var ticker: Timer?
        func glideMouse(from a: V, to b: V, seconds: Double) {
            let began = CACurrentMediaTime()
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                let t = min(1, (CACurrentMediaTime() - began) / seconds)
                self?.fakeMouse = mix(a, b, CGFloat(t))
                if t >= 1 { timer.invalidate() }
            }
            RunLoop.main.add(ticker!, forMode: .common)
        }
        func report(_ name: String) { log("[\(name)] mode=\(goo.mode) c=\(Int(goo.c.x)),\(Int(goo.c.y)) r=\(Int(goo.radius)) stuck=\(goo.stuck) window=\(target.map { Int($0.frame.maxX) } ?? -1)") }

        at(1.6) { report("settled on window") }
        at(1.8) { [self] in
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            glideMouse(from: start, to: start + V(170, 70), seconds: 0.9)
        }
        at(2.8) { [self] in report("after peel"); goo.release() }
        at(4.5) { report("on the floor") }
        at(4.7) { [self] in
            guard let w = target?.frame else { return }
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            glideMouse(from: start, to: V(w.maxX + 40, w.minY + 120), seconds: 0.9)
        }
        at(5.7) { [self] in report("hovering near window") }
        at(5.75) { [self] in goo.release() }
        at(7.2) { [self] in
            report("stuck again")
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            // Tear it off upward, then shake it hard from side to side.
            glideMouse(from: start, to: start + V(0, -10), seconds: 0.05)
            let began = CACurrentMediaTime()
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = CACurrentMediaTime() - began
                self.fakeMouse = start + V(160 + sin(t * 26) * 110, 120)
                if t > 1.1 { timer.invalidate() }
            }
            RunLoop.main.add(ticker!, forMode: .common)
        }
        at(8.5) { [self] in
            report("after shaking")
            // Fling it at the right edge of the screen, from a long way back.
            let start = V(goo.visible.midX - 300, goo.c.y)
            fakeMouse = start
            at(0.25) { [self] in
                log("fling begins at c.x=\(Int(goo.c.x)) mode=\(goo.mode)")
                glideMouse(from: start, to: V(goo.visible.maxX - 90, start.y + 40), seconds: 0.22)
            }
        }
        at(8.93) { [self] in
            log("release c.x=\(Int(goo.c.x)) mouse.x=\(Int(fakeMouse?.x ?? -1)) speed=\(Int(goo.mouseSpeed.x))")
            goo.release()
        }
        at(9.6) { report("splatted on the edge") }
        at(13.0) { report("after sliding off") }
        at(13.1) { [self] in
            // Carry it above a window and let go: it should land on the top edge.
            guard let w = platforms.first(where: { $0.id == testWindow?.windowNumber })?.frame else { log("test window not seen"); return }
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            glideMouse(from: start, to: V(w.midX, w.minY - 44), seconds: 0.5)
        }
        at(12.2) { [self] in
            // A throwaway window of our own, in front of everything, to stand on.
            let window = NSWindow(contentRect: NSRect(x: 1195, y: 300, width: 250, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Tako 自测，马上关闭"
            window.orderFrontRegardless()
            testWindow = window
        }
        at(13.8) { [self] in goo.release() }
        at(15.0) { [self] in
            report("standing")
            log("standing on window: \(goo.standingID != nil) x=\(Int(goo.c.x)) feet=\(Int(goo.c.y + goo.radius * 0.82))")
            testWindow?.setFrameOrigin(NSPoint(x: 1215, y: 380))  // it should ride along
        }
        at(15.6) { [self] in
            report("after window moved")
            log("standing on window: \(goo.standingID != nil) x=\(Int(goo.c.x)) feet=\(Int(goo.c.y + goo.radius * 0.82))")
            testWindow?.close()  // and fall when it is gone
            testWindow = nil
        }
        at(17.2) { [self] in
            report("after window closed")
            // Three quick pokes.
            for k in 0..<3 {
                at(Double(k) * 0.25) { [self] in
                    fakeMouse = goo.c
                    goo.press(goo.c)
                    goo.release()
                }
            }
        }
        at(18.6) { [self] in
            report("after pokes")
            // Leave the cursor quiet nearby: an arm should sneak out for it.
            fakeMouse = goo.c + V(-120, -70)
            goo.nextAct = goo.clock + 60
            goo.nextWander = goo.clock + 60
        }
        at(23.6) { [self] in
            log("arm out=\(Int(goo.armOut)) arrived=\(goo.armArrived)")
            fakeMouse = (fakeMouse ?? goo.c) + V(30, 10)    // caught
        }
        at(24.0) { [self] in log("guilty=\(goo.guilty)") }
        at(26.0) { [self] in
            log("arm back=\(Int(goo.armOut))")
            fakeMouse = V(goo.visible.midX, goo.visible.midY)
            goo.startPeek()
        }
        at(28.0) { [self] in
            log("peeking side=\(Int(goo.peekSide)) c.x=\(Int(goo.c.x)) edge=\(Int(goo.peekSide > 0 ? goo.screenRect.maxX : goo.screenRect.minX))")
            fakeMouse = V(goo.c.x - goo.peekSide * 80, goo.c.y)
        }
        at(29.0) { [self] in
            log("ducking=\(goo.ducking) c.x=\(Int(goo.c.x))")
            fakeMouse = V(goo.visible.midX, goo.visible.midY)
            goo.peekSide = 0
            goo.ducking = false
            goo.settled = false
        }
        at(31.0) { [self] in
            goo.startPuddle()
        }
        at(32.0) { [self] in
            report("puddle")
            fakeMouse = goo.c + V(30, -10)
        }
        at(32.6) { [self] in
            report("after puddle")
            log("puddle=\(goo.puddle)")
            goo.lastMoved = goo.clock - 41   // nap, then a cursor right beside it
        }
        at(33.2) { [self] in
            log("sleeping=\(goo.sleeping)")
            fakeMouse = goo.c + V(25, -25)
        }
        at(33.6) { [self] in
            log("sleeping after cursor=\(goo.sleeping)")
            fakeMouse = nil
            goo.stick(to: target?.frame.maxX ?? 0)
        }
        at(35.2) { [self] in goo.state = "reading" }
        at(37.8) { [self] in
            log("reading arm out=\(Int(goo.armOut)) strand1 reach=\(String(format: "%.2f", goo.reach[1]))")
            goo.state = "idle"
            let times = frameTimes.dropFirst(30).sorted()
            if let worst = times.last, !times.isEmpty {
                let p99 = times[Int(Double(times.count - 1) * 0.99)]
                let mean = times.reduce(0, +) / Double(times.count)
                log(String(format: "frames=%d mean=%.1fms p99=%.1fms worst=%.1fms", times.count, mean * 1000, p99 * 1000, worst * 1000))
            }
            log(String(format: "skin peak=%.2f radii", goo.peakAway))
            log("panel says its region is \(Int(region.width)) wide")  // Only the page's own message can have set this.
            // Dressed as a corgi on the floor: a dash to and fro, then a stroke on the head.
            goo.costume.outfit = Outfit.all.first { $0.id == "corgi" }
            goo.costume.pinned = true
            goo.tearOff(velocity: V(190, -240), reason: "selftest")
            fakeMouse = V(goo.visible.midX, goo.visible.minY + 40)
        }
        at(42.0) { [self] in
            goo.nextAct = goo.clock + 60
            goo.dizzyUntil = 0   // it landed hard; the dash is what is being checked
            goo.startZoomies()
            log("zoomies from c.x=\(Int(goo.c.x)) zooming=\(goo.zooming)")
        }
        at(43.4) { [self] in log("mid-dash c.x=\(Int(goo.c.x)) v.x=\(Int(goo.v.x))") }
        at(45.4) { [self] in
            log("after dash zooming=\(goo.zooming) c.x=\(Int(goo.c.x))")
            fakeMouse = goo.c + V(0, -goo.radius * 0.5)
        }
        at(46.6) { [self] in
            log("petted happy=\(goo.happy) wiggle=\(String(format: "%.2f", goo.wiggle)) tongue=\(goo.costume.tongue.path != nil)")
            fakeMouse = V(goo.visible.midX, goo.visible.minY + 40)
        }
        // Joe 2026-11-04: over the middle of a window it is only carried; near the right edge it latches on and slides to its place.
        var dropOn: CGRect?
        at(47.0) { [self] in
            goo.costume.outfit = nil
            dropOn = platforms.first(where: { $0.sticky })?.frame
            guard let w = dropOn else { log("no window to drop on"); return }
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            glideMouse(from: start, to: V(w.midX, w.midY), seconds: 0.7)
        }
        at(47.9) { [self] in
            log("over the middle candidate=\(goo.candidate != nil)")
            goo.release()
        }
        at(48.6) { [self] in report("dropped mid-window") }
        at(49.4) { [self] in
            guard let w = dropOn else { return }
            let start = goo.c
            fakeMouse = start
            goo.press(start)
            glideMouse(from: start, to: V(w.maxX - 80, w.minY + min(260, w.height * 0.6)), seconds: 0.7)
        }
        at(50.3) { [self] in
            log("near the edge candidate=\(goo.candidate != nil) lean=\(Int(goo.c.x - (fakeMouse?.x ?? goo.c.x)))")
            goo.release()
        }
        for (k, dt) in [0.08, 0.2, 0.35, 0.5, 0.65].enumerated() {
            at(50.3 + dt) { [self] in
                log(String(format: "latch %d: c=%d,%d reach=%.2f,%.2f,%.2f latching=%@ arm=%d out=%.0f wanted=%@ acting=%@", k, Int(goo.c.x), Int(goo.c.y), goo.reach[0], goo.reach[1], goo.reach[2], goo.latch != nil ? "yes" : "no", goo.armStrand, goo.armOut, goo.armWanted ? "y" : "n", goo.acting == nil ? "-" : "y"))
            }
        }
        at(51.5) { [self] in
            report("latched")
            log("home=\(Int(goo.home.x)),\(Int(goo.home.y)) edge=\(Int(dropOn?.maxX ?? -1))")
            fakeMouse = nil
            log("self-test done")
        }
    }

    // MARK: showcase: an outfit's moves on the floor, with a drawn cursor and a caption, for recording

    /// `--showcase[=outfit]` (`=none` for Tako as it is): what an outfit does, played out once on the floor in the middle of the screen. Like the self-test
    /// it opens no panel and moves no window; nothing in it touches the real pointer.
    func runShowcase() {
        // ",lead=3": wait that many seconds before it starts, so a recorder can be running first
        let lead = CommandLine.arguments.first { $0.hasPrefix("--showcase") }?.split(separator: ",")
            .first { $0.hasPrefix("lead=") }.flatMap { Double($0.dropFirst(5)) } ?? 0
        func at(_ t: Double, _ work: @escaping () -> Void) {
            let timer = Timer(timeInterval: t + lead, repeats: false) { _ in work() }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
        }
        var ticker: Timer?
        func glide(to b: V, seconds: Double) {
            let a = fakeMouse ?? b, began = CACurrentMediaTime()
            ticker?.invalidate()
            ticker = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                let t = min(1, (CACurrentMediaTime() - began) / seconds)
                self?.fakeMouse = mix(a, b, CGFloat(t * t * (3 - 2 * t)))
                if t >= 1 { timer.invalidate() }
            }
            RunLoop.main.add(ticker!, forMode: .common)
        }
        let root = gooView.layer!
        let arrow = CAShapeLayer(), caption = CATextLayer()
        let shape = CGMutablePath()
        for (x, y) in [(0.0, 0.0), (0.0, -17.0), (4.2, -13.2), (7.2, -19.6), (10.0, -18.4), (7.2, -12.2), (12.4, -12.2)] {
            if x == 0 && y == 0 { shape.move(to: .zero) } else { shape.addLine(to: CGPoint(x: x, y: y)) }
        }
        shape.closeSubpath()
        arrow.path = shape
        arrow.fillColor = NSColor.black.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.2
        caption.fontSize = 18
        caption.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        caption.foregroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        caption.alignmentMode = .center
        caption.contentsScale = 2
        for layer in [arrow, caption] { root.addSublayer(layer) }
        let floor = goo.visible.maxY, middle = goo.visible.midX
        let cursorTick = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self, let m = self.fakeMouse else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arrow.position = self.goo.L(m)
            caption.frame = CGRect(origin: self.goo.L(V(middle - 160, floor - 236)), size: CGSize(width: 320, height: 24))
            CATransaction.commit()
        }
        RunLoop.main.add(cursorTick, forMode: .common)
        func say(_ words: String) { caption.string = words; log("showcase: \(words)") }
        // ",bare": no caption and no drawn cursor, for footage that goes into something else
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--showcase") && $0.contains(",bare") }) { arrow.isHidden = true; caption.isHidden = true }

        // on the floor, dressed, nothing of its own planned
        // --showcase=corgi, --showcase=none, and ",acts" after it for the scenes it plays while it works
        let asked = (CommandLine.arguments.first { $0.hasPrefix("--showcase") }?.split(separator: "=").dropFirst().first.map(String.init) ?? "corgi")
            .split(separator: ",").map(String.init)
        goo.costume.outfit = Outfit.all.first { $0.id == asked.first }
        // a title for the recording can be given as ",title=…"
        let title = asked.first { $0.hasPrefix("title=") }.map { String($0.dropFirst(6)) } ?? goo.costume.outfit?.name ?? "Tako"
        goo.costume.pinned = true
        goo.radius = asked.contains("real") ? 15 : 45   // three times its size, so a recording shows the outfit's details (",real": as it is)
        goo.mode = .free
        goo.stuck = [false, false, false]   // it starts out holding the front window: let go of it first
        goo.reach = [0, 0, 0]
        goo.reachV = [0, 0, 0]
        goo.place(at: V(middle, floor - goo.radius * goo.stance))
        setWatching(false)
        enchant.hide()   // it started out on a window: that window's ink border goes, so a recording holds only the goo
        fakeMouse = V(middle + 170, floor - 150)
        func quiet() { goo.nextAct = goo.clock + 600; goo.nextWander = goo.clock + 600; goo.lastMoved = goo.clock }
        if asked.contains("acts") {
            // what it does while it works, one scene after another
            let scenes: [(String, String)] = [("think", "在想"), ("search", "上网查"), ("run", "跑命令"), ("look", "看窗口"), ("read", "读微信"),
                                              ("answer", "写回答"), ("listen", "陪你听课"), ("wait", "等你点头"), ("trouble", "连不上，重试中")]
            at(0.2) { [self] in quiet(); say(title); fakeMouse = V(middle + 170, floor - 150) }
            for (i, (act, words)) in scenes.enumerated() {
                at(1.4 + Double(i) * 3.4) { [self] in quiet(); goo.act = act; say(words) }
            }
            let end = 1.4 + Double(scenes.count) * 3.4
            at(end) { [self] in goo.act = ""; say("做完了"); fakeMouse = V(middle + 900, floor - 600); goo.celebrate() }
            at(end + 2.2) { [self] in say("出错了"); goo.fumble() }
            at(end + 5.0) { [self] in log("showcase done") }
            return
        }
        if goo.costume.isWhale && asked.contains("fish") {
            // ",fish": her fish gag, twice, nothing else
            fakeMouse = V(middle + 230, floor - 230)
            at(0.2) { [self] in quiet(); say("吃小鱼") }
            at(1.0) { [self] in quiet(); goo.whaleSnack() }
            at(5.0) { [self] in quiet(); goo.whaleSnack() }
            at(9.0) { [self] in log("showcase done") }
            return
        }
        if goo.costume.isWhale && asked.contains("eggs") {
            // ",eggs": the whale girl's own moves that are not scenes of work: swimming along, stroked, her leap, the fish,
            // a long job's rainbow, held up dripping and dropped with a splash, asleep breathing bubbles
            fakeMouse = V(middle + 230, floor - 230)
            at(0.2) { [self] in quiet(); say("游一游") ; goo.wanderTo = middle - 3 * goo.radius }
            at(3.4) { [self] in quiet(); goo.wanderTo = middle }
            at(6.4) { [self] in say("摸摸头"); quiet(); glide(to: goo.c + V(2, -goo.radius * 0.7), seconds: 0.5) }
            at(7.2) { [self] in glide(to: goo.c + V(-6, -goo.radius * 0.5), seconds: 0.9) }
            at(8.1) { [self] in glide(to: V(middle + 230, floor - 230), seconds: 0.6) }
            at(9.6) { [self] in say("鲸跃"); quiet(); goo.whaleBreach() }
            at(12.6) { [self] in say("吃小鱼"); quiet(); goo.whaleSnack() }
            at(16.0) { [self] in say("长任务做完：彩虹"); quiet(); goo.act = "run"; goo.costume.busySince = goo.clock - 70 }
            at(18.0) { [self] in goo.act = ""; goo.celebrate() }
            at(21.4) { [self] in say("拎起来，滴水"); quiet(); glide(to: goo.c, seconds: 0.4) }
            at(22.0) { [self] in
                goo.press(goo.c)
                let start = goo.c, began = CACurrentMediaTime()
                ticker?.invalidate()
                ticker = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    self.fakeMouse = start + V(0, -min(1, (CACurrentMediaTime() - began) * 1.5) * self.goo.radius * 6)
                    if CACurrentMediaTime() - began > 2.2 { timer.invalidate() }
                }
                RunLoop.main.add(ticker!, forMode: .common)
            }
            at(24.6) { [self] in say("从高处落下：拍水"); goo.candidate = nil; goo.release() }
            at(26.6) { [self] in glide(to: V(middle + 230, floor - 230), seconds: 0.4) }
            at(27.4) { [self] in say("睡着，吐泡泡"); quiet(); goo.lastMoved = goo.clock - 41 }
            at(34.0) { [self] in log("showcase done") }
            return
        }
        if goo.costume.isWhale && !asked.contains("moves") {   // ",moves": the moves every outfit plays, in her
            // plain Tako puts the whale girl on (as when a DeepSeek key is saved), then her moves; the cursor well away, so it
            // neither leans toward it nor reaches for it
            let whale = goo.costume.outfit
            goo.costume.outfit = nil
            fakeMouse = V(middle + 230, floor - 230)
            quiet()
            at(0.2) { [self] in quiet(); say("Tako") }
            at(1.2) { [self] in say("接上 DeepSeek"); goo.costume.outfit = whale; goo.showOff() }
            at(4.6) { [self] in say("开心，喷水"); quiet(); goo.celebrate() }
            at(6.6) { [self] in say("甩尾巴"); quiet(); goo.swishTail() }
            at(8.4) { [self] in say("完成一件事"); quiet(); goo.celebrate() }
            at(10.0) { [self] in say("游一游"); quiet(); goo.wanderTo = middle - 140 }
            at(12.4) { [self] in quiet(); goo.wanderTo = middle }
            at(14.4) { [self] in say("摸摸头"); glide(to: goo.c + V(2, -goo.radius * 0.7), seconds: 0.5) }
            at(15.2) { [self] in glide(to: goo.c + V(-6, -goo.radius * 0.5), seconds: 0.9) }
            at(16.1) { [self] in glide(to: goo.c + V(6, -goo.radius * 0.7), seconds: 0.9) }
            at(17.0) { [self] in glide(to: V(middle + 230, floor - 230), seconds: 0.6) }
            // and, as the film ends, sitting pleased with her spout up
            at(18.4) { [self] in say(title); quiet(); goo.happyUntil = goo.clock + 2.4; goo.spout(1) }
            at(21.4) { [self] in log("showcase done") }
            return
        }
        at(0.2) { [self] in quiet(); say(title) }
        at(1.6) { [self] in say("好奇"); glide(to: goo.c + V(goo.radius * 2.6, -goo.radius * 2.2), seconds: 1.2) }
        at(3.4) { [self] in say("摸摸头"); glide(to: goo.c + V(2, -goo.radius * 0.7), seconds: 0.5) }
        at(4.2) { [self] in glide(to: goo.c + V(-6, -goo.radius * 0.5), seconds: 0.9) }
        at(5.1) { [self] in glide(to: goo.c + V(6, -goo.radius * 0.7), seconds: 0.9) }
        at(6.0) { [self] in glide(to: goo.c + V(-4, -goo.radius * 0.6), seconds: 0.9) }
        at(7.0) { [self] in glide(to: V(middle + 170, floor - 150), seconds: 0.6) }
        at(7.8) { [self] in say("溜达"); quiet(); goo.wanderTo = middle - 200 }
        at(10.0) { [self] in quiet(); goo.wanderTo = middle + 170 }
        at(12.4) { [self] in quiet(); goo.wanderTo = middle }
        at(13.2) { [self] in say("撒欢"); quiet(); goo.startZoomies() }
        at(16.4) { [self] in say("办完事，开心"); goo.wanderTo = nil; quiet(); goo.celebrate() }
        // the cursor stops near it and stays still: a limb creeps out for it; the cursor moves and it is caught
        at(18.2) { [self] in say("偷偷伸手"); quiet(); glide(to: goo.c + V(goo.radius * 4.2, -goo.radius * 2.4), seconds: 0.8) }
        at(23.4) { [self] in say("被抓包"); glide(to: (fakeMouse ?? goo.c) + V(14, 6), seconds: 0.15) }
        at(25.4) { [self] in say("被拎起来晃"); quiet(); glide(to: goo.c, seconds: 0.6) }
        at(26.1) { [self] in
            goo.press(goo.c)
            let start = goo.c, began = CACurrentMediaTime()
            ticker?.invalidate()
            ticker = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = CACurrentMediaTime() - began
                // up a little, shaken hard from side to side, then held still so it drops where it is
                let shake = t < 1.2 ? sin(t * 24) * 70 : 0
                self.fakeMouse = start + V(shake, -min(1, t * 3) * 60)
                if t > 1.6 { timer.invalidate() }
            }
            RunLoop.main.add(ticker!, forMode: .common)
        }
        at(27.9) { [self] in say("晃晕了"); goo.candidate = nil; goo.release() }   // dropped where it is, not onto a window
        at(30.0) { [self] in glide(to: V(middle + 170, floor - 150), seconds: 0.6) }
        at(31.0) { [self] in say("困了"); goo.dizzyUntil = 0; quiet(); goo.lastMoved = goo.clock - 41 }
        at(34.8) { [self] in say(title); glide(to: goo.c + V(goo.radius * 2.4, -goo.radius * 1.8), seconds: 0.5) }
        at(37.0) { [self] in log("showcase done") }
    }
}

