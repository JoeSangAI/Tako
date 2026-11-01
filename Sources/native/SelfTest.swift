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
            log("self-test done")
        }
    }
}
