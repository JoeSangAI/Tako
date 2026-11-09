// The DeepSeek whale girl (Wardrobe.swift says when she is worn): Tako wearing her, not a second body. The goo stays Tako's
// own in every state (stuck on a window, at the top left of the panel, held up, on the floor with its legs); she changes
// only what an outfit may change (Outfit.swift): the face (Tako's own eyes and looks, with pink blush strokes and, for the
// plain smile, a small open pink cat's mouth), a
// broader light on the head, two pieces pinned to the skin that squash and swing with it (the lace apron with the little
// blue whale, the black tail with its forked fluke, which lags and wags), and water that comes and goes with what Tako is
// doing: a spout when a job is done (a rainbow in it after a long one), bubbles while it thinks and asleep, sputters when
// stuck, drips when held up, a splash when it lands. Writing an answer, the limb it reaches with holds her order pad.
// The pieces are pictures in the drawing's style (Sources/art). Plain Tako is untouched: all of this only while she is worn.
import AppKit
import QuartzCore

extension Goo {
    // where the cut pieces sit in the drawing, in head radii from the middle of the head
    static let apronBox = CGRect(x: -0.7161, y: 0.5742, width: 1.4673, height: 0.8612)
    // on the skin: where the tail grows out, low on her back (angle round the middle, 0 right, a quarter turn down); the
    // apron's middle on her front, in head radii, a little smaller than in the drawing, where she had a body under the head
    static let tailAngle: CGFloat = 0.5, tailScale: CGFloat = 1.1, tailFat: CGFloat = 1.25   // a little plumper than drawn
    static let tailBox = CGRect(x: 0.6874, y: 0.0638, width: 0.9888, height: 0.9888), tailPivot = V(1.0064, 0.8612)
    static let apronAt = V(0.0175, 0.88), apronScale: CGFloat = 0.74   // low enough to leave Tako's mouth clear
    static let spoutBox = CGRect(x: -0.8756, y: -2.0096, width: 1.8820, height: 1.1069), spoutBase = V(0.0175, -0.9027)
    static let headTall: CGFloat = 0.925   // her head's height to its width

    // MARK: her habits

    /// Put on just now: a splash round her feet, the apron pops on, the tail springs out, one spout and a happy wiggle.
    func dressUp() {
        let k = costume
        k.dressAt = clock
        k.drops = []
        k.splashes = []
        kick(70)
        splash(at: underfoot(), width: 2.6, count: 6)
    }

    /// Water from the top of the head. `power` 1 is a big happy spout.
    func spout(_ power: CGFloat) {
        let k = costume
        if spoutHeight() > 0.3 && k.spoutPower >= power { return }
        k.spoutAt = clock
        k.spoutPower = power
    }

    /// The tail goes up and swishes about for a moment, for no reason at all.
    func swishTail() {
        guard costume.isWhale, !sleeping, mode != .grabbed else { return }
        costume.swishAt = clock
    }

    /// Where a splash goes: round its feet on the ground, under it anywhere else.
    func underfoot() -> V { mode == .free && settled ? V(c.x, surface - 1) : c + V(0, 1.4 * radius) }

    /// A splash crown rising where she hits the water (`width` in head radii), drops thrown up out of it to both sides.
    func splash(at p: V, width: CGFloat, count: Int) {
        let k = costume, r = radius
        k.splashes.append((p, clock, width * r))
        for i in 0..<count {
            let s: CGFloat = i % 2 == 0 ? -1 : 1
            let at = p + V(s * r * CGFloat.random(in: 0.3...0.5) * width, -r * 0.2)
            k.drops.append((at, V(s * r * CGFloat.random(in: 0.6...1.6), -r * CGFloat.random(in: 3.2...5.5)), r * CGFloat.random(in: 0.1...0.14), 1.2))
        }
    }

