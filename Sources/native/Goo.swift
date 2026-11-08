// Tako as a soft body: its state, moods, mischief and what the pointer does to it. It clings to any window it is
// dropped on, peels off into a desktop pet and sticks back on. Drawn with Core Animation, so nothing waits on a web page.
// Physics is in GooPhysics.swift, drawing in GooDrawing.swift.
import AppKit
import QuartzCore

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
/// Arrives a little past 1 and comes back: a thing that slides into place and settles.
func easeOutBack(_ t: CGFloat, overshoot: CGFloat = 1.5) -> CGFloat { 1 + (overshoot + 1) * pow(t - 1, 3) + overshoot * pow(t - 1, 2) }
func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, x)) }

enum Mode { case attached, open, grabbed, free }

final class GooView: NSView {
    weak var owner: Controller?
    override var acceptsFirstResponder: Bool { true }
    // Feed it a file: it swallows it and the side window opens with it attached.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard owner?.goo.mode == .attached || owner?.goo.mode == .open else { return [] }
        owner?.goo.pop = 1
        return .copy
    }
    // Entering while it was still landing on a window must not refuse the whole drag.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.goo.mode == .attached || owner?.goo.mode == .open ? .copy : []
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
    static let ink = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1).cgColor
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
    var radius: CGFloat = 15   // the same in every state: on a window, on the panel, on the floor (only the showcase draws it bigger)
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
    let eyeShadeL = CAShapeLayer(), eyeShadeR = CAShapeLayer(), shade = CAGradientLayer(), shadeMask = CAShapeLayer()
    // mischief
    let arms = CAShapeLayer(), inkLayer = CAShapeLayer(), outline = CAShapeLayer()
    let costume = Costume()
    // the scene it acts out while it works (Acts.swift) and its props
    var act = "", actBeat: CGFloat = 0, actLast = 0.0, mouthAt = V()
    let propInk = CAShapeLayer(), propLight = CAShapeLayer(), propLine = CAShapeLayer()
    var zoomUntil = 0.0, wiggle: CGFloat = 0, nextStep = 0.0, gait: CGFloat = 0, trot: CGFloat = 0
    var zooming: Bool { clock < zoomUntil }
    var armTip = V(), armOut: CGFloat = 0, armArrived = false, armTipV = V(), armThick: CGFloat = 1, armThickV: CGFloat = 0
    var armLeg = 3, armStrand = 2, armWanted = false  // it reaches with a limb it already has
    var heavy: CGFloat = 0  // how far the upper lids have come down
    var guiltyUntil = 0.0, smirkUntil = 0.0
    var ink: [(p: V, v: V, r: CGFloat, life: CGFloat)] = []
    var peekSide: CGFloat = 0, peekUntil = 0.0, ducking = false, lastNear = 0.0
    var puddle = false
    var pokes = 0
    // how high it stands above whatever is under it; a trotting corgi goes low, the whale girl sits on her short fat legs
    var stance: CGFloat { puddle ? 0.45 : 1.6 - trot * 0.3 - 0.08 * costume.dressed }
    var guilty: Bool { clock < guiltyUntil }
    var dizzy: Bool { clock < dizzyUntil }
    // bounds
    var visible = CGRect.zero, screenRect = CGRect.zero
    var candidate: CGFloat?  // right edge of a window we could stick to, if close enough
    var candidateID: Int?
    var latch: (from: V, start: Double)?  // just set down on an edge: where it touched, and when
    static let latchHold = 0.14, latchSlide = 0.46
    var reachGoal: V?        // somewhere the host wants it to put a limb: an input, a line of text
    // Something far away: the body goes over and puts out a short arm, rather than one long line across the screen.
    static let armReach: CGFloat = 170
    var perch: V?            // where it works from, measured from the window's top left, so it moves with the window
    var perchUntil = 0.0
    var hop: (from: V, start: Double, length: Double)?
    var leap: (id: Int, frame: CGRect, from: V, start: Double, length: Double)?  // over to another window the owner pressed to go to
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
        // a soft shadow where it sits, not a flat smear
        ground.fillColor = nil
        ground.shadowColor = NSColor.black.cgColor
        ground.shadowOpacity = 0.32
        ground.shadowOffset = .zero
        root.addSublayer(ground)
        let goo = Goo.ink
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
        // A faint light from the upper left, so it reads as a soft round thing and not a cut-out.
        shade.type = .radial
        shade.colors = [NSColor(white: 1, alpha: 0.14).cgColor, NSColor(white: 1, alpha: 0.04).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        shade.locations = [0, 0.45, 1]
        shade.startPoint = CGPoint(x: 0.34, y: 0.72)
        shade.endPoint = CGPoint(x: 1.12, y: 1.5)
        shade.mask = shadeMask
        root.addSublayer(shade)
        outline.fillColor = nil
        outline.strokeColor = NSColor(white: 1, alpha: 0.28).cgColor
        outline.lineWidth = 1
        root.addSublayer(outline)
        // black and white only: a wet highlight along the upper edge, thick in the middle and fading at both ends
        gloss.fillColor = NSColor(white: 1, alpha: 0.62).cgColor
        for layer in [eyeL, eyeR] { layer.fillColor = NSColor.white.cgColor }
        for layer in [eyeShadeL, eyeShadeR] { layer.fillColor = NSColor(white: 0.82, alpha: 1).cgColor }  // the lid's shadow in the eye
        for layer in [pupilL, pupilR] { layer.fillColor = goo }
        mouth.fillColor = NSColor.white.cgColor
        for layer in [sparkleL, sparkleR] { layer.fillColor = NSColor.white.cgColor }
        for layer in [lidL, lidR] { layer.fillColor = goo }
        swirl.fillColor = nil
        swirl.strokeColor = goo
        swirl.lineCap = .round
        for layer in [gloss, eyeL, eyeR, eyeShadeL, eyeShadeR, pupilL, pupilR, sparkleL, sparkleR, swirl, lidL, lidR, mouth] { root.addSublayer(layer) }
        costume.attach(behind: liquid, over: liquid)
        costume.onWear = { [unowned self] _ in self.showOff() }
        propInk.fillColor = goo
        propLight.fillColor = NSColor.white.cgColor
        propLine.fillColor = nil
        propLine.strokeColor = goo
        propLine.lineCap = .round
        propLine.lineJoin = .round
        for layer in [propLight, propLine, propInk] { root.addSublayer(layer) }
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
        let bob = trotting ? 0 : creep * (0.1 - 0.05 * costume.dressed) * sin(CGFloat(clock) * 7)   // the whale girl's big head bobs less
        let stretch = (1 + bob) / (1 + tall * 0.28) * (1 + trot * 0.13)
        var shape = V(d.x * radius * breathe * stretch, d.y * radius * breathe / stretch)
        if costume.isWhale {
            // her head is a little wider than it is tall; drawn through the smoothed skin it comes out the full radius across
            shape.x *= 1 + 0.025 * costume.dressed
            shape.y *= 1 - 0.052 * costume.dressed
            // gone down to think, swimming along, her manners; and the fish gag pulls and squashes her head, swings it at the
            // fish and fills her cheeks (Whale.swift)
            let k = costume
            shape = V(shape.x * k.stretch.x + k.lunge, shape.y * k.stretch.y + k.sink)
            if k.puff > 0.01 {
                for (cheek, side) in [(CGFloat(0.5), CGFloat(1)), (.pi - 0.5, -1)] {
                    var gap = atan2(d.y, d.x) - cheek
                    gap = atan2(sin(gap), cos(gap))
                    let full = k.puff * radius * 0.55 * (1 + 0.35 * k.wobble * (side == (facing > 0 ? 1 : -1) ? 1 : -0.5))
                    shape = shape + d * (full * exp(-(gap / 0.45) * (gap / 0.45)))
                }
            }
        }
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
        if wiggle > 0.01 {
            // a corgi with no tail wags the whole back end
            shape.x += sin(CGFloat(clock) * 19) * radius * 0.16 * wiggle * max(0, d.y)
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

    /// Just put something on: it shows it off, with a corgi's dash if it has the room, the whale girl's splash and spout, otherwise a happy hop.
    func showOff() {
        if costume.isWhale { dressUp() } else if costume.isCorgi && mode == .free && settled { startZoomies() } else { celebrate() }
    }

    /// Zoomies: a few fast runs to and fro along whatever it stands on.
    func startZoomies() {
        guard mode == .free, settled, !sleeping, !puddle, !dizzy else { return }
        zoomUntil = clock + 2.8
        happyUntil = zoomUntil   // eyes shut with joy, tongue out
        peekSide = 0
        let (lo, hi) = roamBounds()
        wanderTo = clamp(c.x + CGFloat.random(in: 110...170) * (c.x > (lo + hi) / 2 ? -1 : 1), lo, hi)
        pop = 0.5
        host.log("zoomies")
    }

    /// How far it can wander: the screen, or the top of the window it stands on.
    func roamBounds() -> (CGFloat, CGFloat) {
        var lo = visible.minX + 30, hi = visible.maxX - 30
        if let id = standingID, let w = host.platforms.first(where: { $0.id == id })?.frame {
            lo = max(lo, w.minX + radius + 4); hi = min(hi, w.maxX - radius - 4)
        }
        return (lo, hi)
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
        if hop != nil || latch != nil {
            goal = nil                          // limbs in while it is in the air, or sliding into its place
        } else if let asked = reachGoal {
            goal = asked                        // it has been asked to touch something over there
            armStrand = 1
            quick = 620
        } else if let hold = actHold() {
            goal = hold                         // holding the scene's prop: a magnifier, a quill
            armStrand = 2
            quick = 520
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
        } else if free && acting == nil && still > 2.5 && distance < 260 && distance > radius + 14 {
            goal = m                            // the cursor has gone quiet: go for it
            armStrand = 2
        }
        armWanted = goal != nil
        if goal != nil && armOut < 2 { armLeg = (goal!.x > c.x) ? 3 : 0 }
        let rest = armRest()
        // Moved while the arm is out: caught. It was never doing anything.
        if armOut > 12 && still < 0.05 && state == "idle" && reachGoal == nil && !guilty && acting == nil && latch == nil {
            guiltyUntil = clock + 1.9
            goal = nil
            armArrived = false
            host.log("caught reaching")
        }
        if let g = goal {
            // Out on a soft spring, never faster than the errand allows: it sneaks, it doesn't shoot.
            let to = g - armTip
            armTipV = armTipV + (to * 90 - armTipV * 13) * dt
            if armTipV.length > quick { armTipV = armTipV.unit * quick }
            if to.length <= 4 && !armArrived {
                armArrived = true
                if state == "idle" { pop = 0.5 }
                host.log("arm arrived")
            }
        } else {
            // Let go, it snaps home like elastic: a touch past, a wobble, and the body gives a little bounce.
            let back = rest - armTip
            let tucked = hop != nil || latch != nil  // moving fast: the limb stays with the body
            armTipV = armTipV + (back * (tucked ? 900 : 320) - armTipV * (tucked ? 50 : 15)) * dt
            armArrived = false
        }
        armTip = armTip + armTipV * dt
        // Home again it simply is its leg (or strand) once more, wherever that leg is stepping.
        if goal == nil && (armTip - rest).length < 8 && armTipV.length < 300 { armTip = rest; armTipV = V() }
        let wasOut = armOut
        armOut = (armTip - rest).length
        if goal == nil && wasOut > 10 && armOut <= 10 && armTipV.length > 120 { kick(min(armTipV.length * 0.06, 70)) }
        // Thinned while it moves fast, it fills out again when it stops, and the goo jiggles as it does.
        let thinGoal = 1 - clamp(armTipV.length / 1100, 0, 0.32)
        armThickV += ((thinGoal - armThick) * 280 - armThickV * 8) * dt
        armThick = clamp(armThick + armThickV * dt, 0.55, 1.35)

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
        if trotting { return trotLeg(k) }   // drawn stubbier in drawArms
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

    /// A corgi on the move, seen from the side: two legs at the front, two at the back, stepping in diagonal pairs,
    /// each foot lifted and swung forward, paws pointing the way it goes. The stride follows the ground it covers.
    var trotting: Bool { costume.isCorgi && mode == .free && wanderTo != nil && creep > 0.05 && !puddle && !sleeping && !dizzy }

    func trotLeg(_ k: Int) -> [V] {
        let r = radius, f = CGFloat(k) - 1.5, ahead: CGFloat = (wanderTo ?? c.x) >= c.x ? 1 : -1
        let s = f * ahead                                   // -1.5 … 1.5, back to front
        let front = s > 0, outer = abs(s) > 1
        let slot = (front ? 0.44 : -0.44) + (outer ? 0.08 : -0.08) * (front ? 1 : -1)
        let ground = surface - 0.6
        let phase = gait + ((front == outer) ? 0 : .pi)     // the diagonal pairs move together
        // short legs: small, quick steps that barely leave the ground
        let reach = r * 0.2 * creep, lift = r * 0.16 * creep
        let hip = V(c.x + ahead * slot * r * 0.82, c.y + r * 0.62)
        let foot = V(c.x + ahead * (slot * r - cos(phase) * reach), ground - r * 0.1 - max(0, sin(phase)) * lift)
        // front knees fold back, hind hocks forward
        let knee = mix(hip, foot, 0.5) + V(ahead * r * (front ? -0.07 : 0.07), 0)
        return [hip, knee, foot, foot + V(ahead * r * 0.2, r * 0.02), foot + V(ahead * r * 0.3, -r * 0.08)]
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
        var whaleReach: [V]? = nil   // the whale girl draws the reach as one of her tentacles (Whale.swift)
        var reaching: [V] = []   // the reaching leg's points, so it is kept from closing a pinhole with the others too
        // The limb that goes reaching: one of the legs, or one of the strands while it is stuck on.
        if out {
            let isLeg = mode == .free || mode == .grabbed
            let root = isLeg ? leg(armLeg)[0] : c + (armTip - c).unit * (r * 0.55)
            // A leg leaves along the ground first and only then rises, so it reads as that leg;
            // going straight up it would vanish behind the body and seem to sprout from its side.
            let side: CGFloat = armTip.x >= root.x ? 1 : -1
            let reachOut = clamp(armOut * 0.5, 0, r * 1.5)
            let elbow = isLeg ? V(root.x + side * reachOut, root.y + clamp(reachOut * 0.45, 0, r * 0.5)) : root
            // One soft limb from root to tip: a single curve (a leg bends out along the ground first, a strand sags
            // under its own weight) with the same ripple running its whole length, so no part of it is stiffer
            // than the rest.
            let chord = armTip - root, n = chord.unit.normal
            let sag = isLeg ? 0 : clamp(armOut * 0.3, 0, 32) * (n.y >= 0 ? 1 : -1)
            let bend = isLeg ? elbow + (elbow - mix(root, armTip, 0.5)) * 0.6 : mix(root, armTip, 0.5) + n * (sag * 2)
            var points: [V] = []
            let steps = 9
            for i in 0...steps {
                let s = CGFloat(i) / CGFloat(steps)
                let base = root * ((1 - s) * (1 - s)) + bend * (2 * s * (1 - s)) + armTip * (s * s)
                let tangent = ((bend - root) * (2 * (1 - s)) + (armTip - bend) * (2 * s)).unit
                let wave = sin(s * 6 - CGFloat(clock) * 5) * min(isLeg ? 5 : 3, armOut * 0.08) * sin(s * .pi)
                var p = base + tangent.normal * wave
                if armArrived && i == steps { p = p + V(0, sin(CGFloat(clock) * 14) * 2) }  // tap tap
                points.append(p)
            }
            reaching = points
            let limb = CGMutablePath()
            // The same goo however far it goes: the longer it is, the thinner it gets, never to a thread;
            // and it ends in a round pad, not a point.
            let slim = clamp((r * 1.6 / max(r * 1.6, armOut)).squareRoot(), 0.6, 1) * armThick
            let tip = points[points.count - 1]
            if isLeg {
                taper(points, r * 0.24, max(1.7, r * 0.13 * slim), max(1.5, r * 0.1 * slim), into: limb)
                limb.addPath(ellipse(tip, max(1.6, r * 0.13 * armThick), max(1.6, r * 0.13 * armThick)))
            } else {
                // Thick where it leaves the body, thin along the way, a small pad on the end.
                taper(points, r * 0.36, max(2, r * 0.17 * slim), max(1.6, r * 0.12 * slim), into: limb)
                limb.addPath(ellipse(tip, r * 0.19 * armThick, r * 0.19 * armThick))
            }
            if costume.isWhale && costume.dressed > 0.5 && !puddle { whaleReach = points } else { path.addPath(limb.normalized()) }
        }
        // Each limb is made whole on its own and then joined: two legs crossing with their outlines running
        // opposite ways would otherwise cancel where they overlap and leave pinholes.
        var joined: CGPath = path
        for layer in costume.tentacles { layer.path = nil }
        costume.armsLine.path = nil
        costume.hands.path = nil
        costume.handLight.path = nil
        if costume.isWhale && costume.dressed > 0.5 && !puddle {
            // the whale girl's short fat arms and legs, in every state, drawn like her behind the head (Whale.swift)
            whaleLimbs(reaching: out && (mode == .free || mode == .grabbed) ? armLeg : nil, reach: whaleReach)
        } else if hasLegs {
            // the web between the legs where they leave the body, so no chink of background shows between two of them
            // (not on the move: then front and hind legs stand apart)
            // (on the move only a little at the very top, so front and hind legs still stand apart)
            let web = trotting ? ellipse(c + V(0, r * 0.84), r * 0.38, r * 0.24) : ellipse(c + V(0, r * 0.88), r * 0.5, r * 0.32)
            joined = joined.isEmpty ? web : joined.union(web)
            // Wherever two legs come close enough for the goo's soft edge to run them together (walking, they pass
            // each other; hanging or dashing, they swing in), they are joined into one shape for the moment, so the
            // goo never closes round a pinhole of background between them. The soft edge is the same few points at
            // any size, so the reach is too.
            let touching = r * 0.28 + 5.2
            do {
                var legs = (0..<4).filter { !(out && $0 == armLeg) }.map { leg($0) }
                if reaching.count > 3 { legs.append([reaching[0], reaching[1], reaching[2]]) }
                for a in 0..<legs.count { for b in (a + 1)..<legs.count {
                    for joint in [1, 2] where (legs[a][joint] - legs[b][joint]).length < touching {
                        let bridge = CGMutablePath()
                        bridge.move(to: L(legs[a][joint]))
                        bridge.addLine(to: L(legs[b][joint]))
                        joined = joined.union(bridge.copy(strokingWithWidth: r * 0.24, lineCap: .round, lineJoin: .round, miterLimit: 1))
                    }
                } }
            }
            // and where a pair of neighbouring legs nearly meet lower down, close the pinhole they would leave
            if !trotting {
                for (a, b) in [(0, 1), (2, 3)] where !(out && (a == armLeg || b == armLeg)) {
                    let p = leg(a), q = leg(b)
                    joined = joined.union(ellipse((p[1] + q[1] + p[2] + q[2]) * 0.25, r * 0.17, r * 0.2))
                }
            }
            for k in 0..<4 where !(out && k == armLeg) {
                let limb = CGMutablePath()
                if trotting {
                    taper(leg(k), r * 0.26, max(1.9, r * 0.17), max(1.7, r * 0.14), into: limb)   // stubby corgi legs
                } else {
                    taper(leg(k), r * 0.22, max(1.7, r * 0.11), max(1.5, r * 0.085), into: limb)
                }
                joined = joined.isEmpty ? limb : joined.union(limb)
            }
        }
        arms.path = joined

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
        if hoverTime > 0.5 { pet() }

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
            if nextZ <= 0 && !costume.isWhale {   // the whale girl breathes out bubbles instead (Whale.swift)
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
            switch Int.random(in: 0..<(costume.isCorgi || costume.isWhale ? 9 : 7)) {
            case 7 where costume.isWhale, 8 where costume.isWhale: swishTail()   // the whale girl swishes her tail about
            case 7, 8: startZoomies()                       // a corgi's mad dash, back and forth
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
        zoomUntil = 0
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
            stick(to: edge, window: candidateID, latching: true)
        } else {
            mode = .free
            v = mouseSpeed * 0.75
        }
    }

    /// `latching`: set down by hand. The strands shoot out one after another, the side against the glass flattens, the ink spreads from where it touched, and then it slides to its place.
    func stick(to edge: CGFloat, window id: Int? = nil, latching: Bool = false) {
        mode = .attached
        let touched = V(edge, c.y)
        if let id { host.adopt(id, contact: touched) } else if let current = host.target?.id { host.adopt(current, contact: touched) }
        host.setWatching(true)
        for i in 0..<3 { stuck[i] = true; reach[i] = max(reach[i], 0.15); reachV[i] = latching ? 30 - CGFloat(i) * 7 : 16 }
        latch = latching && abs(c.x - edge) < 160 ? (c, clock) : nil
        if latching {
            v = V()
            squash(towards: V(edge > c.x ? 1 : -1, 0), 150)
        }
        pop = 0.7
        host.log("stuck to window")
        if !host.selfTest { UserDefaults.standard.set("attached", forKey: modeKey) }
    }

    func peelOff(reason: String) {
        // Tore completely free.
        mode = mode == .grabbed ? .grabbed : .free
        host.enchant.peel(at: c)
        host.setWatching(false)
        host.log("peeled off: \(reason)")
        if !host.selfTest { UserDefaults.standard.set("pet", forKey: modeKey) }
    }

    /// One side meets something: that side flattens and the rest bulges, then the skin springs back.
    func squash(towards side: V, _ strength: CGFloat) {
        for i in 0..<Goo.count {
            let facing = dir(i).x * side.x + dir(i).y * side.y
            ringV[i] = ringV[i] + side * (-strength * max(0, facing)) + dir(i) * (strength * 0.3 * (1 - abs(facing)))
        }
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
}
