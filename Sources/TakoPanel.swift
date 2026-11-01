// Tako as a soft body: clings to any window it is dropped on, peels off into a desktop pet, sticks back on.
// With the Accessibility permission it may move that window left to make room, and moves it back.
// Three panels: a screen-sized click-through one for the goo (drawn with Core Animation, so nothing
// waits on a web page), a side window whose contents are the web page, and the ink around the
// window (Enchant.swift). What it can do to the window lives in Hands.swift.
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreImage
import QuartzCore
import ScreenCaptureKit
import Vision
import WebKit

let sidePanelWidth: CGFloat = 720
let minimumWidth: CGFloat = 280
let minimumSharedWidth: CGFloat = 420   // a window sharing the screen with the panel never gets narrower than this
let widthKey = "sideWidth"
let modeKey = "gooMode"
// It sticks to any ordinary window except these. DingTalk's foreground app is off limits by rule.
let blockedOwners: Set<String> = ["Tako", "TAKO", "钉钉", "DingTalk", "universalAccessAuthWarn", "Dock", "Window Server", "程序坞", "控制中心", "通知中心", "UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent"]
let weChatBundle = "com.tencent.xinWeChat"

struct V {
    var x: CGFloat, y: CGFloat
    init(_ x: CGFloat = 0, _ y: CGFloat = 0) { self.x = x; self.y = y }
    static func + (a: V, b: V) -> V { V(a.x + b.x, a.y + b.y) }
    static func - (a: V, b: V) -> V { V(a.x - b.x, a.y - b.y) }
    static func * (a: V, k: CGFloat) -> V { V(a.x * k, a.y * k) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
    var unit: V { let l = length; return l < 0.001 ? V(1, 0) : V(x / l, y / l) }
    var normal: V { V(-y, x) }
}
func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func mix(_ a: V, _ b: V, _ t: CGFloat) -> V { V(mix(a.x, b.x, t), mix(a.y, b.y, t)) }
func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, x)) }

enum Mode { case attached, open, grabbed, free }

final class SideWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    // Left to itself AppKit pushes a panel down out of the menu bar, and the ink would no longer sit on the window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - The goo

final class GooView: NSView {
    weak var owner: Controller?
    override var acceptsFirstResponder: Bool { true }
    // Feed it a file: it swallows it and the side window opens with it attached.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard owner?.goo.mode == .attached || owner?.goo.mode == .open else { return [] }
        owner?.goo.pop = 1
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        owner?.goo.kick(150)
        return owner?.takeFiles(sender) ?? false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.goo.press(owner?.mouse() ?? V()) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { owner?.goo.release() }
    override func rightMouseDown(with event: NSEvent) { owner?.showMenu(event, in: self) }
}

final class Goo {
    unowned let host: Controller
    let view: GooView
    // layers
    let strands = (0..<3).map { _ in CAShapeLayer() }
    let body = CAShapeLayer()
    let eyeL = CAShapeLayer(), eyeR = CAShapeLayer(), pupilL = CAShapeLayer(), pupilR = CAShapeLayer()
    let mouth = CAShapeLayer(), gloss = CAShapeLayer(), bits = CAShapeLayer(), ground = CAShapeLayer()
    // soft body
    static let count = 28
    var c = V(), v = V()
    var ring = [V](repeating: V(), count: Goo.count), ringV = [V](repeating: V(), count: Goo.count)
    var radius: CGFloat = 13, radiusTarget: CGFloat = 13
    var mode = Mode.attached
    var home = V()
    var settled = false
    // strands
    var reach: [CGFloat] = [0, 0, 0], reachV: [CGFloat] = [0, 0, 0]
    var stuck = [false, false, false]
    var anchor = [V(), V(), V()]
    // pointer
    var grabOffset = V(), grabStart = V(), grabTime = 0.0, grabMoved = false
    var fromAttached = false
    var mouseAt = V(), mouseSpeed = V(), lastMouse = V()
    // bits of goo
    var drops: [(p: V, v: V, r: CGFloat, life: CGFloat)] = []
    var stains: [(p: V, r: CGFloat, life: CGFloat)] = []
    // face
    var eye = V(), slosh = V(), sloshV = V(), lastV = V(), gaze = V(), lid: CGFloat = 1, blink: CGFloat = 0, nextBlink = 2.5, pop: CGFloat = 0
    var state = "idle"
    var clock = 0.0, lastMoved = 0.0
    // pet life
    var nextWander = 14.0, wanderTo: CGFloat?, creep: CGFloat = 0
    var standingID: Int?, standLeft: CGFloat = 0
    var splatNormal = V(), splatUntil = 0.0, splatAmount: CGFloat = 0
    var dizzyUntil = 0.0, shakes: [Double] = [], lastShakeSign: CGFloat = 0
    var clicks: [Double] = []
    var sleeping = false, nextZ = 0.0, zs: [(p: V, life: CGFloat)] = []
    var lean: CGFloat = 0, leanDir = V(1, 0), hoverTime = 0.0
    var tall: CGFloat = 0, tallTime = 0.0, lookTime = 0.0, lookAt = V(), nextAct = 6.0
    let zLayer = CAShapeLayer()
    // Everything gooey is drawn into one layer that is blurred and then cut back to a hard edge,
    // so body, strands, legs and arms flow into each other like one liquid.
    let liquid = CALayer()
    let sparkleL = CAShapeLayer(), sparkleR = CAShapeLayer(), lidL = CAShapeLayer(), lidR = CAShapeLayer(), swirl = CAShapeLayer()
    // mischief
    let arms = CAShapeLayer(), inkLayer = CAShapeLayer(), outline = CAShapeLayer()
    var armTip = V(), armOut: CGFloat = 0, armArrived = false
    var armLeg = 3, armStrand = 2, armWanted = false  // it reaches with a limb it already has
    var heavy: CGFloat = 0  // how far the upper lids have come down
    var guiltyUntil = 0.0, smirkUntil = 0.0
    var ink: [(p: V, v: V, r: CGFloat, life: CGFloat)] = []
    var peekSide: CGFloat = 0, peekUntil = 0.0, ducking = false, lastNear = 0.0
    var puddle = false
    var pokes = 0
    var stance: CGFloat { puddle ? 0.45 : 1.6 }  // how high it stands above whatever is under it
    var guilty: Bool { clock < guiltyUntil }
    var dizzy: Bool { clock < dizzyUntil }
    // bounds
    var visible = CGRect.zero, screenRect = CGRect.zero
    var candidate: CGFloat?  // right edge of a window we could stick to, if close enough
    var candidateID: Int?
    var reachGoal: V?        // somewhere the host wants it to put a limb: an input, a line of text
    // Something far away: the body goes over and puts out a short arm, rather than one long line across the screen.
    static let armReach: CGFloat = 170
    var perch: V?            // where it works from, measured from the window's top left, so it moves with the window
    var perchUntil = 0.0
    var hop: (from: V, start: Double, length: Double)?
    var happyUntil = 0.0, oopsUntil = 0.0
    var happy: Bool { clock < happyUntil }
    var oops: Bool { clock < oopsUntil }
    var onDark = false       // on a dark window the ink needs a light edge to be seen at all
    var surface: CGFloat = 0
    var peakAway: CGFloat = 0  // self-test: furthest the skin got from the centre, in radii