    /// How tall the spout stands, 0…1 (a little over 1 as it shoots up): up fast, a moment at its height, then it sinks back.
    func spoutHeight() -> CGFloat {
        let k = costume, u = CGFloat(clock - k.spoutAt), length = 0.9 + 0.7 * k.spoutPower
        guard u >= 0, u < length else { return 0 }
        if u < 0.24 { return easeOutBack(u / 0.24, overshoot: 1.8) }
        let fall = clamp((length - u) / 0.35, 0, 1)
        return fall * fall * (3 - 2 * fall)
    }

    /// A point on the skin at an angle round the centre (0 to the right, a quarter turn down), between the ring's samples.
    func rim(_ ring: [V], _ angle: CGFloat) -> V {
        let n = CGFloat(Goo.count)
        var x = (angle / (2 * .pi) * n).truncatingRemainder(dividingBy: n)
        if x < 0 { x += n }
        let i = Int(x), f = x - CGFloat(i)
        return mix(ring[i % Goo.count], ring[(i + 1) % Goo.count], f)
    }

    /// 0 until `at` seconds into putting her on, then a springy 0 → 1 (a little past it and back): a part popping on.
    func popIn(_ since: CGFloat, _ at: CGFloat) -> CGFloat {
        guard since > at else { return 0 }
        let u = (since - at) / 0.4
        return u >= 1 ? 1 : easeOutBack(u, overshoot: 2.6)
    }

    // MARK: her shape

    /// The head as the skin has it this frame: its middle, and how far it is squashed across and down from her round head.
    /// The little bulge it puts out toward the cursor is left out: what she wears stays where it is while her head leans.
    func whaleForm(_ skin: [V]) {
        let k = costume
        var lo = V(.infinity, .infinity), hi = V(-.infinity, -.infinity)
        for (i, point) in skin.enumerated() {
            let d = dir(i), toward = max(0, d.x * leanDir.x + d.y * leanDir.y)
            let p = point - d * (toward * toward * toward * lean * radius)
            lo = V(min(lo.x, p.x), min(lo.y, p.y))
            hi = V(max(hi.x, p.x), max(hi.y, p.y))
        }
        k.mid = mix(lo, hi, 0.5)
        k.sx = (hi.x - lo.x) / (2 * radius)
        k.sy = (hi.y - lo.y) / (2 * radius * Goo.headTall)
    }

    /// A point on her, in head radii from the middle of the head, squashed with it.
    func onHead(_ x: CGFloat, _ y: CGFloat) -> V {
        let k = costume
        return k.mid + V(x * radius * k.sx, y * radius * k.sy)
    }

    /// Her mouth, in place of Tako's plain smile (every other look stays Tako's own): a small pink opening hanging from a
    /// little cat's lip, the tongue lighter at the bottom, wider when she is pleased; narrower as the head turns.
    func whaleMouth(at m: V, wide: Bool) {
        let k = costume, r = radius, s: CGFloat = wide ? 1.05 : 0.85
        let q = (m - c) * (1 / r), squeeze = turned(q.x, q.y).squeeze
        func M(_ x: CGFloat, _ y: CGFloat) -> V { m + V(x * r * s * squeeze, (y - 0.1) * r * s) }
        let opening = CGMutablePath()
        opening.move(to: L(M(-0.105, 0.083)))
        opening.addQuadCurve(to: L(M(0, 0.062)), control: L(M(-0.05, 0.092)))
        opening.addQuadCurve(to: L(M(0.105, 0.083)), control: L(M(0.05, 0.092)))
        opening.addCurve(to: L(M(0, 0.215)), control1: L(M(0.115, 0.15)), control2: L(M(0.07, 0.215)))
        opening.addCurve(to: L(M(-0.105, 0.083)), control1: L(M(-0.07, 0.215)), control2: L(M(-0.115, 0.15)))
        opening.closeSubpath()
        k.mouthIn.path = opening
        k.mouthTongue.path = opening.intersection(ellipse(M(0, 0.255), 0.12 * r * s * squeeze, 0.105 * r * s))
        let lip = CGMutablePath()
        lip.move(to: L(M(-0.13, 0.062)))
        lip.addQuadCurve(to: L(M(0, 0.055)), control: L(M(-0.07, 0.11)))
        lip.addQuadCurve(to: L(M(0.13, 0.062)), control: L(M(0.07, 0.11)))
        k.lip.lineWidth = max(0.5, r * 0.022)
        k.lip.path = lip
    }