    init(host: Controller, view: GooView) {
        self.host = host
        self.view = view
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        let root = view.layer!
        root.isOpaque = false
        root.backgroundColor = NSColor.clear.cgColor
        ground.fillColor = NSColor(white: 0, alpha: 0.13).cgColor
        root.addSublayer(ground)
        let goo = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1).cgColor
        let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.6])!
        let edge = CIFilter(name: "CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 15),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -5.4)])!
        // Without this the boosted alpha stays above 1 and multiplies the colour up to a washed-out grey.
        let limit = CIFilter(name: "CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])!
        liquid.filters = [blur, edge, limit]
        root.addSublayer(liquid)
        for layer in strands { layer.fillColor = goo; liquid.addSublayer(layer) }
        bits.fillColor = goo
        root.addSublayer(bits)
        zLayer.fillColor = nil
        zLayer.strokeColor = NSColor(white: 0.06, alpha: 0.65).cgColor
        zLayer.lineWidth = 1.3
        zLayer.lineCap = .round
        root.addSublayer(zLayer)
        inkLayer.fillColor = NSColor(white: 0, alpha: 0.16).cgColor
        root.addSublayer(inkLayer)
        arms.fillColor = goo
        liquid.addSublayer(arms)
        body.fillColor = goo
        liquid.addSublayer(body)
        outline.fillColor = nil
        outline.strokeColor = NSColor(white: 1, alpha: 0.28).cgColor
        outline.lineWidth = 1
        root.addSublayer(outline)
        // black and white only: a wet highlight along the upper edge, a faint bounce below
        gloss.fillColor = nil
        gloss.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
        gloss.lineCap = .round
        for layer in [eyeL, eyeR] { layer.fillColor = NSColor.white.cgColor }
        for layer in [pupilL, pupilR] { layer.fillColor = goo }
        mouth.fillColor = NSColor.white.cgColor
        for layer in [sparkleL, sparkleR] { layer.fillColor = NSColor.white.cgColor }
        for layer in [lidL, lidR] { layer.fillColor = goo }
        swirl.fillColor = nil
        swirl.strokeColor = goo
        swirl.lineCap = .round
        for layer in [gloss, eyeL, eyeR, pupilL, pupilR, sparkleL, sparkleR, swirl, lidL, lidR, mouth] { root.addSublayer(layer) }
    }

    func place(at p: V) {
        c = p; v = V(); eye = p
        for i in 0..<Goo.count { ring[i] = target(i); ringV[i] = V() }
    }

    func dir(_ i: Int) -> V {
        let a = CGFloat(i) / CGFloat(Goo.count) * 2 * .pi
        return V(cos(a), sin(a))
    }

    func target(_ i: Int) -> V {
        let d = dir(i)
        let breathe = 1 + (sleeping ? 0.04 * sin(CGFloat(clock) * 1.1) : 0.018 * sin(CGFloat(clock) * 1.5))
        let stretch = (1 + creep * 0.1 * sin(CGFloat(clock) * 7)) / (1 + tall * 0.28)
        var shape = V(d.x * radius * breathe * stretch, d.y * radius * breathe / stretch)
        if splatAmount > 0.01 {
            // Flattened against whatever it hit: wide along the surface, thin across it.
            let across = d.x * splatNormal.x + d.y * splatNormal.y
            let along = V(d.x - across * splatNormal.x, d.y - across * splatNormal.y)
            let flat = (along * (1 + (puddle ? 1 : 0.42) * splatAmount)) + (splatNormal * (across * (1 - (puddle ? 0.58 : 0.46) * splatAmount)))
            shape = mix(shape, flat * radius, splatAmount)
        }
        if lean > 0.01 {
            // A little bulge creeping toward the cursor.
            let toward = max(0, d.x * leanDir.x + d.y * leanDir.y)
            shape = shape + d * (toward * toward * toward * lean * radius)
        }
        return c + shape
    }

    // MARK: moods

    func makeDizzy(_ seconds: Double, _ why: String) {
        dizzyUntil = max(dizzyUntil, clock + seconds)
        host.log("dizzy: \(why)")
    }

    /// Torn off whatever it was stuck to, flying away from it.
    func tearOff(velocity: V, reason: String) {
        host.closeSide()
        mode = .free
        settled = false
        v = velocity
        for i in 0..<3 where stuck[i] {
            stuck[i] = false
            reachV[i] = -7
            stains.append((anchor[i], 4.2, 1.5))
        }
        kick(120)
        spray(at: c, 3, speed: 150, along: velocity.unit)
        peelOff(reason: reason)
    }

    func startSplat(_ normal: V) {
        splatNormal = normal
        // A ceiling can't hold it long; a wall lets it ooze down for a while.
        splatUntil = clock + (normal.y < 0 ? 0.9 : 2.3)
        settled = false
        standingID = nil
        v = V()
        kick(160)
        pop = 0.8
        spray(at: c + normal * radius, 4, speed: 240, along: normal * -1)
        makeDizzy(normal.y < 0 ? 1.8 : 3, "splat")
        host.log("splat \(Int(normal.x)),\(Int(normal.y))")
    }

    /// Finished something it was asked to do: a little hop, eyes shut with pleasure.
    func celebrate() {
        guard !sleeping, !dizzy else { return }
        happyUntil = clock + 1.5
        pop = 0.6
        kick(110)
        lookTime = 0
        if mode == .free && settled { v.y = -230; settled = false }
    }

    /// Something it tried did not work: it sags, one drop of sweat, and looks at you sideways.
    func fumble() {
        guard !sleeping else { return }
        oopsUntil = clock + 2.4
        happyUntil = 0
        kick(60)
        spray(at: c + V(radius * 0.8, -radius * 0.6), 2, speed: 70, along: V(0.7, -0.6))
    }

    func startSleep() {
        sleeping = true
        host.log("asleep")
    }

    // MARK: mischief

    /// Scared or fed up: a cloud of ink, and off it goes.
    func squirt(away from: V) {
        let d = (c - from).unit
        for _ in 0..<8 {
            let spread = V(CGFloat.random(in: -70...70), CGFloat.random(in: -70...70))
            ink.append((c, (d * CGFloat.random(in: -240 ... -80)) + spread, CGFloat.random(in: 3...6), CGFloat.random(in: 0.9...1.5)))
        }
        kick(150)
        pop = 0.9
    }

    /// Slinks to the nearest screen edge and watches from there with half its face.
    func startPeek() {
        guard mode == .free, standingID == nil else { return }
        peekSide = c.x > visible.midX ? 1 : -1
        peekUntil = clock + 26
        ducking = false
        wanderTo = nil
        host.log("sneaking to the edge")
    }

    /// Gives up on having a shape for a while.
    func startPuddle() {
        puddle = true
        splatNormal = V(0, 1)
        splatUntil = clock + 7
        wanderTo = nil
        host.log("puddle")
    }

    func endPuddle(_ startled: Bool) {
        puddle = false
        splatUntil = 0
        settled = false
        v.y = startled ? -240 : -120
        kick(70)
    }

    func updateMischief(_ m: V, _ distance: CGFloat, _ dt: CGFloat) {
        let still = clock - lastMoved
        var goal: V?
        let free = !sleeping && !puddle && peekSide == 0 && !dizzy && !guilty && mode != .grabbed && mode != .open
        var quick: CGFloat = 62
        if hop != nil {
            goal = nil                          // limbs in while it is in the air
        } else if let asked = reachGoal {
            goal = asked                        // it has been asked to touch something over there
            armStrand = 1
            quick = 620
        } else if perch != nil {
            goal = nil                          // over there, waiting for the next thing to touch
        } else if state == "working", mode == .attached, let w = host.target?.frame {
            // working the window: a limb in it, feeling about
            goal = V(w.maxX - 70 + sin(CGFloat(clock) * 2.3) * 26, w.midY + cos(CGFloat(clock) * 1.7) * 60)
            armStrand = 1
            quick = 420
        } else if state == "reading", mode == .attached, let w = host.target?.frame {
            goal = V(w.maxX - 44, c.y + 16)    // the middle strand wanders into the window while it reads
            armStrand = 1
        } else if free && still > 2.5 && distance < 260 && distance > radius + 14 {
            goal = m                            // the cursor has gone quiet: go for it
            armStrand = 2
        }
        armWanted = goal != nil
        if goal != nil && armOut < 2 { armLeg = (goal!.x > c.x) ? 3 : 0 }
        let rest = armRest()
        // Moved while the arm is out: caught. It was never doing anything.
        if armOut > 12 && still < 0.05 && state == "idle" && reachGoal == nil && !guilty {
            guiltyUntil = clock + 1.9
            goal = nil
            armArrived = false
            host.log("caught reaching")
        }
        if let g = goal {
            let to = g - armTip
            if to.length > 3 {
                armTip = armTip + to.unit * min(to.length, quick * dt)
            } else if !armArrived {
                armArrived = true
                if state == "idle" { pop = 0.5 }
                host.log("arm arrived")
            }
        } else {
            let back = rest - armTip
            armTip = armTip + back.unit * min(back.length, (hop != nil ? 3000 : 900) * dt)
            armArrived = false
        }
        armOut = (armTip - rest).length

        // ink thins out
        for i in ink.indices.reversed() {
            ink[i].life -= dt
            ink[i].p = ink[i].p + ink[i].v * dt
            ink[i].v = ink[i].v * pow(0.08, dt)
            ink[i].r += dt * 10
            if ink[i].life < 0 { ink.remove(at: i) }
        }

        // the puddle pulls itself together when the cursor comes near
        if puddle && (distance < 70 || clock >= splatUntil) { endPuddle(distance < 70) }

        // peeking: ducks out of sight when the cursor gets close, comes back when it has gone
        if peekSide != 0 {
            if distance < 135 {
                if !ducking { ducking = true; host.log("ducked") }
                lastNear = clock
            } else if ducking && clock - lastNear > 2.2 {
                ducking = false
            }
            if clock > peekUntil { peekSide = 0; settled = false; v = V(0, -200) }
        }

    }

    /// A tapered limb through the given points, added as one filled shape.
    func taper(_ points: [V], _ w0: CGFloat, _ waist: CGFloat, _ w1: CGFloat, into path: CGMutablePath) {
        var fine: [V] = []
        let at = { (i: Int) in points[max(0, min(points.count - 1, i))] }
        for i in 0..<(points.count - 1) {
            let a = at(i - 1), b = at(i), c = at(i + 1), e = at(i + 2)
            for step in 0..<6 {
                let t = CGFloat(step) / 6, t2 = t * t, t3 = t2 * t
                let f = { (a: CGFloat, b: CGFloat, c: CGFloat, e: CGFloat) -> CGFloat in
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - e) * t2 + (3 * b - a - 3 * c + e) * t3)
                }
                fine.append(V(f(a.x, b.x, c.x, e.x), f(a.y, b.y, c.y, e.y)))
            }
        }
        fine.append(points[points.count - 1])
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in fine.enumerated() {
            let d = (fine[min(fine.count - 1, i + 1)] - fine[max(0, i - 1)]).unit
            let s = CGFloat(i) / CGFloat(fine.count - 1)
            let w = s < 0.5 ? mix(w0, waist, pow(s * 2, 0.55)) : mix(waist, w1, pow((s - 0.5) * 2, 1.8))
            let n = V(-d.y, d.x) * w
            left.append(L(p + n))
            right.append(L(p - n))
        }
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
    }

    /// One of the four legs: hip, knee, foot and the two points of its curled tip.
    func leg(_ k: Int) -> [V] {
        let r = radius, f = CGFloat(k) - 1.5, spread = r * 0.32
        let side: CGFloat = f > 0 ? 1 : -1
        let hip = V(c.x + f * spread * 0.8, c.y + r * 0.62)
        if mode == .free && settled {
            let ground = surface - 0.6
            let step = creep * (peekSide != 0 ? 1.6 : 1)
            let phase = CGFloat(clock) * 10 + CGFloat(k) * .pi
            let foot = V(c.x + f * spread * 1.5 + sin(phase) * 2.6 * step, ground - r * 0.1 - max(0, cos(phase)) * 2.4 * step)
            let knee = V(c.x + f * spread * 1.05, (hip.y + ground) / 2)
            return [hip, knee, foot, foot + V(side * r * 0.2, r * 0.02), foot + V(side * r * 0.32, -r * 0.1)]
        }
        // Off the ground they hang and wiggle; at speed they stream out behind it.
        let wiggle = sin(CGFloat(clock) * 9 + CGFloat(k) * 1.7) * r * 0.14
        let hang = V(f * r * 0.22 + wiggle, r * 0.62)
        let speed = v.length
        let streaming = clamp((speed - 260) / 500, 0, 1)
        let behind = (v * -1).unit
        let across = behind.normal * (f * r * 0.34)
        let foot = hip + mix(hang, (behind * (r * 1.25)) + across, streaming)
        let knee = mix(hip, foot, 0.5) + V(f * r * 0.08, 0)
        let curl = mix(V(side * r * 0.16, -r * 0.1), behind.normal * (side * r * 0.2), streaming)
        return [hip, knee, foot, foot + curl]
    }

    /// Where the reaching limb sits when it isn't reaching.
    func armRest() -> V {
        if mode == .free || mode == .grabbed { return leg(armLeg)[2] }
        return c + (anchor[armStrand] - c).unit * (radius * 0.55)
    }

    func drawArms() {
        let r = radius
        let path = CGMutablePath()
        let hasLegs = (mode == .free || mode == .grabbed || perch != nil) && !puddle && !sleeping
        let out = armOut > 3
        // The limb that goes reaching: one of the legs, or one of the strands while it is stuck on.
        if out {
            let isLeg = mode == .free || mode == .grabbed
            let root = isLeg ? leg(armLeg)[0] : c + (armTip - c).unit * (r * 0.55)
            // A leg leaves along the ground first and only then rises, so it reads as that leg;
            // going straight up it would vanish behind the body and seem to sprout from its side.
            let side: CGFloat = armTip.x >= root.x ? 1 : -1
            let reachOut = clamp(armOut * 0.5, 0, r * 1.5)
            let elbow = isLeg ? V(root.x + side * reachOut, root.y + clamp(reachOut * 0.45, 0, r * 0.5)) : root
            let along = armTip - elbow, n = along.unit.normal
            // A strand hangs in a curve under its own weight; only a leg goes more or less straight.
            let sag = isLeg ? 0 : clamp(armOut * 0.3, 0, 32) * (n.y >= 0 ? 1 : -1)
            var points = isLeg ? [root, elbow] : [root]
            let steps = 7
            for i in 1...steps {
                let s = CGFloat(i) / CGFloat(steps)
                let wave = sin(s * 6.5 - CGFloat(clock) * 5) * min(isLeg ? 6 : 3, armOut * 0.09) * sin(s * .pi)
                var p = elbow + (along * s) + (n * (wave + sag * sin(s * .pi)))
                if armArrived && i == steps { p = p + V(0, sin(CGFloat(clock) * 14) * 2) }  // tap tap
                points.append(p)
            }
            if isLeg {
                taper(points, r * 0.22, max(1.7, r * 0.11), max(1.5, r * 0.085), into: path)
            } else {
                // Thick where it leaves the body, thin along the way, a small pad on the end.
                taper(points, r * 0.36, max(2, r * 0.17), max(1.6, r * 0.12), into: path)
                path.addPath(ellipse(points[points.count - 1], r * 0.19, r * 0.19))
            }
        }
        if hasLegs {
            for k in 0..<4 where !(out && k == armLeg) {
                taper(leg(k), r * 0.22, max(1.7, r * 0.11), max(1.5, r * 0.085), into: path)
            }
        }
        arms.path = path

        let puffs = CGMutablePath()
        for puff in ink {
            let size = puff.r * min(1, puff.life / 0.45)
            puffs.addPath(ellipse(puff.p, size, size))
        }
        inkLayer.path = puffs

    }

    func wake(startled: Bool) {
        sleeping = false
        lastMoved = clock
        if startled {
            v.y = -340
            settled = false
            standingID = nil
            pop = 1
            squirt(away: mouseAt)
            host.log("woken with a start")
        }
    }

    func updateMoods(_ m: V, _ dt: CGFloat) {
        let toMouse = m - c
        let distance = toMouse.length
        // Leaning toward the cursor; shy once it is right on top.
        let wantLean = (mode == .grabbed || sleeping || mode == .open) ? 0 : clamp(1 - distance / 105, 0, 1) * 0.3
        lean += (wantLean - lean) * min(1, dt * 7)
        if distance > 3 { leanDir = mix(leanDir, toMouse.unit, min(1, dt * 8)).unit }
        updateMischief(m, distance, dt)

        hoverTime = (distance < radius + 5 && mode != .grabbed) ? hoverTime + Double(dt) : 0

        // Shaken while held: enough reversals in a second and it gets dizzy.
        if mode == .grabbed {
            let sign: CGFloat = abs(mouseSpeed.x) > 420 ? (mouseSpeed.x > 0 ? 1 : -1) : 0
            if sign != 0 && sign != lastShakeSign {
                if lastShakeSign != 0 { shakes.append(clock) }
                lastShakeSign = sign
            }
            shakes.removeAll { clock - $0 > 1.2 }
            if shakes.count >= 4 {
                shakes.removeAll()
                makeDizzy(3.2, "shaken")
                spray(at: c, 3, speed: 230, along: mouseSpeed.unit)
                kick(120)
            }
        }

        // Asleep after a long stillness; a cursor nearby startles it awake.
        if mode == .free && settled && !sleeping && clock - lastMoved > 40 && state == "idle" { startSleep() }
        if sleeping {
            if clock - lastMoved < 0.05 { wake(startled: distance < 75) }
            nextZ -= Double(dt)
            if nextZ <= 0 {
                nextZ = 1.5
                zs.append((c + V(radius * 0.7, -radius * 0.8), 2.2))
            }
        }
        for i in zs.indices.reversed() {
            zs[i].life -= dt
            zs[i].p = zs[i].p + V(sin(zs[i].life * 3) * 5 * dt, -11 * dt)
            if zs[i].life < 0 { zs.remove(at: i) }
        }

        // Stuck on a window it isn't idle either: it glances into the window, and now and then pats it.
        if mode == .attached && state == "idle" && armOut < 3 && !guilty && clock > nextAct {
            nextAct = clock + Double.random(in: 7...18)
            switch Int.random(in: 0..<4) {
            case 0:
                lookTime = 1.6
                lookAt = V(-1, CGFloat.random(in: -0.4...0.4))
            case 1:
                lookTime = 0.9
                lookAt = (mouseAt - c).unit
                smirkUntil = clock + 0.9
            case 2:
                kick(55)
            default:
                if let w = host.target?.frame {
                    let goal = V(w.maxX - 14, clamp(c.y + CGFloat.random(in: -24...24), w.minY + 8, w.maxY - 8))
                    reachGoal = goal
                    armArrived = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                        if self?.reachGoal?.x == goal.x { self?.reachGoal = nil }
                    }
                }
            }
        }

        // Small things it does on its own.
        tallTime = max(0, tallTime - Double(dt))
        tall += ((tallTime > 0 ? 1 : 0) - tall) * min(1, dt * 5)
        lookTime = max(0, lookTime - Double(dt))
        if mode == .free && settled && !sleeping && !puddle && peekSide == 0 && wanderTo == nil && armOut < 3 && clock > nextAct {
            nextAct = clock + Double.random(in: 9...22)
            switch Int.random(in: 0..<7) {
            case 0: tallTime = 1.3                               // yawn and stretch
            case 1: v.y = -210; settled = false; kick(70)        // a little hop
            case 2: startPeek()
            case 3: startPuddle()
            case 4:                                              // a smirk at nothing in particular
                smirkUntil = clock + 2
                lookTime = 2
                lookAt = (mouseAt - c).unit
            default:
                lookTime = 1.4
                lookAt = V(Bool.random() ? 1 : -1, CGFloat.random(in: -0.5...0.2))
            }
        }
    }

    var isAttachedLike: Bool { mode == .attached }

    // MARK: pointer

    func press(_ m: V) {
        grabOffset = c - m
        grabStart = m
        grabTime = clock
        grabMoved = false
        fromAttached = mode == .attached || mode == .open
        wasOpen = mode == .open
        if mode == .open { host.closeSide() }
        if sleeping { wake(startled: false) }
        puddle = false
        peekSide = 0
        mode = .grabbed
        settled = false
        standingID = nil
        splatUntil = 0
        wanderTo = nil
        creep = 0
        kick(70)
    }
    var wasOpen = false

    func release() {
        guard mode == .grabbed else { return }
        if !grabMoved && clock - grabTime < 0.4 {
            if fromAttached {
                mode = .attached
                if !wasOpen { host.toggleSide() }
            } else {
                mode = .free
                v = V(v.x, -230)
                kick(130)
                pop = 0.9
                // Poke it too many times and it gets annoyed.
                clicks.append(clock)
                clicks.removeAll { clock - $0 > 1.4 }
                if clicks.count == 2 { smirkUntil = clock + 1.1; lookTime = 1.1; lookAt = (mouseAt - c).unit }  // a warning look
                if clicks.count >= 3 {
                    clicks.removeAll()
                    // Enough. Ink, and off it goes.
                    let side: CGFloat = mouseAt.x > c.x ? -1 : 1
                    squirt(away: mouseAt)
                    v = V(side * 620, -420)
                    host.log("poked too much: inked")
                }
            }
            return
        }
        if stuck.contains(true) {
            // Let go before it tore free: everything springs back.
            mode = .attached
            kick(90)
            return
        }
        // Set down near the window it sticks; flung past the window it keeps flying.
        if let edge = candidate, mouseSpeed.length < 900 {
            stick(to: edge, window: candidateID)
        } else {
            mode = .free
            v = mouseSpeed * 0.75
        }
    }

    func stick(to edge: CGFloat, window id: Int? = nil) {
        mode = .attached
        radiusTarget = 13
        if let id { host.adopt(id, contact: c) } else if let current = host.target?.id { host.adopt(current, contact: c) }
        host.setWatching(true)
        for i in 0..<3 { stuck[i] = true; reach[i] = max(reach[i], 0.15); reachV[i] = 16 }
        pop = 0.7
        host.log("stuck to window")
        UserDefaults.standard.set("attached", forKey: modeKey)
    }

    func peelOff(reason: String) {
        // Tore completely free.
        mode = mode == .grabbed ? .grabbed : .free
        radiusTarget = 17
        host.enchant.peel(at: c)
        host.setWatching(false)
        host.log("peeled off: \(reason)")
        UserDefaults.standard.set("pet", forKey: modeKey)
    }

    func kick(_ strength: CGFloat) {
        let phase = CGFloat.random(in: 0...6.28)
        for i in 0..<Goo.count {
            let a = CGFloat(i) / CGFloat(Goo.count) * 2 * .pi
            ringV[i] = ringV[i] + dir(i) * (strength * (0.72 + 0.28 * sin(a * 3 + phase)))
        }
    }

    func spray(at p: V, _ count: Int, speed: CGFloat, along d: V) {
        for i in 0..<count {
            let spread = CGFloat(i) - CGFloat(count - 1) / 2
            let vel = (d * speed) + (d.normal * (spread * speed * 0.55)) + V(0, -40)
            drops.append((p, vel, CGFloat.random(in: 1.2...2.6), 0.8))
        }
    }

    // MARK: physics

    func step(_ dt: CGFloat) {
        clock += Double(dt)
        radius += (radiusTarget - radius) * min(1, dt * 7)

        let m = host.mouse()
        mouseSpeed = mouseSpeed * 0.9 + ((m - lastMouse) * (1 / dt)) * 0.1
        if (m - lastMouse).length > 0.01 { lastMoved = clock }
        lastMouse = m
        mouseAt = m
        updateMoods(m, dt)

        // where the window is, and whether we are close enough to grab it
        candidate = nil
        candidateID = nil
        if mode == .grabbed, !stuck.contains(true), let near = host.windowNear(c) {
            candidate = near.frame.maxX
            candidateID = near.id
        }
        let window = candidateID.flatMap { id in host.platforms.first { $0.id == id }?.frame } ?? host.target?.frame

        switch mode {
        case .attached:
            if let w = window {
                // On a window that fills the screen there is nothing to its right: it holds on from just inside.
                home = V(min(w.maxX + radius + 7, visible.maxX - radius - 4), min(w.minY + 66 + radius, w.maxY - radius))
                settle(in: w, k: 240, damping: 21, dt)
            }
        case .open:
            if let w = window {
                home = V(host.sideX + 27, w.minY + host.barHeight / 2)
                settle(in: w, k: 300, damping: 26, dt)
            }
        case .grabbed:
            perch = nil
            hop = nil
            let goal = m + grabOffset
            if (m - grabStart).length > 4 { grabMoved = true }
            // Stuck strands make it feel heavy until they let go.
            spring(to: goal, k: stuck.contains(true) ? 180 : 900, damping: stuck.contains(true) ? 16 : 46, dt)
        case .free:
            perch = nil
            hop = nil
            if puddle {
                v = V()
                c.y += ((surface - radius * stance) - c.y) * min(1, dt * 7)
                break
            }
            if clock < splatUntil {
                // Holding on to the glass, oozing down it.
                v = splatNormal.y < 0 ? V() : V(0, 24)
                break
            }
            if peekSide != 0 {
                // Scuttling to the edge of the screen; only the face stays in view.
                let edge = peekSide > 0 ? screenRect.maxX : screenRect.minX
                let goal = edge + peekSide * radius * (ducking ? 1.9 : 0.25)
                let to = goal - c.x
                creep += ((abs(to) > 2 ? 1 : 0) - creep) * min(1, dt * 6)
                v.x = clamp(to * 9, -(ducking ? 520 : 240), ducking ? 520 : 240)
                v.y += 1700 * dt
                break
            }
            v.y += 1700 * dt
            v.x *= pow(settled ? 0.0005 : 0.55, dt)
            if dizzy && settled { v.x = sin(CGFloat(clock) * 5) * 34 }  // staggering
            if let goal = wanderTo, settled {
                creep += (1 - creep) * min(1, dt * 3)
                v.x = (goal > c.x ? 1 : -1) * 20
                if abs(goal - c.x) < 3 { wanderTo = nil; nextWander = clock + Double.random(in: 14...40) }
            } else {
                creep += (0 - creep) * min(1, dt * 3)
                if settled && clock > nextWander && !sleeping && !dizzy {
                    let away = CGFloat.random(in: 40...150) * (Bool.random() ? 1 : -1)
                    var lo = visible.minX + 30, hi = visible.maxX - 30
                    if let id = standingID, let w = host.platforms.first(where: { $0.id == id })?.frame {
                        lo = max(lo, w.minX + radius + 4); hi = min(hi, w.maxX - radius - 4)
                    }
                    wanderTo = clamp(c.x + away, lo, hi)
                }
            }
        }
        let before = c
        c = c + v * dt

        splatAmount += ((clock < splatUntil ? 1 : 0) - splatAmount) * min(1, dt * (clock < splatUntil ? 26 : 6))

        // what it can stand on: the top of a window, otherwise the bottom of the screen
        surface = visible.maxY
        if mode == .free {
            if let id = standingID {
                if let w = host.platforms.first(where: { $0.id == id })?.frame, c.x > w.minX - 2, c.x < w.maxX + 2 {
                    surface = w.minY
                    if settled { c.x += w.minX - standLeft }   // the window carries it along
                    standLeft = w.minX
                    if settled { c.y = surface - radius * stance }
                } else {
                    standingID = nil
                    settled = false
                    host.log("window went away, falling")
                }
            } else if v.y > 0, clock >= splatUntil {
                let feet = radius * stance
                for (index, w) in host.platforms.enumerated() where c.x > w.frame.minX + 4 && c.x < w.frame.maxX - 4 {
                    guard before.y + feet <= w.frame.minY + 3, c.y + feet >= w.frame.minY else { continue }
                    // Only a top edge you can actually see: nothing in front of it.
                    let point = CGPoint(x: c.x, y: w.frame.minY - 1)
                    if host.platforms[..<index].contains(where: { $0.frame.contains(point) }) { continue }
                    surface = w.frame.minY
                    standingID = w.id
                    standLeft = w.frame.minX
                    break
                }
            }
        }

        // the floor and sides of the screen
        let floor = surface - radius * stance
        if mode == .free {
            if clock >= splatUntil && !puddle {
                if c.y > floor {
                    let hit = v.y
                    c.y = floor
                    if hit > 90 {
                        v.y = -hit * 0.3
                        settled = false
                        kick(min(hit * 0.14, 130))
                        if hit > 420 { spray(at: V(c.x, surface - 2), 3, speed: hit * 0.2, along: V(0, -1)); pop = max(pop, 0.5) }
                        if hit > 1500 { makeDizzy(1.6, "hard landing") }
                    } else {
                        v.y = 0
                        if !settled {
                            settled = true
                            nextWander = clock + Double.random(in: 8...22)
                            host.log(standingID == nil ? "landed" : "landed on window")
                        }
                    }
                }
                let hard: CGFloat = 620
                if peekSide != 0 {
                    // allowed past the edge
                } else if c.x < visible.minX + radius {
                    if -v.x > hard { c.x = visible.minX + radius * 0.6; startSplat(V(-1, 0)) } else { c.x = visible.minX + radius; v.x = abs(v.x) * 0.4 }
                } else if c.x > visible.maxX - radius {
                    if v.x > hard { c.x = visible.maxX - radius * 0.6; startSplat(V(1, 0)) } else { c.x = visible.maxX - radius; v.x = -abs(v.x) * 0.4 }
                } else if c.y < visible.minY + radius {
                    if -v.y > hard { c.y = visible.minY + radius * 0.6; startSplat(V(0, -1)) } else { c.y = visible.minY + radius; v.y = abs(v.y) * 0.3 }
                }
            }
        } else {
            c.x = clamp(c.x, visible.minX + 2, visible.maxX - 2)
            c.y = clamp(c.y, visible.minY + 2, visible.maxY - 2)
        }

        // the skin: each point chases its place on the circle, tugged by its neighbours
        let edgeX = (mode == .attached || candidate != nil) ? (window?.maxX ?? -9999) : -9999
        let floorY = surface
        var next = ringV
        let tremble: CGFloat = state == "thinking" ? 26 : 0
        for i in 0..<Goo.count {
            let a = ring[(i + Goo.count - 1) % Goo.count], b = ring[(i + 1) % Goo.count]
            var force = (target(i) - ring[i]) * 300
            force = force + ((a + b) - (ring[i] * 2)) * 60
            force = force - (ringV[i] - v) * 11
            if tremble > 0 { force = force + dir(i) * (tremble * sin(CGFloat(clock) * 40 + CGFloat(i))) }
            next[i] = ringV[i] + force * dt
        }
        ringV = next
        for i in 0..<Goo.count {
            ring[i] = ring[i] + ringV[i] * dt
            // However hard the hit, the skin never comes away from the body it wraps.
            let place = target(i)
            let away = ring[i] - place
            let limit = radius * 0.62
            if away.length > limit {
                ring[i] = place + away.unit * limit
                ringV[i] = mix(ringV[i], v, 0.5)
            }
            peakAway = max(peakAway, (ring[i] - c).length / radius)
            if ring[i].y > floorY { ring[i].y = floorY; ringV[i].y = min(0, ringV[i].y) }
            if ring[i].x < edgeX + 1 && c.x > edgeX { ring[i].x = edgeX + 1; ringV[i].x = max(0, ringV[i].x) }
            // the glass of the screen itself
            if peekSide == 0 {
                if ring[i].x < visible.minX { ring[i].x = visible.minX; ringV[i].x = max(0, ringV[i].x) }
                if ring[i].x > visible.maxX { ring[i].x = visible.maxX; ringV[i].x = min(0, ringV[i].x) }
            }
            if ring[i].y < visible.minY { ring[i].y = visible.minY; ringV[i].y = max(0, ringV[i].y) }
        }

        updateStrands(window, dt)
        updateBits(dt)
        updateFace(dt)
    }

    /// Stays at its spot by the window, unless what it has to touch is too far to reach from there: then it hops over.
    func settle(in w: CGRect, k: CGFloat, damping: CGFloat, _ dt: CGFloat) {
        let origin = V(w.minX, w.minY)
        if let goal = reachGoal {
            perchUntil = clock + 14
            if (goal - (perch.map { origin + $0 } ?? home)).length > Goo.armReach {
                // Beside the target on the side it came from, a little above, so the arm comes down onto it.
                let side = ((home - goal).unit + V(0.3, -0.9)).unit
                let spot = goal + side * 84
                perch = V(clamp(spot.x, visible.minX + radius + 6, visible.maxX - radius - 6) - w.minX,
                          clamp(spot.y, visible.minY + radius + 6, visible.maxY - radius - 6) - w.minY)
                beginHop(to: origin + perch!)
            }
        } else if perch != nil, clock > perchUntil || (state != "working" && state != "thinking" && state != "reading") {
            // Nothing more to touch: back to its place.
            perch = nil
            beginHop(to: home)
        }
        let place = perch.map { origin + $0 } ?? home
        guard let flight = hop else { return spring(to: place, k: k, damping: damping, dt) }
        let t = CGFloat((clock - flight.start) / flight.length)
        if t >= 1 {
            hop = nil
            v = (place - c) * (1 / dt)
            kick(46)
            spray(at: place + V(0, radius), 2, speed: 70, along: V(0, -1))
            return
        }
        let height = clamp((place - flight.from).length * 0.22, 16, 96)
        let p = mix(flight.from, place, t) - V(0, sin(t * .pi) * height)
        v = (p - c) * (1 / dt)
    }

    func beginHop(to place: V) {
        hop = (c, clock, Double(clamp(0.2 + (place - c).length / 1800, 0.26, 0.6)))
        kick(30)
    }

    func spring(to goal: V, k: CGFloat, damping: CGFloat, _ dt: CGFloat) {
        v = v + ((goal - c) * k - v * damping) * dt
    }

    func updateStrands(_ window: CGRect?, _ dt: CGFloat) {
        let offsets: [CGFloat] = [-0.72, 0, 0.72]
        let limits: [CGFloat] = [62, 96, 78]
        for i in 0..<3 {
            var goal: CGFloat = 0
            if let w = window {
                anchor[i] = V(w.maxX, anchorY(i, w, offsets[i]))
            }
            let length = (anchor[i] - c).length
            if stuck[i] {
                goal = 1
                if mode == .grabbed && length > limits[i] {
                    stuck[i] = false
                    reachV[i] = -7
                    let along = (c - anchor[i]).unit
                    v = v + along * 150
                    kick(55)
                    spray(at: mix(anchor[i], c, 0.5), 3, speed: 150, along: along * -1)
                    stains.append((anchor[i], 4.2, 1.5))
                    host.log("strand \(i) snapped at \(Int(length))")
                    if !stuck.contains(true) { peelOff(reason: "dragged away") }
                }
                if mode == .open || perch != nil || hop != nil { goal = 0 }
                if i == armStrand && (armWanted || armOut > 3) && mode == .attached { goal = 0 }
            } else if candidate != nil {
                // Close to a window: feelers reach out for it before you let go.
                let distance = c.x - (window?.maxX ?? c.x)
                // Over the middle of a window the edge is too far away to feel for.
                goal = distance < -60 ? 0 : clamp(1 - distance / 70, 0.25, 0.92) * (0.9 + 0.1 * sin(CGFloat(clock) * 5 + CGFloat(i) * 2))
            }
            reachV[i] += ((goal - reach[i]) * 210 - reachV[i] * 17) * dt
            reach[i] = clamp(reach[i] + reachV[i] * dt, 0, 1.08)
        }
    }

    func anchorY(_ i: Int, _ w: CGRect, _ offset: CGFloat) -> CGFloat {
        let base = min(w.minY + 66 + 13, w.maxY - 13)
        let reference = (mode == .attached || mode == .open) ? base : c.y
        return clamp(reference + offset * 13 + sin(CGFloat(clock) * 0.8 + CGFloat(i) * 2) * 1.2, w.minY + 4, w.maxY - 4)
    }

    func updateBits(_ dt: CGFloat) {
        for i in drops.indices.reversed() {
            drops[i].v.y += 1100 * dt
            drops[i].p = drops[i].p + drops[i].v * dt
            drops[i].life -= dt
            if drops[i].life < 0 || drops[i].p.y > visible.maxY { drops.remove(at: i) }
        }
        for i in stains.indices.reversed() {
            stains[i].life -= dt
            stains[i].p.y += dt * 7   // what is left on the window slides down it
            if stains[i].life < 0 { stains.remove(at: i) }
        }
    }

    func updateFace(_ dt: CGFloat) {
        pop = max(0, pop - dt * 1.3)
        // the face sloshes inside the body when the body changes speed, but never leaves it
        let shove = (v - lastV) * (1 / dt)
        lastV = v
        sloshV = sloshV + ((slosh * -520) - sloshV * 26 - V(clamp(shove.x, -9000, 9000), clamp(shove.y, -9000, 9000)) * 0.55) * dt
        slosh = slosh + sloshV * dt
        let limit = radius * 0.16
        if slosh.length > limit { slosh = slosh.unit * limit }
        eye = c + V(radius * 0.08, -radius * 0.14) + slosh

        var look: V
        switch state {
        case "reading", "working": look = V(-1, sin(CGFloat(clock) * 2) * 0.4)
        case "thinking": look = V(sin(CGFloat(clock) * 2.4) * 0.7, -1)
        default:
            let toMouse = mouseAt - c
            look = toMouse.length > 6 ? toMouse.unit * min(1, toMouse.length / 90) : V()
        }
        if let goal = reachGoal, (goal - c).length > 2 { look = (goal - c).unit }  // eyes on what it is touching
        if mode == .grabbed && mouseSpeed.length > 90 { look = (mouseSpeed * -1).unit }
        if mode == .free && !settled { look = (v * 1).unit }
        if lookTime > 0 { look = lookAt }
        // caught: looks anywhere but at you
        if guilty { look = ((c - mouseAt).unit + V(0, -0.5)).unit }
        // close up it won't meet your eye for long: a side glance, then away
        if mode != .grabbed && hoverTime > 0.15 && hoverTime < 1 { look = V(sin(CGFloat(hoverTime) * 9) > 0 ? 1 : -1, 0.1) }
        // dizzy: the pupils go round and round
        if dizzy { look = V(cos(CGFloat(clock) * 11), sin(CGFloat(clock) * 11)) }
        if oops { look = V(-0.8, 0.5) }
        gaze = mix(gaze, look, min(1, dt * (dizzy ? 40 : 11)))

        if clock > nextBlink { blink = 1; nextBlink = clock + Double.random(in: 2.4...6.5) }
        blink = max(0, blink - dt * 8)
        let yawning = tall > 0.4
        let open: CGFloat = blink > 0 ? abs(cos(blink * .pi)) : (yawning ? 0.4 : 1)
        var wantHeavy: CGFloat = 0
        if state == "reading" { wantHeavy = 0.2 }
        if state == "working" { wantHeavy = 0.14 }
        if oops { wantHeavy = 0.3 }
        if peekSide != 0 { wantHeavy = 0.28 }
        if armOut > 6 || clock < smirkUntil { wantHeavy = 0.36 }
        if puddle { wantHeavy = 0.42 }
        heavy += (wantHeavy - heavy) * min(1, dt * 12)
        lid += (open - lid) * min(1, dt * 22)
    }

    // MARK: drawing

    func L(_ p: V) -> CGPoint { CGPoint(x: p.x - screenRect.minX, y: screenRect.maxY - p.y) }

    func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawBody()
        for i in 0..<3 { strands[i].path = strandPath(i) }
        drawFace()
        drawBits()
        drawArms()
        fitLiquid()
        CATransaction.commit()
    }

    /// The filtered layers cover only what is on them, so the blur costs little however big the screen is.
    func fitLiquid() {
        var box = CGRect(origin: L(c), size: .zero).insetBy(dx: -radius * 2.6, dy: -radius * 2.6)
        for i in 0..<3 where reach[i] > 0.02 { box = box.union(CGRect(origin: L(anchor[i]), size: .zero)) }
        if armOut > 3 { box = box.union(CGRect(origin: L(armTip), size: .zero)) }
        box = box.insetBy(dx: -18, dy: -18)
        liquid.bounds = box
        liquid.position = CGPoint(x: box.midX, y: box.midY)
    }

    /// The skin, with any corners from collisions evened out before drawing.
    func smoothedSkin() -> [V] {
        let n = Goo.count
        var out = ring
        for _ in 0..<2 {
            let before = out
            for i in 0..<n {
                out[i] = (before[(i + n - 1) % n] * 0.25) + (before[i] * 0.5) + (before[(i + 1) % n] * 0.25)
            }
        }
        return out
    }

    func drawBody() {
        let path = CGMutablePath()
        let n = Goo.count
        let skin = smoothedSkin()
        path.move(to: L(skin[0]))
        for i in 0..<n {
            let p0 = skin[(i + n - 1) % n], p1 = skin[i], p2 = skin[(i + 1) % n], p3 = skin[(i + 2) % n]
            path.addCurve(to: L(p2), control1: L(p1 + (p2 - p0) * (1.0 / 6)), control2: L(p2 - (p3 - p1) * (1.0 / 6)))
        }
        path.closeSubpath()
        body.path = path
        outline.path = onDark ? path : nil

        // Light follows the actual skin: a wet streak up on the left, a faint bounce low on the right.
        func arc(from a: CGFloat, to b: CGFloat, inset: CGFloat) -> CGPath {
            let streak = CGMutablePath()
            let steps = 8
            for k in 0...steps {
                let index = Int((mix(a, b, CGFloat(k) / CGFloat(steps)) * CGFloat(n)).rounded()) % n
                let p = L(mix(c, skin[index], inset))
                if k == 0 { streak.move(to: p) } else { streak.addLine(to: p) }
            }
            return streak
        }
        gloss.lineWidth = max(1.3, radius * 0.09)
        gloss.path = arc(from: 0.56, to: 0.68, inset: 0.8)

        if mode == .free && settled {
            let w = radius * 1.25, floor = screenRect.maxY - surface
            ground.path = CGPath(ellipseIn: CGRect(x: c.x - screenRect.minX - w, y: floor - 2, width: w * 2, height: 4), transform: nil)
        } else { ground.path = nil }
    }

    func strandPath(_ i: Int) -> CGPath? {
        guard reach[i] > 0.02 else { return nil }
        let a = anchor[i]
        let d = (a - c).unit, n = d.normal
        let base = c + d * (radius * 0.55)
        let tip = mix(base, a, reach[i])
        let length = (tip - base).length
        // Stretching thins it, like anything with a fixed amount of goo in it.
        let neck = clamp(radius * 0.32 * (22 / max(22, length)), 1.7, radius * 0.32)
        let gripped = stuck[i] ? reach[i] : reach[i] * 0.3
        let foot = (i == 1 ? radius * 0.5 : radius * 0.32) * gripped + neck * 0.8
        let root = radius * (i == 1 ? 0.55 : 0.42)
        // A gripping foot lies flat along the window edge instead of across the strand.
        let side = n.y < 0 ? V(0, -1) : V(0, 1)
        let flat = mix(n, side, gripped).unit
        let sag = V(0, (1.5 + sin(CGFloat(clock) * 1.3 + CGFloat(i))) * min(1, length / 40))
        let mid = mix(base, tip, 0.5) + sag
        let back = d * -1
        let flare = neck + (foot - neck) * 0.12
        let reachBack = max(2, length * 0.3)
        let path = CGMutablePath()
        path.move(to: L(tip + flat * foot))
        path.addCurve(to: L(mid + n * neck), control1: L(tip + back * reachBack + flat * flare), control2: L(mid + d * (length * 0.14) + n * neck))
        path.addCurve(to: L(base + n * root), control1: L(mid + back * (length * 0.14) + n * neck), control2: L(base + d * (length * 0.2) + n * root))
        path.addLine(to: L(base - n * root))
        path.addCurve(to: L(mid - n * neck), control1: L(base + d * (length * 0.2) - n * root), control2: L(mid + back * (length * 0.14) - n * neck))
        path.addCurve(to: L(tip - flat * foot), control1: L(mid + d * (length * 0.14) - n * neck), control2: L(tip + back * reachBack - flat * flare))
        path.closeSubpath()
        return path
    }

    func ellipse(_ p: V, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        let q = L(p)
        return CGPath(ellipseIn: CGRect(x: q.x - rx, y: q.y - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    func drawFace() {
        let r = radius
        let wide = 1 + pop * 0.22 + (mode == .grabbed ? 0.12 : 0)
        let left = eye + V(-r * 0.33, -r * 0.02), right = eye + V(r * 0.33, r * 0.05)
        let lRX = r * 0.3 * wide, lRY = r * 0.37 * wide, rRX = r * 0.25 * wide, rRY = r * 0.32 * wide
        if happy && !dizzy {
            // pleased: eyes squeezed into two upward arcs
            let arc = { (p: V, w: CGFloat) -> CGPath in
                let q = CGMutablePath()
                q.move(to: self.L(p + V(-w, w * 0.2)))
                q.addQuadCurve(to: self.L(p + V(w, w * 0.2)), control: self.L(p + V(0, -w * 1.2)))
                q.addQuadCurve(to: self.L(p + V(-w, w * 0.2)), control: self.L(p + V(0, -w * 0.45)))
                q.closeSubpath()
                return q
            }
            eyeL.path = arc(left, lRX)
            eyeR.path = arc(right, rRX)
        } else if sleeping {
            // eyes shut: two soft downward curves
            let shut = { (p: V, w: CGFloat) -> CGPath in
                let q = CGMutablePath()
                q.move(to: self.L(p + V(-w, 0)))
                q.addQuadCurve(to: self.L(p + V(w, 0)), control: self.L(p + V(0, w * 0.7)))
                q.addQuadCurve(to: self.L(p + V(-w, 0)), control: self.L(p + V(0, w * 0.32)))
                q.closeSubpath()
                return q
            }
            eyeL.path = shut(left, lRX)
            eyeR.path = shut(right, rRX)
        } else {
            eyeL.path = ellipse(left, lRX, max(0.7, lRY * lid))
            eyeR.path = ellipse(right, rRX, max(0.7, rRY * lid))
        }
        let showing = lid > 0.3 && !sleeping && !dizzy && !happy
        let pL = left + gaze * (lRX * 0.43), pR = right + gaze * (rRX * 0.43)
        let prL = lRX * 0.5, prR = rRX * 0.5
        pupilL.path = showing ? ellipse(pL, prL, prL) : nil
        pupilR.path = showing ? ellipse(pR, prR, prR) : nil
        // a catch of light in each eye, so they look wet too
        sparkleL.path = showing ? ellipse(pL + V(-prL * 0.32, -prL * 0.36), prL * 0.27, prL * 0.27) : nil
        sparkleR.path = showing ? ellipse(pR + V(-prR * 0.32, -prR * 0.36), prR * 0.27, prR * 0.27) : nil

        // dizzy: the pupils become spirals, slowly turning
        if dizzy {
            let spin = CGMutablePath()
            for (p, size) in [(left, lRX), (right, rRX)] {
                var a: CGFloat = 0
                spin.move(to: L(p))
                while a < 14 {
                    a += 0.45
                    let radiusHere = a * size * 0.06
                    spin.addLine(to: L(p + V(cos(a + CGFloat(clock) * 5), sin(a + CGFloat(clock) * 5)) * radiusHere))
                }
            }
            swirl.lineWidth = max(0.9, r * 0.055)
            swirl.path = spin
        } else { swirl.path = nil }

        // heavy upper lids: what makes it look like it is up to something
        let lidShape = { (p: V, rx: CGFloat, ry: CGFloat) -> CGPath? in
            guard self.heavy > 0.03, !self.sleeping else { return nil }
            let top = p.y - ry - 1.5, bottom = p.y - ry + ry * 2 * self.heavy
            let q = CGMutablePath()
            q.move(to: self.L(V(p.x - rx - 1.5, top)))
            q.addLine(to: self.L(V(p.x + rx + 1.5, top)))
            q.addLine(to: self.L(V(p.x + rx + 1.5, bottom)))
            q.addQuadCurve(to: self.L(V(p.x - rx - 1.5, bottom)), control: self.L(V(p.x, bottom + r * 0.04)))
            q.closeSubpath()
            return q
        }
        lidL.path = lidShape(left, lRX, lRY)
        lidR.path = lidShape(right, rRX, rRY)

        // A small smile; surprised while dragged; the venom teeth when it has something to say.
        let m = eye + V(0, r * 0.5)
        let path = CGMutablePath()
        // Left resting on it for a moment, it starts nibbling the cursor.
        let chomp = hoverTime > 1 ? abs(sin(CGFloat(clock) * 11)) * 0.75 + 0.15 : pop
        if happy {
            // a wide open smile
            path.move(to: L(m + V(-r * 0.24, -r * 0.02)))
            path.addQuadCurve(to: L(m + V(r * 0.24, -r * 0.02)), control: L(m + V(0, r * 0.05)))
            path.addQuadCurve(to: L(m + V(-r * 0.24, -r * 0.02)), control: L(m + V(0, r * 0.36)))
            path.closeSubpath()
        } else if oops {
            // an awkward little frown
            path.move(to: L(m + V(-r * 0.15, r * 0.08)))
            path.addQuadCurve(to: L(m + V(r * 0.15, r * 0.08)), control: L(m + V(0, -r * 0.04)))
            path.addQuadCurve(to: L(m + V(-r * 0.15, r * 0.08)), control: L(m + V(0, r * 0.04)))
            path.closeSubpath()
        } else if guilty {
            // whistling innocently, off to one side
            path.addPath(ellipse(m + V(r * 0.2, r * 0.04), r * 0.07, r * 0.08))
        } else if (armOut > 6 || clock < smirkUntil) && chomp <= 0.14 {
            // the smirk
            path.move(to: L(m + V(-r * 0.2, r * 0.05)))
            path.addQuadCurve(to: L(m + V(r * 0.27, -r * 0.09)), control: L(m + V(r * 0.08, r * 0.1)))
            path.addQuadCurve(to: L(m + V(-r * 0.2, r * 0.05)), control: L(m + V(r * 0.08, r * 0.19)))
            path.closeSubpath()
        } else if puddle {
            path.addRect(CGRect(origin: L(m + V(-r * 0.16, r * 0.02)), size: CGSize(width: r * 0.32, height: 1.1)))
        } else if sleeping {
            path.addPath(ellipse(m + V(0, r * 0.05), r * 0.07, r * 0.07 * (1 + 0.5 * sin(CGFloat(clock) * 1.1))))
        } else if tall > 0.4 {
            path.addPath(ellipse(m + V(0, r * 0.08), r * 0.16, r * 0.24 * tall))
        } else if dizzy {
            path.move(to: L(m + V(-r * 0.24, 0)))
            for i in 1...4 {
                let up: CGFloat = i % 2 == 0 ? -1 : 1
                path.addQuadCurve(to: L(m + V(-r * 0.24 + r * 0.12 * CGFloat(i), 0)), control: L(m + V(-r * 0.3 + r * 0.12 * CGFloat(i), up * r * 0.1)))
            }
            for i in (0...3).reversed() {
                path.addLine(to: L(m + V(-r * 0.24 + r * 0.12 * CGFloat(i), r * 0.02)))
            }
            path.closeSubpath()
        } else if chomp > 0.14 {
            let w = r * (0.34 + chomp * 0.16), h = r * (0.06 + chomp * 0.3), teeth = 4
            let step = (w * 2) / CGFloat(teeth)
            path.move(to: L(m + V(-w, 0)))
            for i in 0..<teeth {
                path.addLine(to: L(m + V(-w + step * (CGFloat(i) + 0.5), -r * 0.07)))
                path.addLine(to: L(m + V(-w + step * (CGFloat(i) + 1), 0)))
            }
            path.addQuadCurve(to: L(m + V(-w, 0)), control: L(m + V(0, h * 2)))
            path.closeSubpath()
        } else if mode == .grabbed || (mode == .free && !settled) {
            let s = clamp(max(mouseSpeed.length, v.length) / 900, 0.09, 0.2) * r
            path.addPath(ellipse(m + V(0, r * 0.05), s * 0.85, s))
        } else {
            let w = r * (state == "thinking" ? 0.1 : 0.2), h = r * (state == "thinking" ? 0.02 : 0.13)
            path.move(to: L(m + V(-w, 0)))
            path.addQuadCurve(to: L(m + V(w, 0)), control: L(m + V(0, h)))
            path.addQuadCurve(to: L(m + V(-w, 0)), control: L(m + V(0, h + r * 0.08)))
            path.closeSubpath()
        }
        mouth.path = path
    }

    func drawBits() {
        let path = CGMutablePath()
        for d in drops {
            let stretch = 1 + min(1, d.v.length / 500)
            path.addPath(ellipse(d.p, d.r / stretch.squareRoot(), d.r * stretch.squareRoot()))
        }
        for s in stains {
            let r = s.r * min(1, s.life / 0.9)
            path.addPath(ellipse(s.p, r * 0.8, r * 1.5))
        }
        if state == "reading", mode == .attached, stuck[1] {
            let p = CGFloat(clock * 0.9).truncatingRemainder(dividingBy: 1)
            path.addPath(ellipse(mix(anchor[1], c, p), 1.2 + 2 * sin(p * .pi), 1.2 + 2 * sin(p * .pi)))
        }
        bits.path = path

        let letters = CGMutablePath()
        for z in zs {
            let s = 2 + (2.2 - z.life) * 1.1
            letters.move(to: L(z.p + V(-s, -s)))
            letters.addLine(to: L(z.p + V(s, -s)))
            letters.addLine(to: L(z.p + V(-s, s)))
            letters.addLine(to: L(z.p + V(s, s)))
        }
        zLayer.path = letters
    }
}

// MARK: - The app

final class Controller: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var url: URL!
    let backend = Backend()
    let updater = Updater()
    var lastApp: NSRunningApplication?  // the app in front before Tako was, which gets the keyboard back
    let selfTest: Bool
    var side: SideWindow!
    var web: WKWebView!
    var gooPanel: NSPanel!
    var gooView: GooView!
    var goo: Goo!
    var link: CADisplayLink?
    var loaded = false
    var region = NSRect.zero  // from the side window's top-left, reported by the page
    var dragging = false
    var target: (id: Int, frame: CGRect)?
    var platforms: [(id: Int, frame: CGRect, sticky: Bool)] = []  // every ordinary window, front to back
    var ticks = 0
    var moving = 0
    var sentGeometry = ""
    var wanted: CGFloat = 0
    var sideOpen = false
    var sideX: CGFloat = 0
    var pid: pid_t = 0
    var bundle = ""            // of the app it is stuck to
    var appName = ""
    var barHeight: CGFloat = 52
    var enchant: Enchant!
    var neverStuck = true, lostID: Int?, lostBundle = ""
    var cardWidth: CGFloat = 0
    var skinBusy = false, lastReported = ""
    var elements: [Element] = [], elementsWindow = 0
    var pointerHome: CGPoint?, pointerLeft: CGPoint?
    var operating = false, lastSummon: CFTimeInterval = 0
    var listener: Listener?
    var cardsShown = false, lastStep: CFTimeInterval = 0   // a card has to be clickable, even in the middle of a run
    let inkFlash = InkFlash()
    var hotKey: EventHotKeyRef?
    var isWeChat: Bool { bundle == weChatBundle }
    var trusted = false
    var homeX: CGFloat?, homeWidth: CGFloat = 0           // where the window was before we made room
    var expectedX: CGFloat = 0, expectedWidth: CGFloat = 0 // where we last put it; anything else means the owner moved it himself
    var ownMoveAt: CFTimeInterval = 0, resettle = false
    var fullHome: CGRect?      // the window's frame behind native full screen, while the panel has brought it out
    var glide: (from: CGFloat, to: CGFloat, step: Int)?
    var last: CFTimeInterval = 0
    var spill: CGFloat = 0
    var stopSource: DispatchSourceSignal?, collapseSource: DispatchSourceSignal?, reportSource: DispatchSourceSignal?
    var headerBusy = false, lastBand = 0, canCapture = false, captureAsked = false
    // self-test
    var testWindow: NSWindow?
    var fakeMouse: V?
    var frameTimes: [CFTimeInterval] = []

    init(selfTest: Bool) { self.selfTest = selfTest }

    func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    func mouse() -> V {
        if let fake = fakeMouse { return fake }
        let m = NSEvent.mouseLocation
        return V(m.x, (NSScreen.screens.first?.frame.maxY ?? 0) - m.y)
    }

    @objc func checkForUpdate() { updater.showOrCheck() }
    var statistics: Bool?   // nil where there is nothing to switch: a development build
    @objc func toggleStatistics() {
        let on = !(statistics ?? true)
        statistics = on
        web.evaluateJavaScript("setStatistics(\(on))")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        lastApp = NSWorkspace.shared.frontmostApplication
        updater.owner = self
        backend.onFail = { [weak self] reason in self?.giveUp(reason) }
        backend.onReady = { [weak self] address in
            guard let self else { return }
            let restarted = self.url != nil
            self.url = address
            if restarted { self.web.load(URLRequest(url: address)) } else { self.launch() }
        }
        backend.start(arguments: CommandLine.arguments.dropFirst().filter { $0 != "--selftest" })
    }

    func giveUp(_ reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tako 启动不了"
        alert.informativeText = reason
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// The Dock icon does what the shortcut does. Tako never keeps the keyboard from the app it sits on.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard goo != nil else { return false }
        lastApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.summon() }
        return false
    }

    func launch() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "goo")
        let start = NSRect(x: 0, y: 0, width: sidePanelWidth, height: 600)
        web = TakoWeb(frame: start, configuration: config)
        (web as? TakoWeb)?.owner = self
        web.registerForDraggedTypes([.fileURL])
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.load(URLRequest(url: url))

        side = SideWindow(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(side)
        side.contentView = web

        let screen = NSScreen.main ?? NSScreen.screens[0]
        gooPanel = SideWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(gooPanel)
        gooView = GooView(frame: NSRect(origin: .zero, size: screen.frame.size))
        gooView.owner = self
        gooView.autoresizingMask = [.width, .height]
        gooView.registerForDraggedTypes([.fileURL])
        gooPanel.contentView = gooView
        goo = Goo(host: self, view: gooView)
        enchant = Enchant(host: self)
        setScreen(screen)
        gooPanel.orderFront(nil)

        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("accessibility trusted=\(trusted)")
        // A hung app must not freeze the goo for the default 6 seconds per question.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        scan()
        startGoo()

        let link = gooView.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link

        // Being stopped must not strand the window where we moved it.
        signal(SIGTERM, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        stop.setEventHandler { [weak self] in self?.moveBackNow(); self?.backend.stop(); exit(0) }
        stop.resume()
        restoreMoved()
        updater.start()
        // A display unplugged or rearranged: never leave it on a screen that is gone.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let primary = NSScreen.screens.first?.frame else { return }
            let here = NSPoint(x: self.goo.c.x, y: primary.maxY - self.goo.c.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(here) }) ?? NSScreen.main { self.setScreen(screen) }
            self.placeSide()
        }
        stopSource = stop

        // SIGUSR1 collapses the side window, for scripted checks of the move back.
        signal(SIGUSR1, SIG_IGN)
        let collapse = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        collapse.setEventHandler { [weak self] in self?.closeSide() }
        collapse.resume()
        collapseSource = collapse

        // SIGUSR2 reports where it is, also for scripted checks.
        signal(SIGUSR2, SIG_IGN)
        let report = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        report.setEventHandler { [weak self] in
            guard let self else { return }
            self.log("at \(Int(self.goo.c.x)) \(Int(self.goo.c.y)) \(self.goo.mode) on \(self.bundle) key=\(self.side.isKeyWindow) responder=\(String(describing: self.side.firstResponder.map { type(of: $0) }))")
        }
        report.resume()
        reportSource = report

        // Switching apps reorders every window: catch up at once rather than on the next scan.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let other = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, other != NSRunningApplication.current { self?.lastApp = other }
            // The new app's windows come forward a moment after the notification.
            for delay in [0.0, 0.1, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan() } }
        }
        pollCommands()
        installHotKey()
        installMenus()
        if selfTest { runSelfTest() }
        // Opening an app puts it in front; Tako goes to the window it sits on, not in the way of it.
        if lastApp == nil || lastApp == NSRunningApplication.current {
            lastApp = openWindows().first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }  // By now macOS has already put Tako in front.
        }
        lastApp?.activate()
    }

    func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
    }

    func startGoo() {
        let pet = UserDefaults.standard.string(forKey: modeKey) == "pet"
        if pet || target == nil {
            goo.mode = .free
            goo.radius = 17; goo.radiusTarget = 17
            goo.place(at: V(goo.visible.maxX - 120, goo.visible.maxY - 300))
            setWatching(false)
        } else if let w = target?.frame {
            // drops in from above and grabs on
            goo.place(at: V(min(w.maxX + 40, goo.visible.maxX - 20), w.minY + 10))
            goo.stick(to: w.maxX)
        }
    }

    func setScreen(_ screen: NSScreen) {
        guard let primary = NSScreen.screens.first?.frame else { return }
        let f = screen.frame, vis = screen.visibleFrame
        goo.screenRect = CGRect(x: f.minX, y: primary.maxY - f.maxY, width: f.width, height: f.height)
        goo.visible = CGRect(x: vis.minX, y: primary.maxY - vis.maxY, width: vis.width, height: vis.height)
        gooPanel.setFrame(f, display: false)
        gooView.layer?.frame = CGRect(origin: .zero, size: f.size)
    }

    // MARK: every frame

    @objc func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 120 : min(0.05, now - last)
        last = now
        if selfTest { frameTimes.append(dt) }

        if targetRefreshDue() { refresh() }
        refreshStanding()
        ticks += 1
        if ticks % 30 == 0 { scan() }
        if ticks % 30 == 0 { readHeaderIfDue() }
        stepGlide()
        followScreen()

        spill = min(0.05, spill + CGFloat(dt))
        let fixed: CGFloat = 1.0 / 240
        while spill >= fixed { goo.step(fixed); spill -= fixed }
        goo.draw()
        enchant.step(CGFloat(dt))
        if ticks % 300 == 0 { sampleSkin() }
        // A run whose end never came (a restart, a lost reply) must not leave the panel unclickable.
        if operating, !cardsShown, ticks % 120 == 0, CACurrentMediaTime() - lastStep > 60 { log("run went quiet"); operating = false; goo.reachGoal = nil }
        // Settled, it doesn't need every frame the display can give; everything counted in ticks slows down with it.
        let wantedRate: Float = goo.mode == .grabbed || goo.mode == .free || moving > 0 || glide != nil ? 120 : 60
        if link.preferredFrameRateRange.preferred != wantedRate {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: wantedRate)
        }
        updateClickThrough()
        updateOrder()

        if ticks % 120 == 0 && !trusted {
            trusted = AXIsProcessTrusted()
            if trusted {
                log("accessibility trusted=true")
                web.evaluateJavaScript("setCanMove(true)")
                makeRoom(animated: true)
            }
        }
    }

    func targetRefreshDue() -> Bool {
        NSEvent.pressedMouseButtons != 0 || moving > 0 || ticks % 12 == 0 || goo.mode == .grabbed
    }

    func followScreen() {
        let point: V
        switch goo.mode {
        case .grabbed: point = mouse()  // the pointer leads: otherwise the screen's own bounds would stop it at the edge
        case .free: point = goo.c
        default: point = target.map { V($0.frame.maxX - 1, $0.frame.midY) } ?? goo.c
        }
        guard let primary = NSScreen.screens.first?.frame else { return }
        let ns = NSPoint(x: point.x, y: primary.maxY - point.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(ns) }), screen.frame != gooPanel.frame {
            setScreen(screen)
        }
    }

    func updateClickThrough() {
        let m = mouse()
        let onGoo = goo.mode == .grabbed || (m - goo.c).length < goo.radius + 7
        if gooPanel.ignoresMouseEvents == onGoo { gooPanel.ignoresMouseEvents = !onGoo }
        if sideOpen {
            let local = NSPoint(x: m.x - side.frame.minX, y: m.y - ((NSScreen.screens.first?.frame.maxY ?? 0) - side.frame.maxY))
            // While it is working a window the panel may lie over part of it: its own presses have to reach that window.
            let through = (operating && !cardsShown) || (!dragging && !region.contains(local))
            if side.ignoresMouseEvents != through { side.ignoresMouseEvents = through }
        }
    }

    /// Attached: just above WeChat, so other apps cover both. Free: above everything, a pet on the glass.
    func updateOrder() {
        let free = goo.mode == .free || goo.mode == .grabbed
        let level: NSWindow.Level = free ? .floating : .normal
        if gooPanel.level != level {
            gooPanel.level = level
            gooPanel.collectionBehavior = free ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
            if free { gooPanel.orderFront(nil) }
        }
    }

    func keepAbove(_ found: (id: Int, frame: CGRect), in ids: [Int]) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        var below = found.id
        if sideOpen {
            let s = ids.firstIndex(of: side.windowNumber), t = ids.firstIndex(of: found.id)
            // In use it may float up; once the owner has gone off to another app it goes back down with its window.
            let inUse = side.isKeyWindow && (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || side.frame.contains(NSEvent.mouseLocation))
            if !(s != nil && t != nil && s! + 1 == t!) && !inUse { side.order(.above, relativeTo: found.id) }
            below = side.windowNumber
        }
        guard goo.mode != .free && goo.mode != .grabbed else { return }
        // from the back: the window, the side window, its ink, the goo
        let ink = ids.firstIndex(of: enchant.panel.windowNumber), under = ids.firstIndex(of: below)
        if enchant.panel.isVisible && !(ink != nil && under != nil && ink! < under!) { enchant.panel.order(.above, relativeTo: below) }
        let top = enchant.panel.isVisible ? enchant.panel.windowNumber : below
        let g = ids.firstIndex(of: gooPanel.windowNumber), t = ids.firstIndex(of: top)
        if !(g != nil && t != nil && g! < t!) { gooPanel.order(.above, relativeTo: top) }
    }

    // MARK: the window it is on

    func refresh() {
        moving = max(0, moving - 1)
        guard let current = target else { return }
        if moving == 0 && resettle && NSEvent.pressedMouseButtons == 0 { resettle = false; shareScreen() }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(current.id)) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else {
            windowGone()
            return
        }
        if rect != current.frame {
            noteWindowMove(dx: rect.minX - current.frame.minX)
            target = (current.id, rect)
            noteAnswer(rect)
            moving = 20
            placeSide()
            enchant.sync()
        }
    }

    /// While it stands on a window, that window's position matters every frame the mouse is down.
    func refreshStanding() {
        guard let id = goo.standingID, NSEvent.pressedMouseButtons != 0 || ticks % 6 == 0,
              let index = platforms.firstIndex(where: { $0.id == id }),
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else { return }
        platforms[index].frame = rect
    }

    func windowGone() {
        let gone = target?.id
        lostID = gone
        lostBundle = bundle
        target = nil
        side.orderOut(nil)
        enchant.hide()
        guard goo.mode == .attached || goo.mode == .open else { return }
        // Off this Space or minimized, it waits with the window. Really closed, it has nothing to hold: it falls.
        let exists = { gone.flatMap { CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID($0)) as? [[String: Any]] }?.isEmpty == false }
        if exists() {
            gooPanel.orderOut(nil)
        } else {
            // A window changing Spaces (in or out of full screen) is missing from the list for a moment: only a window still gone is closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.target == nil, self.lostID == gone, self.goo.mode == .attached || self.goo.mode == .open, !exists() else { return }
                self.goo.tearOff(velocity: V(40, -180), reason: "window closed")
                self.gooPanel.orderFront(nil)
            }
        }
    }

    /// The window under it, for dropping it on: the frontmost one, on it or just off its right edge.
    func windowNear(_ c: V) -> (id: Int, frame: CGRect)? {
        for w in platforms where c.y > w.frame.minY - 8 && c.y < w.frame.maxY + 8 && c.x > w.frame.minX && c.x < w.frame.maxX + 70 {
            return w.sticky ? (w.id, w.frame) : nil
        }
        return nil
    }

    /// Stuck onto this window: it becomes the one it serves.
    func adopt(_ id: Int, contact: V?) {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first,
              let raw = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { return }
        let changed = (target?.id ?? lostID) != id
        // Moved the old window to make room: it goes back before the goo leaves it.
        if changed { moveBackNow(); homeX = nil; glide = nil }
        target = (id, rect)
        pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
        appName = info[kCGWindowOwnerName as String] as? String ?? ""
        bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? appName
        neverStuck = false
        if changed { lastBand = 0 }
        placeSide()
        reportStuck(title: info[kCGWindowName as String] as? String ?? "")
        sampleSkin()
        enchant.attach(contact: contact ?? V(rect.maxX, rect.minY + 66))
        log("stuck on \(bundle)")
    }

    /// Keeps track of every window; finds its way back to the one it was on when that one comes back.
    func scan() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let ordinary = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        platforms = ordinary.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  number != side.windowNumber, number != gooPanel.windowNumber, number != enchant.panel.windowNumber,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw),
                  rect.width > 200, rect.height > 80 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return (number, rect, !blockedOwners.contains(owner) && rect.width > 300 && rect.height > 200)
        }
        if let current = target {
            if let now = platforms.first(where: { $0.id == current.id }) {
                if now.frame != current.frame { target = (current.id, now.frame); noteAnswer(now.frame); placeSide(); enchant.sync() }
                keepAbove(target!, in: ordinary.compactMap { $0[kCGWindowNumber as String] as? Int })
            }
            return
        }
        // Nothing to hold yet: the window it lost if that is back, a window of the same app, or at first WeChat.
        var best: (id: Int, frame: CGRect)?
        var bestInfo: [String: Any]?
        for info in ordinary {
            guard let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), rect.width > 300, rect.height > 200,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int else { continue }
            if number == lostID { best = (number, rect); bestInfo = info; break }
            guard let app = NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier else { continue }
            guard app == (lostBundle.isEmpty ? weChatBundle : lostBundle) else { continue }
            if best == nil || rect.width * rect.height > best!.frame.width * best!.frame.height {
                best = (number, rect)
                bestInfo = info
            }
        }
        guard let found = best, let info = bestInfo else { return }
        target = found
        pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
        appName = info[kCGWindowOwnerName as String] as? String ?? ""
        bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? appName
        placeSide()
        if goo.mode != .free && goo.mode != .grabbed {
            gooPanel.orderFront(nil)
            reportStuck(title: info[kCGWindowName as String] as? String ?? "")
            sampleSkin()
            enchant.attach(contact: nil)
        }
    }

    /// Flush with the window's right edge and the same height. With too little screen to the
    /// right, the side window keeps its minimum width and overlaps the window by the difference.
    func placeSide() {
        guard let frame = target?.frame, let primary = NSScreen.screens.first,
              let visible = visibleFrame(of: frame) else { return }
        let room = visible.maxX - frame.maxX
        let x = room >= minimumWidth ? frame.maxX : visible.maxX - minimumWidth
        sideX = x
        let next = NSRect(x: x, y: primary.frame.maxY - frame.maxY, width: sidePanelWidth, height: frame.height)
        if next.size == side.frame.size {
            side.setFrameOrigin(next.origin)
        } else {
            side.setFrame(next, display: sideOpen)
        }
        let geometry = "\(frame.maxX - x),\(room)"
        if loaded && geometry != sentGeometry {
            sentGeometry = geometry
            web.evaluateJavaScript("setGeometry(\(geometry))")
        }
    }

    func visibleFrame(of frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let middle = NSPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        return (NSScreen.screens.first { $0.frame.contains(middle) } ?? primary).visibleFrame
    }

    // MARK: side window

    func toggleSide() { web.evaluateJavaScript("setOpen(\(!sideOpen))") }
    func closeSide() { if sideOpen { web.evaluateJavaScript("setOpen(false)") } }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let saved = UserDefaults.standard.double(forKey: widthKey)
        if saved > 0 { web.evaluateJavaScript("setWidth(\(saved))") }
        web.evaluateJavaScript("setCanMove(\(trusted))")
        web.evaluateJavaScript("setCanRead(\(CGPreflightScreenCaptureAccess()))")
        updater.panelLoaded()
        sentGeometry = ""
        placeSide()
        sampleSkin()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let rect = body["region"] as? [Double], rect.count == 4 {
            region = NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        if let value = body["dragging"] as? Bool { dragging = value }
        if let value = body["cards"] as? Bool { cardsShown = value }
        if let value = body["width"] as? Double { UserDefaults.standard.set(value, forKey: widthKey) }
        if let text = body["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let value = body["goo"] as? String { goo.state = value; enchant.setMood(value) }
        if body["done"] != nil { goo.celebrate() }
        if body["oops"] != nil { goo.fumble() }
        if let value = body["cardWidth"] as? Double { cardWidth = CGFloat(value); enchant.sync() }
        if let path = body["openFile"] as? String { openFile(path) }
        if body["pickFiles"] != nil { pickFiles() }
        if let action = body["update"] as? String { updater.act(action) }
        if let value = body["statistics"] as? Bool { statistics = value }
        if let path = body["revealFile"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        if let link = body["openURL"] as? String, let target = URL(string: link), ["http", "https"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
        if let value = body["pop"] as? Double { goo.pop = CGFloat(value); goo.kick(CGFloat(value) * 90) }
        if let value = body["wanted"] as? Double {
            wanted = value
            if sideOpen && dragging { makeRoom(animated: false) }
        }
        if let open = body["open"] as? Bool {
            sideOpen = open
            enchant.sync()
            if open {
                // It only speaks while stuck on, so an opening side window always has a window to sit on.
                if goo.mode == .attached { goo.mode = .open }
                side.ignoresMouseEvents = false
                side.makeKeyAndOrderFront(nil)
                if let id = target?.id { side.order(.above, relativeTo: id) }
                if enchant.panel.isVisible { enchant.panel.order(.above, relativeTo: side.windowNumber) }
                gooPanel.order(.above, relativeTo: enchant.panel.isVisible ? enchant.panel.windowNumber : side.windowNumber)
                makeRoom(animated: true)
                sampleSkin()
            } else {
                if goo.mode == .open { goo.mode = .attached }
                moveBack()
                side.ignoresMouseEvents = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, !self.sideOpen else { return }
                    self.side.orderOut(nil)
                }
            }
        }
    }

    // MARK: which conversation is open
    //
    // WeChat exposes nothing through Accessibility, so the only thing read is the top strip of its
    // window, on this Mac, and only the title in it leaves this function. The chat itself is never captured
    // unless the owner asks it to look.
    func readHeaderIfDue() {
        // Any other window: its title is all that changes, and the system already tells us that.
        if !isWeChat, (goo.mode == .attached || goo.mode == .open), let id = target?.id, ticks % 120 == 0,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first {
            reportStuck(title: info[kCGWindowName as String] as? String ?? "")
        }
        // The title only changes while WeChat is in use; but always read once right after sticking on.
        guard isWeChat, goo.mode == .attached || goo.mode == .open, !headerBusy, let current = target,
              lastBand == 0 || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        if !canCapture {
            canCapture = CGPreflightScreenCaptureAccess()
            if !canCapture {
                if !captureAsked {
                    captureAsked = true
                    log("screen capture trusted=false")
                    _ = CGRequestScreenCaptureAccess()
                    web.evaluateJavaScript("setCanRead(false)")
                }
                return
            }
            log("screen capture trusted=true")
            web.evaluateJavaScript("setCanRead(true)")
        }
        headerBusy = true
        let id = current.id, width = current.frame.width
        Task.detached { [weak self] in
            let titles = await Controller.headerTitles(windowID: id, width: width, previous: self?.lastBand ?? 0)
            await MainActor.run {
                guard let self else { return }
                self.headerBusy = false
                if let titles {
                    self.lastBand = titles.band
                    self.log("header changed, \(titles.lines.count) lines")
                    if !titles.lines.isEmpty { self.sendHeader(titles.lines) }
                }
            }
        }
    }

    static func headerTitles(windowID: Int, width: CGFloat, previous: Int) async -> (band: Int, lines: [String])? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: width, height: 62)
            config.width = Int(width * 2)
            config.height = 124
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard let bytes = image.dataProvider?.data as Data? else { return nil }
            // Data's own hash only looks at its first bytes, which never change here: hash all of it.
            let band = bytes.withUnsafeBytes { raw -> Int in
                var value: UInt64 = 14695981039346656037
                for byte in raw { value = (value ^ UInt64(byte)) &* 1099511628211 }
                return Int(truncatingIfNeeded: value)
            }
            if band == previous { return nil }   // nothing changed up there: no need to read it again

            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results ?? []).compactMap { o in
                o.topCandidates(1).first.map { (x: o.boundingBox.minX, right: o.boundingBox.maxX, text: $0.string) }
            }
            // Everything left of the end of the search box is the chat list, not the title.
            let listEnd = found.first(where: { $0.text.contains("搜索") })?.right ?? 0
            let lines = found.filter { $0.x > listEnd && !$0.text.contains("搜索") }
                .sorted { $0.text.count > $1.text.count }.map(\.text)
            return (band, lines)
        } catch {
            return nil
        }
    }

    func sendHeader(_ lines: [String]) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/current"
        guard let endpoint = parts.url, let body = try? JSONSerialization.data(withJSONObject: ["titles": lines]) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    func setWatching(_ on: Bool) {
        if !on { listener?.stop(); listener = nil }  // peeled off, it stops listening too; the server files what it heard
        if on { lastBand = 0 }   // stuck back on: read the title again straight away
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/watching"
        guard let endpoint = parts.url else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"on\":\(on)}".utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    func showMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let pet = goo.mode == .free || goo.mode == .grabbed
        let name = appName.isEmpty ? "窗口" : appName
        let toggle = NSMenuItem(title: pet ? "粘回\(name)" : "从\(name)上扒下来", action: #selector(toggleStick), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !pet || target != nil
        menu.addItem(toggle)
        let shortcut = NSMenuItem(title: "随时叫它：⌃⌥T", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())
        if let statistics {
            let item = NSMenuItem(title: "匿名统计", action: #selector(toggleStatistics), keyEquivalent: "")
            item.target = self
            item.state = statistics ? .on : .off
            menu.addItem(item)
        }
        let version = NSMenuItem(title: "Tako \(Updater.current)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let update = NSMenuItem(title: updater.menuTitle, action: #selector(checkForUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let quit = NSMenuItem(title: "退出 Tako", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func toggleStick() {
        if goo.mode == .free || goo.mode == .grabbed {
            if let edge = target?.frame.maxX { goo.stick(to: edge, window: target?.id) }
        } else {
            goo.tearOff(velocity: V(190, -240), reason: "menu")
        }
    }

    /// Shaking the window hard throws it off.
    func noteWindowMove(dx: CGFloat) {
        let now = CACurrentMediaTime()
        guard abs(dx) > 2, glide == nil else { return }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if sign != lastWindowSign {
            if lastWindowSign != 0 { windowShakes.append(now) }
            lastWindowSign = sign
        }
        windowShakes.removeAll { now - $0 > 1.1 }
        if windowShakes.count >= 4, goo.mode == .attached || goo.mode == .open {
            windowShakes.removeAll()
            goo.makeDizzy(2.6, "window shaken")
            goo.tearOff(velocity: V(sign * 260, -320), reason: "window shaken")
        }
    }
    var lastWindowSign: CGFloat = 0, windowShakes: [CFTimeInterval] = []

    @objc func quit() {
        moveBackNow()
        NSApp.terminate(nil)
    }

    // MARK: making room

    func axWindow(pid wanted: pid_t? = nil, frame given: CGRect? = nil) -> AXUIElement? {
        guard let frame = given ?? target?.frame else { return nil }
        let app = AXUIElementCreateApplication(wanted ?? pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var position: CFTypeRef?, extent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &extent) == .success else { continue }
            var origin = CGPoint.zero, dimension = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
            if abs(origin.x - frame.minX) < 2 && abs(origin.y - frame.minY) < 2 && abs(dimension.width - frame.width) < 2 {
                return window
            }
        }
        return nil
    }

    func setWindow(x: CGFloat, width: CGFloat? = nil) {
        guard let window = axWindow(), let frame = target?.frame else { return }
        var point = CGPoint(x: x, y: frame.minY)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if result != .success { log("move failed \(result.rawValue)") }
        if let width {
            var extent = CGSize(width: width, height: frame.height)
            if let value = AXValueCreate(.cgSize, &extent) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        }
        expectedX = x
        expectedWidth = width ?? frame.width
        ownMoveAt = CACurrentMediaTime()
        recordMoved()
        moving = 20
        refresh()
    }

    /// Right after we set a window it may settle somewhere else (its own minimum width, say): that is still our doing, not the owner's.
    func noteAnswer(_ rect: CGRect) {
        if CACurrentMediaTime() - ownMoveAt < 0.6 {
            expectedX = rect.minX
            expectedWidth = rect.width
            recordMoved()
        } else if NSEvent.pressedMouseButtons == 0 {
            resettle = true
        }
    }

    func stillWherePut(_ frame: CGRect) -> Bool { abs(frame.minX - expectedX) < 2 && abs(frame.width - expectedWidth) < 2 }

    /// The owner made the window fill the screen while the panel is open (the green button, a window manager).
    func shareScreen() {
        guard sideOpen, let frame = target?.frame, let visible = visibleFrame(of: frame),
              frame.width + min(wanted, sidePanelWidth) > visible.width + 1 else { return }
        // The owner has just asked for native full screen: don't pull it back out. The panel steps aside until they calls it.
        if let window = axWindow(), isFullScreen(window) { closeSide(); return }
        makeRoom(animated: false)
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success && value as? Bool == true
    }

    func axFrame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &extent) == .success else { return nil }
        var origin = CGPoint.zero, dimension = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
        return CGRect(origin: origin, size: dimension)
    }

    func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, dimension = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &dimension) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    /// Native full screen is a Space of its own: nothing can resize the window there or sit beside it. So the panel
    /// brings it out to fill the desktop with the panel, and closing the panel sends it back in.
    func leaveFullScreen(_ window: AXUIElement) {
        log("leaving full screen for the panel")
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        settleOut(of: window, last: nil, left: 40)
    }

    func settleOut(of window: AXUIElement, last: CGRect?, left: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let now = self.axFrame(window)
            if left > 0, self.isFullScreen(window) || now == nil || now != last {
                self.settleOut(of: window, last: now, left: left - 1)
                return
            }
            guard self.sideOpen else {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
                return
            }
            guard let now, !self.isFullScreen(window), let primary = NSScreen.screens.first?.frame, let visible = self.visibleFrame(of: now) else { return }
            self.fullHome = now
            self.homeX = visible.minX
            self.homeWidth = visible.width
            let shared = CGRect(x: visible.minX, y: primary.maxY - visible.maxY, width: visible.width - min(self.wanted, sidePanelWidth), height: visible.height)
            self.setFrame(window, shared)
            self.expectedX = shared.minX
            self.expectedWidth = shared.width
            self.ownMoveAt = CACurrentMediaTime()
            self.recordMoved()
            self.moving = 20
            self.refresh()
            self.side.makeKeyAndOrderFront(nil)
            self.scan()
            self.placeSide()
            self.enchant.sync()
        }
    }

    /// Back to where full screen had it: the frame it will return to when the owner leaves full screen himself, and then in.
    func returnToFullScreen(_ full: CGRect) {
        fullHome = nil
        homeX = nil
        guard let frame = target?.frame, stillWherePut(frame), let window = axWindow() else { recordMoved(); return }
        setFrame(window, full)
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        recordMoved()
    }

    /// Slides the window left, and if it fills the screen, narrows it too: the two share the screen rather than overlap.
    func makeRoom(animated: Bool) {
        guard sideOpen, trusted, let frame = target?.frame, let visible = visibleFrame(of: frame) else { return }
        if let window = axWindow(), isFullScreen(window) { leaveFullScreen(window); return }
        if homeX != nil && !stillWherePut(frame) { homeX = nil }
        let fromX = homeX ?? frame.minX, fromWidth = homeX == nil ? frame.width : homeWidth
        let lacking = min(wanted, sidePanelWidth) - (visible.maxX - (fromX + fromWidth))
        var x = fromX, width = fromWidth
        if lacking > 0 {
            x = min(fromX, max(visible.minX, fromX - lacking))
            let short = lacking - (fromX - x)
            if short > 0 { width = max(min(fromWidth, minimumSharedWidth), fromWidth - short) }
        }
        guard abs(x - frame.minX) >= 1 || abs(width - frame.width) >= 1 else { return }
        if homeX == nil { homeX = frame.minX; homeWidth = frame.width; log("making room: \(frame.minX),\(frame.width) to \(x),\(width)") }
        // Resizing can be slow in a heavy app, so only a slide is animated.
        if animated && abs(width - frame.width) < 1 {
            expectedX = frame.minX
            expectedWidth = frame.width
            glide = (frame.minX, x, 0)
        } else {
            glide = nil
            setWindow(x: x, width: width)
        }
    }

    func moveBack() {
        // The window is away (minimized, another Space): the debt stands until it is back.
        guard target != nil else { return }
        if let full = fullHome { returnToFullScreen(full); return }
        defer { homeX = nil; recordMoved() }
        guard let home = homeX, let frame = target?.frame else { return }
        // The owner moved it meanwhile: the new place is their, so leave it there.
        guard stillWherePut(frame) else { log("left where the owner put it"); return }
        log("moved back to \(home),\(homeWidth)")
        if abs(frame.width - homeWidth) >= 1 {
            glide = nil
            setWindow(x: home, width: homeWidth)
        } else {
            glide = (frame.minX, home, 0)
        }
    }

    func moveBackNow() {
        if let full = fullHome { returnToFullScreen(full); return }
        guard let home = homeX, let frame = target?.frame, stillWherePut(frame) else { return }
        glide = nil
        setWindow(x: home, width: homeWidth)
    }

    /// Written down each time a window is moved, so that even a crash can't strand it: the next start puts it back.
    var movedFile: URL { takoHome.appendingPathComponent("moved.json") }

    func recordMoved() {
        guard let home = homeX, let id = target?.id else { try? FileManager.default.removeItem(at: movedFile); return }
        var note: [String: Any] = ["id": id, "pid": Int(pid), "home": Double(fullHome?.minX ?? home), "homeWidth": Double(fullHome?.width ?? homeWidth), "expected": Double(expectedX), "expectedWidth": Double(expectedWidth)]
        if let full = fullHome { note["homeY"] = Double(full.minY); note["homeHeight"] = Double(full.height) }
        try? JSONSerialization.data(withJSONObject: note).write(to: movedFile)
    }

    func restoreMoved() {
        guard let data = try? Data(contentsOf: movedFile), let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = note["id"] as? Int, let owner = note["pid"] as? Int, let home = note["home"] as? Double, let expected = note["expected"] as? Double else { return }
        try? FileManager.default.removeItem(at: movedFile)
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first,
              (info[kCGWindowOwnerPID as String] as? Int) == owner, let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw), abs(rect.minX - expected) < 2,
              abs(rect.width - (note["expectedWidth"] as? Double ?? rect.width)) < 2,
              let window = axWindow(pid: pid_t(owner), frame: rect) else { return }
        setFrame(window, CGRect(x: home, y: note["homeY"] as? Double ?? rect.minY, width: note["homeWidth"] as? Double ?? rect.width, height: note["homeHeight"] as? Double ?? rect.height))
        log("moved a window back after an unclean exit")
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stop()
        guard goo != nil else { return }  // It never got as far as moving anything.
        moveBackNow()
        recordMoved()
    }

    /// The panel's page crashed: no message will ever come from it again, so the native side lets go by itself.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("panel page crashed")
        sideOpen = false
        cardsShown = false
        side.orderOut(nil)
        moveBack()
        webView.reload()
    }

    func stepGlide() {
        guard let current = glide else { return }
        let step = current.step + 1, steps = 18
        let t = 1 - pow(1 - CGFloat(step) / CGFloat(steps), 3)
        setWindow(x: current.from + (current.to - current.from) * t)
        glide = step >= steps ? nil : (current.from, current.to, step)
    }

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
            log("self-test done")
        }
    }
}