    // MARK: drawing

    /// One of her pictures on the screen this frame, from the costume's pool of picture layers: in front of everything, or
    /// (`held`) a thing in her hands, under the hands. `turn` is counter-clockwise; `anchor` is the point of the picture put at `p`.
    func sprite(_ name: String, _ p: V, width: CGFloat, turn: CGFloat = 0, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
                opacity: CGFloat = 1, flip: Bool = false, squash: CGFloat = 1, held: Bool = false) {
        let k = costume, pool = held ? k.props : k.sprites
        let index = held ? k.propsUsed : k.spritesUsed
        guard width > 0.8, opacity > 0.02, index < pool.count else { return }
        if held { k.propsUsed += 1 } else { k.spritesUsed += 1 }
        let layer = pool[index], scale = view.window?.backingScaleFactor ?? 2
        k.dress(layer, name, points: (width * scale / 6).rounded(.up) * 6 / scale, scale: scale)   // a few sizes made, not one a frame
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: width * Costume.aspect(name))
        layer.anchorPoint = anchor
        layer.position = L(p)
        layer.transform = CATransform3DScale(CATransform3DMakeRotation(turn, 0, 0, 1), flip ? -1 : 1, squash, 1)
        layer.opacity = Float(min(1, opacity))
        layer.isHidden = false
    }

    func drawWhale(_ skin: CGPath, _ dt: CGFloat) {
        let k = costume, r = radius, ring = smoothedSkin(), scale = view.window?.backingScaleFactor ?? 2
        for layer in [k.ears, k.earsInner, k.hoodMask, k.furMask, k.tongue, k.tongueLine, k.cover, k.fold, k.stitch] { layer.path = nil }
        k.spritesUsed = 0
        k.propsUsed = 0
        defer {
            for layer in k.sprites[k.spritesUsed...] { layer.isHidden = true }
            for layer in k.props[k.propsUsed...] { layer.isHidden = true }
        }
        let since = CGFloat(clock - k.dressAt)
        // putting her on: the splash hides the change, then the apron pops on, the tail springs out, a spout, a wiggle
        k.dressed = clamp((since - 0.1) / 0.22, 0, 1)
        let apronIn = popIn(since, 0.35), tailIn = popIn(since, 0.7)
        func passes(_ at: CGFloat) -> Bool { since >= at && since - dt < at }
        if passes(0.35) || passes(0.7) { kick(32) }   // a little jolt as each part pops on
        if passes(1.15) { spout(1); kick(40) }
        if passes(1.6) { celebrate() }
        if k.dressed > 0.5 { seaLife(dt) }
        let petted = clock - k.pettedAt < 1.2

        // what her moods ask of the tail: how high it is held, how hard and how fast it wags. Pleased, it goes right up.
        let scared = guilty || !ink.isEmpty
        let moving = mode == .free && wanderTo != nil && creep > 0.3
        var lift: CGFloat = 0, wagAmount: CGFloat = 0.08, wagSpeed: CGFloat = 2.4
        if sleeping { lift = -0.45; wagAmount = 0.03; wagSpeed = 1 }
        else if scared { lift = -0.7; wagAmount = 0.05; wagSpeed = 20 }                // tucked away, trembling
        else if mode == .grabbed { lift = -0.5; wagAmount = 0.25; wagSpeed = 9 }      // dangling, wriggling
        else if dizzy { lift = -0.2; wagAmount = 0.3; wagSpeed = 5 }
        else if petted { lift = 0.25; wagAmount = 0.3; wagSpeed = 18 }                // stroked: a delighted flutter
        else if happy { lift = 0.2; wagAmount = 0.12; wagSpeed = 12 }                // up as in the drawing, wagging
        else if oops { lift = -0.45; wagAmount = 0.04; wagSpeed = 2 }
        else if pop > 0.3 { lift = 0.35; wagAmount = 0.1; wagSpeed = 3 }
        else if let a = acting {
            switch a {
            case "think": lift = 0.15; wagAmount = 0.12; wagSpeed = 1.4                  // curling slowly
            case "look", "read": lift = 0.3; wagAmount = 0.04; wagSpeed = 3              // held still, attentive
            case "search": lift = 0.25; wagAmount = 0.12; wagSpeed = 5                   // curious
            case "run": lift = 0.15; wagAmount = 0.16; wagSpeed = 9                      // busy
            case "answer", "write", "file": lift = 0.15; wagAmount = 0.12; wagSpeed = 3
            case "listen": lift = 0.2; wagAmount = 0.2; wagSpeed = 6.8                   // tapping to the beat
            case "wait": lift = 0.2; wagAmount = 0.06; wagSpeed = 2                      // waiting politely
            case "trouble": lift = -0.5; wagAmount = 0.04; wagSpeed = 1.5                // drooping
            default: break
            }
        } else if moving { lift = 0.1; wagAmount = 0.3; wagSpeed = 4.5 }                // a slow rudder as she swims along
        if clock - k.swishAt < 1.4 { lift = 0.3; wagAmount = 0.3; wagSpeed = 10 }
        // and it lags behind the body: a sudden move swings it the other way, and it settles after
        let drag = clamp(-(v.x - k.lastV.x) / max(dt, 0.001) / 9000, -0.35, 0.35) + clamp(v.y / 1400, -0.25, 0.25)
        k.spring(&k.tailLift, &k.tailLiftV, to: lift + drag, k: 200, damping: 12, dt)
        k.wag += (wagAmount - k.wag) * min(1, dt * 6)
        k.wagPhase += wagSpeed * dt

        // The tail, the drawing's own (the one in the film), pinned to the skin low on her back with its root tucked in behind
        // it; mood lifts and wags it. Seen from the front it is behind her and out of sight (Joe 2026-11-08); it comes round
        // into view as she turns side on, holding on to a window's edge.
        let side = clamp(abs(turn) / Goo.sideTurn, 0, 1) * tailIn
        if side > 0.02 && !puddle {
            let box = Goo.tailBox, pivot = c + (rim(ring, Goo.tailAngle) - c) * 0.92
            k.dress(k.tailArt, "tail", points: box.width * r, scale: scale)
            k.tailArt.bounds = CGRect(x: 0, y: 0, width: box.width * r, height: box.height * r)
            k.tailArt.anchorPoint = CGPoint(x: (Goo.tailPivot.x - box.minX) / box.width, y: 1 - (Goo.tailPivot.y - box.minY) / box.height)
            k.tailArt.position = L(pivot)
            let swing = min(0.1, clamp(k.tailLift, -1, 1) * 0.42 - 0.04 + k.wag * sin(k.wagPhase) * 0.7)
            k.tailArt.transform = CATransform3DScale(CATransform3DMakeRotation(swing, 0, 0, 1), side * Goo.tailScale * Goo.tailFat, side * Goo.tailScale, 1)
            k.tailArt.isHidden = false
        } else { k.tailArt.isHidden = true }
        k.tailArt.shadowOpacity = onDark ? 0.45 : 0

        // The apron, the drawing's own, on her front like a bib on the skin: squashed with the body and tipped with the
        // face; it pops on from its middle.
        if apronIn > 0.02 && !puddle {
            let box = Goo.apronBox
            k.dress(k.apronArt, "apron", points: box.width * r, scale: scale)
            k.apronArt.bounds = CGRect(x: 0, y: 0, width: box.width * r, height: box.height * r)
            let round = turned(Goo.apronAt.x, Goo.apronAt.y * Goo.headTall)   // turned side on, it comes round with her front
            k.apronArt.position = L(onHead(round.x, Goo.apronAt.y))
            let tip = CATransform3DMakeRotation(-(actTilt() + k.swim) * 0.4, 0, 0, 1)
            k.apronArt.transform = CATransform3DScale(tip, k.sx * apronIn * Goo.apronScale * round.squeeze, k.sy * apronIn * Goo.apronScale, 1)
            k.apronArt.isHidden = false
        } else { k.apronArt.isHidden = true }

        // blush: two short pink strokes on each cheek with a soft glow, under Tako's own eyes; deeper when stroked
        let cheeks = CGMutablePath(), glow = CGMutablePath(), b: CGFloat = petted ? 1 : happy ? 0.4 : 0
        if k.dressed > 0.5 && !dizzy {
            let tilt = actTilt() + k.swim, middle = k.mid + slosh * 0.6 + V(0.08 * r * k.sx, 0.05 * r)
            func F(_ x: CGFloat, _ y: CGFloat) -> V { middle + rotate(V(turned(x, y * Goo.headTall).x * r * k.sx, y * r * k.sy), tilt) }
            for side in [CGFloat(-1), 1] {
                for x in [CGFloat(0.553), 0.684] {
                    let p = F(side * x, 0.137), stroke = CGMutablePath()
                    stroke.move(to: L(p + rotate(V(-0.03 * r, 0.035 * r), tilt)))
                    stroke.addLine(to: L(p + rotate(V(0.03 * r, -0.035 * r), tilt)))
                    cheeks.addPath(stroke.copy(strokingWithWidth: max(0.9, r * 0.062 * (1 + 0.25 * b)), lineCap: .round, lineJoin: .round, miterLimit: 1))
                }
                glow.addPath(ellipse(F(side * 0.62, 0.137), r * (0.17 + 0.06 * b) * k.sx * turned(side * 0.62, 0.127).squeeze, r * (0.1 + 0.04 * b) * k.sy))
            }
        }
        k.blush.shadowRadius = max(1, r * 0.05)
        k.blush.fillColor = NSColor(srgbRed: 0.95 + 0.03 * b, green: 0.6 - 0.2 * b, blue: 0.59 - 0.12 * b, alpha: 1).cgColor
        k.trim.fillColor = NSColor(srgbRed: 0.97, green: 0.45, blue: 0.5, alpha: 0.05 + 0.3 * b).cgColor
        k.blush.path = cheeks.isEmpty ? nil : cheeks
        k.trim.path = glow.isEmpty ? nil : glow

        // what sets the water going: a job done (a long job brings a rainbow in the spout). Stroked, she does not blow.
        if happy && !k.wasHappy && !petted {
            spout(1)
            let ran = k.busySince.map { clock - $0 } ?? (clock - k.busyEndedAt < 5 ? k.busyLength : 0)
            if ran > Goo.longJob { k.rainbowAt = clock }
        }
        k.wasHappy = happy

        // The spout, the drawing's own: out of the top of the head, shooting up narrow and opening out, swaying a little
        // while it stands, then sinking back into the head.
        let height = spoutHeight()
        if height > 0.01 && !puddle {
            let box = Goo.spoutBox, base = rim(ring, 1.5 * .pi) + V(Goo.spoutBase.x * r * k.sx, (Goo.headTall + Goo.spoutBase.y) * r)
            let power = 0.55 + 0.45 * k.spoutPower, t = CGFloat(clock)
            k.dress(k.spoutArt, "spout", points: box.width * r, scale: scale)
            k.spoutArt.bounds = CGRect(x: 0, y: 0, width: box.width * r, height: box.height * r)
            k.spoutArt.anchorPoint = CGPoint(x: (Goo.spoutBase.x - box.minX) / box.width, y: 0)
            k.spoutArt.position = L(base)
            let across = (0.5 + 0.5 * min(1, height)) * (1 + 0.04 * sin(t * 16 + 1)) * power
            let up = height * (1 + 0.035 * sin(t * 13)) * power
            k.spoutArt.transform = CATransform3DScale(CATransform3DMakeRotation(0.035 * sin(t * 7), 0, 0, 1), across, up, 1)
            k.spoutArt.opacity = Float(min(1, height * 2.5))
            k.spoutArt.isHidden = false
            // and in a long job's spout, a little rainbow standing in the water
            let bow = clock - k.rainbowAt < 2.4 ? min(1, height) * clamp(CGFloat(clock - k.rainbowAt - 0.15) / 0.3, 0, 1) : 0
            if bow > 0.02 {
                sprite("rainbow", base + V(0, -0.3 * r * up), width: 1.5 * r * across, anchor: CGPoint(x: 0.5, y: 0.15), opacity: bow, squash: 0.6 + 0.4 * bow)
            }
        } else { k.spoutArt.isHidden = true }

        // writing an answer: her order pad, held up by the limb Tako reaches out with, the tip writing on it
        if let a = acting, ["answer", "write", "file"].contains(a), let hold = armOut > 3 ? armTip : actHold() {
            sprite("pad", hold + V(facing * 0.22 * r, 0.12 * r), width: 0.8 * r, turn: -0.12 * facing, held: true)
        }

        drawSea(arms.path.map { skin.union($0) } ?? skin, dt)
    }

    // MARK: her sea

    /// The scenes she plays her own way instead of with Tako's props (Acts.swift skips its own for these): bubbles for the
    /// thought bubbles, a sputtering spout for the bead of sweat, her order pad for the quill.
    static let whaleActs: Set<String> = ["think", "trouble", "answer", "write", "file"]
    /// A job this long (seconds) ends in a spout with a rainbow in it.
    static let longJob = 60.0

    /// Coming down from a height: a splash crown round her feet, as big as the fall.
    func landsInWater(_ hit: CGFloat) {
        guard costume.dressed > 0.5, hit > 450 else { return }
        splash(at: V(c.x, surface - 1), width: 2.2 + min(1.2, (hit - 450) / 800), count: 4 + min(4, Int((hit - 450) / 200)))
    }

    /// Every frame she is dressed: how long the job has been running, the sway she swims along with, and the bubbles, drops
    /// and hearts her state gives off.
    func seaLife(_ dt: CGFloat) {
        let k = costume, r = radius, scene = acting ?? ""
        // the job's length, for the rainbow at its end
        if !act.isEmpty, k.busySince == nil { k.busySince = clock }
        if act.isEmpty, let since = k.busySince { k.busyLength = clock - since; k.busyEndedAt = clock; k.busySince = nil }
        // done thinking: she blows
        if k.lastAct == "think" && scene != "think" && !sleeping { spout(0.6); kick(45) }
        k.lastAct = scene
        // a heart when she is stroked
        let petted = clock - k.pettedAt < 0.4
        if petted && !k.wasShy { k.hearts.append((onHead(0.95, -0.45), clock)) }
        k.wasShy = petted
        // swimming along she sways a little
        let moving = mode == .free && wanderTo != nil && creep > 0.3
        k.swim += ((moving ? 0.07 * sin(t * 2.5) : 0) - k.swim) * min(1, dt * 4)
        let top = rim(smoothedSkin(), 1.5 * .pi)   // the blowhole
        if clock > k.nextBubble {
            if scene == "think" {
                // a bubble or two rising off her head, as if from the deep
                k.nextBubble = clock + Double.random(in: 0.8...1.2)
                k.bubbles.append((top + V(CGFloat.random(in: -0.35...0.35) * r, -0.1 * r), V(0, -1.0 * r), 0.12 * r, 1.7, CGFloat.random(in: 0.2...0.26) * r))
            } else if sleeping {
                // asleep, one slow bubble a breath instead of Z's
                k.nextBubble = clock + 1.9
                k.bubbles.append((top + V(0.15 * r, -0.08 * r), V(0.08 * r, -0.42 * r), 0.1 * r, 2.4, 0.24 * r))
            } else { k.nextBubble = clock + 0.2 }
        }
        // held up, she drips
        if mode == .grabbed && clock > k.nextDrip {
            k.nextDrip = clock + 0.22
            k.drops.append((c + V(CGFloat.random(in: -0.6...0.6) * r, 1.2 * r), V(0, 0.4 * r), CGFloat.random(in: 0.11...0.14) * r, 1.0))
        }
        // stuck: the spout will not go; a drop or two sputters up and falls back on her head
        if scene == "trouble" && clock > k.nextDrip {
            k.nextDrip = clock + Double.random(in: 0.9...1.3)
            for _ in 0..<Int.random(in: 1...2) {
                k.sputter.append((top + V(0, -0.1 * r), V(CGFloat.random(in: -0.45...0.45) * r, -CGFloat.random(in: 2.8...3.6) * r), 0.13 * r, 1.4))
            }
        }
    }

    /// Her water and hearts in the air this frame, as pictures: drops, sputtered drops, bubbles, splash crowns, hearts.
    func drawSea(_ silhouette: CGPath, _ dt: CGFloat) {
        let k = costume, r = radius, gravity = r * 26
        // drops fall and are gone where they land on her or on the ground
        for i in k.drops.indices.reversed() {
            var d = k.drops[i]
            d.life -= dt
            d.v.y += gravity * dt
            d.p = d.p + d.v * dt
            let landed = d.v.y > 0 && (silhouette.contains(L(d.p)) || (mode == .free && d.p.y > surface))
            if d.life <= 0 || landed { k.drops.remove(at: i) } else { k.drops[i] = d }
        }
        if k.drops.count > 16 { k.drops.removeFirst(k.drops.count - 16) }
        for d in k.drops { sprite("drop", d.p, width: d.r * 2, turn: atan2(d.v.x, d.v.y), opacity: d.life / 0.2) }
        // sputtered drops: up a little, back down onto her head with a tiny splash
        for i in k.sputter.indices.reversed() {
            var d = k.sputter[i]
            d.life -= dt
            d.v.y += gravity * dt
            d.p = d.p + d.v * dt
            if d.v.y > 0 && silhouette.contains(L(d.p)) {
                k.splashes.append((d.p + V(0, 0.05 * r), clock, 0.7 * r))
                k.sputter.remove(at: i)
            } else if d.life <= 0 { k.sputter.remove(at: i) } else { k.sputter[i] = d }
        }
        for d in k.sputter { sprite("drop", d.p, width: d.r * 2, turn: atan2(d.v.x, d.v.y)) }
        // bubbles wobble up, growing, and pop at the end
        for i in k.bubbles.indices.reversed() {
            var b = k.bubbles[i]
            b.life -= dt
            b.p = b.p + V(b.v.x + sin(CGFloat(clock) * 5 + CGFloat(i)) * 0.18 * r, b.v.y) * dt
            b.r += (b.full - b.r) * min(1, dt * 2.5)
            if b.life <= 0 { k.bubbles.remove(at: i) } else { k.bubbles[i] = b }
        }
        if k.bubbles.count > 6 { k.bubbles.removeFirst(k.bubbles.count - 6) }
        for b in k.bubbles {
            let popping = b.life < 0.12 ? 1 + (0.12 - b.life) * 3 : 1
            sprite("bubble", b.p, width: b.r * 2 * popping, opacity: min(1, b.life / 0.12))
        }
        // splash crowns: up out of the water, a moment, then they fall back
        k.splashes.removeAll { clock - $0.start > 0.8 }
        for s in k.splashes {
            let u = CGFloat(clock - s.start) / 0.8, grow = u < 0.25 ? easeOutBack(u / 0.25, overshoot: 1.4) : 1
            let fall = u > 0.55 ? (u - 0.55) / 0.45 : 0
            sprite("splash", s.p, width: s.width * (0.75 + 0.25 * grow), anchor: CGPoint(x: 0.5, y: 0.1),
                   opacity: 1 - fall, squash: max(0.05, (0.3 + 0.7 * grow) * (1 - 0.6 * fall)))
        }
        // hearts float up and fade
        k.hearts.removeAll { clock - $0.start > 1.3 }
        for h in k.hearts {
            let u = CGFloat(clock - h.start)
            sprite("heart", h.p + V(sin(u * 5) * 0.08 * r, -0.55 * r * u), width: 0.4 * r * min(1, 0.4 + u * 3), turn: 0.15 * sin(u * 4), opacity: 1.3 - u)
        }
    }
}
