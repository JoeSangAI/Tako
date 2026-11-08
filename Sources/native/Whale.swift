// The DeepSeek whale girl (Wardrobe.swift says when she is worn), the way Tako wears her after swallowing her: it becomes
// the drawing of her that ends the film. A round head a little wider than tall with a broad white crescent of light,
// smiling eyes, two pink strokes of blush on each cheek, a small open pink mouth; short fat arms and legs; her white lace
// apron with the little blue whale, her black tail up behind on the right with its forked fluke, and now and then her
// spout.
// What she does is her own, in two lines: a whale's (she goes down deep to think, blows when a job is done, a rainbow in it
// after a long one, sputters when stuck, breathes bubbles asleep, drips when held up, lands with a splash, now and then
// leaps or gulps a passing fish) and a maid's (hand over her eyes looking about, notes on her order pad, the feather duster,
// waiting with a tray, hiding her face when stroked, a curtsey when done). None of it is the corgi's.
// Everything that is not her body is a picture in the same style (Sources/art): the apron, tail and spout cut from the
// drawing, the water and her maid's things made to match it. They are hung on the goo and squashed, turned and sprung with
// it; the rest is drawn here to the drawing's measures, in head radii from the middle of the head (x across, y down).
// Plain Tako is untouched: all of this only while she is worn.
import AppKit
import QuartzCore

extension Goo {
    // where the cut pieces sit in the drawing, in head radii from the middle of the head
    static let apronBox = CGRect(x: -0.7161, y: 0.5742, width: 1.4673, height: 0.8612)
    static let tailBox = CGRect(x: 0.6874, y: 0.0638, width: 0.9888, height: 0.9888), tailPivot = V(1.0064, 0.8612)
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

    /// An ellipse turned by `a` (positive turns its right end down).
    func blob(_ p: V, _ rx: CGFloat, _ ry: CGFloat, _ a: CGFloat) -> CGPath {
        let q = L(p)
        var turn = CGAffineTransform(translationX: q.x, y: q.y).rotated(by: -a)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &turn)
    }

    /// Her light: a broad white crescent along the upper left of the head.
    func whaleGloss() -> CGPath {
        let arc = CGMutablePath()
        arc.move(to: L(onHead(-0.69, -0.4)))
        arc.addQuadCurve(to: L(onHead(-0.29, -0.735)), control: L(onHead(-0.55, -0.6525)))
        return arc.copy(strokingWithWidth: max(1.2, radius * 0.1), lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// One tentacle along a centre line, thick at the root and thin at the end (`widths` are half widths, one per point),
    /// round at both ends; with a long soft light along its upper side, like the one on her head.
    func tentacle(_ line: [V], _ widths: [CGFloat], up: CGFloat) -> (shape: CGPath, rim: CGPath) {
        var left: [CGPoint] = [], right: [CGPoint] = [], normals: [V] = []
        for (i, p) in line.enumerated() {
            let d = (line[min(line.count - 1, i + 1)] - line[max(0, i - 1)]).unit, n = d.normal
            normals.append(n)
            left.append(L(p + n * widths[i]))
            right.append(L(p - n * widths[i]))
        }
        let outline = CGMutablePath()
        outline.addLines(between: left + right.reversed())
        outline.closeSubpath()
        var shape: CGPath = outline.union(ellipse(line[0], widths[0], widths[0]))
        shape = shape.union(ellipse(line[line.count - 1], widths[widths.count - 1], widths[widths.count - 1]))
        // the light: a thin crescent along the side facing up, over the middle of its length
        let rim = CGMutablePath(), from = line.count / 5, to = line.count * 3 / 5
        if to > from + 1 {
            var edge: [CGPoint] = [], inner: [CGPoint] = []
            for i in from...to {
                let side = normals[i] * up, s = sin(CGFloat(i - from) / CGFloat(to - from) * .pi)
                edge.append(L(line[i] + side * (widths[i] * 0.72)))
                inner.append(L(line[i] + side * (widths[i] * (0.72 - 0.3 * s))))
            }
            rim.addLines(between: edge + inner.reversed())
            rim.closeSubpath()
        }
        return (shape, rim)
    }

    /// Tako's tentacles as she wears them: four short fat ones coming out from under the apron, two out to the sides and two
    /// down in front, each thick at the root, thinning, its end rolled up in Tako's little curl;
    /// the front pair over the back pair, each with its own outline and a light edge so they read one by one. Two short arms
    /// at the bottom of the head hold the apron's corners (or come round in front for her manners, `hands`). On the ground
    /// the front pair stand and paddle; off it they all hang and wave. `reaching` is the one out as an arm, drawn the same
    /// way along `reach`.
    func whaleLimbs(reaching: Int?, reach: [V]?) {
        let k = costume, r = radius
        let grounded = mode == .free && settled
        let ground = surface - 0.6
        // an arm at rest sits behind, at the bottom of the head; one the pose puts to use comes round in front (`hands`)
        let pose = maidPose()
        var arms: CGPath = CGMutablePath()
        for (side, x, held, palm, bend) in [(CGFloat(-1), CGFloat(-0.593), pose.left, pose.leftPalm, pose.leftElbow),
                                            (1, 0.663, pose.right, pose.rightPalm, pose.rightElbow)] {
            let shoulder = onHead(x, 0.746)
            guard let hand = held else { arms = arms.union(blob(shoulder, 0.245 * r, 0.19 * r, 0)); continue }
            // the elbow kept out to the side, so a raised arm goes up beside the head and not across the face; the arm meets
            // the palm at its outer end. Drawn like her tentacles: outlined, a soft light along it, so it reads on her black.
            let high = clamp((shoulder.y - hand.y) / r, 0, 1)
            let wrist = hand + rotate(V(side * palm.0 * 0.65 * r, 0), -palm.2)
            let elbow = bend ?? mix(shoulder, wrist, 0.5) + V(side * (0.22 + 0.5 * high) * r, 0.04 * r)
            var line: [V] = [], widths: [CGFloat] = []
            let control = elbow * 2 - (shoulder + wrist) * 0.5
            for j in 0...12 {
                let s = CGFloat(j) / 12
                line.append(shoulder * ((1 - s) * (1 - s)) + control * (2 * s * (1 - s)) + wrist * (s * s))
                widths.append(mix(0.19 * r, 0.12 * r, s))
            }
            let piece = tentacle(line, widths, up: side * -1)
            arms = arms.union(blob(shoulder, 0.2 * r, 0.16 * r, 0))
            k.handPaths.append(piece.shape.union(blob(hand, palm.0 * r, palm.1 * r, palm.2)))
            k.handLights.append(piece.rim)
            k.handLights.append(blob(hand + rotate(V(0, -palm.1 * 0.42 * r), -palm.2), palm.0 * 0.7 * r, max(0.5, palm.1 * 0.26 * r), palm.2))   // a gleam on the palm
        }
        // root, middle, end of each, in head radii: out left, down left, down right, out right
        let rest: [(V, V, V)] = [(V(-0.42, 1.0), V(-0.84, 1.17), V(-1.1, 1.08)), (V(-0.2, 1.12), V(-0.3, 1.37), V(-0.6, 1.4)),
                                 (V(0.22, 1.12), V(0.33, 1.37), V(0.63, 1.4)), (V(0.44, 1.0), V(0.86, 1.17), V(1.12, 1.08))]
        // the body under the apron, out to where the arms and the outer pair meet, so no chink of window shows between them
        var back: CGPath = ellipse(onHead(0.03, 0.98), 0.55 * r * k.sx, 0.4 * r)
        for side in [CGFloat(-1), 1] { back = back.union(ellipse(onHead(side * 0.72, 0.95), 0.2 * r, 0.17 * r)) }
        var front: CGPath = CGMutablePath()
        let rims = [CGMutablePath(), CGMutablePath()], grooves = [CGMutablePath(), CGMutablePath()]
        k.tailRoot = nil
        for i in 0..<4 where i != reaching {
            let (root0, mid0, end0) = rest[i]
            let side: CGFloat = i < 2 ? -1 : 1, down = i == 1 || i == 2
            let root = onHead(root0.x, root0.y)
            var mid = onHead(mid0.x, mid0.y), end = onHead(end0.x, end0.y)
            let phase = CGFloat(clock) * 10 + CGFloat(i) * .pi
            if grounded {
                // on the ground whatever the head does; walking, the front pair paddle and the outer pair wave
                mid.y = ground - (1.52 - mid0.y) * r
                end.y = ground - (1.52 - end0.y) * r
                let step = creep * (peekSide != 0 ? 1.6 : 1)
                if down {
                    let paddle = V(sin(phase * 0.6) * 0.07 * r * step, -max(0, cos(phase * 0.6)) * 0.06 * r * step)
                    mid = mid + paddle * 0.6
                    end = end + paddle
                } else {
                    end.y -= sin(phase) * 0.06 * r * step
                }
                // and never quite still: the ends breathe a little
                end = end + V(0, sin(CGFloat(clock) * 1.7 + CGFloat(i)) * 0.025 * r)
            } else {
                // off the ground they hang and wave; at speed they stream out behind
                let wave = sin(CGFloat(clock) * 8 + CGFloat(i) * 1.7)
                mid = mid + V(wave * 0.04 * r, (down ? 0.08 : 0.12) * r)
                end = end + V(wave * 0.09 * r - side * (down ? 0 : 0.12) * r, (down ? 0.16 : 0.3) * r)
                let streaming = clamp((v.length - 260) / 500, 0, 1), behind = (v * -1).unit * (0.4 * r * streaming)
                mid = mid + behind * 0.6
                end = end + behind
            }
            if i == 3 { k.tailRoot = mid - onHead(mid0.x, mid0.y) }   // the tail goes in behind this one and moves with it
            // the centre line: through the middle to the end, then rolled up in a curl, upward and outward
            var line: [V] = [], widths: [CGFloat] = []
            let control = mid * 2 - (root + end) * 0.5, w0: CGFloat = 0.25 * r, w1: CGFloat = (down ? 0.17 : 0.18) * r, w2: CGFloat = 0.1 * r
            for j in 0...10 {
                let s = CGFloat(j) / 10
                line.append(root * ((1 - s) * (1 - s)) + control * (2 * s * (1 - s)) + end * (s * s))
                widths.append(s < 0.5 ? mix(w0, w1, s * 2) : mix(w1, w2, (s - 0.5) * 2))
            }
            let d = (line[10] - line[9]).unit, n = d.normal, up: CGFloat = n.y < 0 ? 1 : -1
            let curl = 0.13 * r, centre = end + n * (up * curl), start = atan2(end.y - centre.y, end.x - centre.x)
            let spin: CGFloat = (V(-sin(start), cos(start)).x * d.x + V(-sin(start), cos(start)).y * d.y) >= 0 ? 1 : -1
            let sweep = 1.25 * .pi + 0.12 * .pi * sin(CGFloat(clock) * 1.9 + CGFloat(i) * 2)
            for j in 1...9 {
                let u = CGFloat(j) / 9, a = start + spin * sweep * u, radius = curl * (1 - 0.42 * u)
                line.append(centre + V(cos(a), sin(a)) * radius)
                widths.append(mix(w2, 0.05 * r, u))
            }
            let piece = tentacle(line, widths, up: up)
            let g = down ? 1 : 0
            // the middle of the curl filled in: an open loop would leave a pinhole of window in the black
            let shape = piece.shape.union(ellipse(centre, curl, curl))
            if down { front = front.union(shape) } else { back = back.union(shape) }
            rims[g].addPath(piece.rim)
            // and the line round the inside of the curl, so it still reads as rolled up
            let groove = CGMutablePath()
            for j in 11..<line.count {
                let p = line[j] + (centre - line[j]).unit * (widths[j] * 0.9)
                if j == 11 { groove.move(to: L(p)) } else { groove.addLine(to: L(p)) }
            }
            grooves[g].addPath(groove.copy(strokingWithWidth: max(0.5, r * 0.022), lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        // the one out as an arm: the same tentacle however far it goes, fat at the root, thinning, never to a thread, its
        // end rolled in the same little curl
        if let reach, reach.count > 2 {
            var line = reach, widths = reach.indices.map { i -> CGFloat in
                let s = CGFloat(i) / CGFloat(reach.count - 1)
                return s < 0.4 ? mix(0.3 * r, 0.19 * r, s / 0.4) : mix(0.19 * r, 0.09 * r, (s - 0.4) / 0.6)
            }
            // a wider loop than the resting ones and a thinner end going into it, so at arm's length it still reads as a
            // curl and not a knob
            let end = line[line.count - 1], d = (end - line[line.count - 2]).unit, n = d.normal, up: CGFloat = n.y < 0 ? 1 : -1
            let curl = 0.19 * r, centre = end + n * (up * curl), start = atan2(end.y - centre.y, end.x - centre.x)
            let spin: CGFloat = (V(-sin(start), cos(start)).x * d.x + V(-sin(start), cos(start)).y * d.y) >= 0 ? 1 : -1
            for j in 1...10 {
                let u = CGFloat(j) / 10, a = start + spin * 1.35 * .pi * u
                line.append(centre + V(cos(a), sin(a)) * (curl * (1 - 0.45 * u)))
                widths.append(mix(0.09 * r, 0.045 * r, u))
            }
            let piece = tentacle(line, widths, up: up)
            front = front.union(piece.shape.union(ellipse(centre, curl * 0.8, curl * 0.8)))
            rims[1].addPath(piece.rim)
            let groove = CGMutablePath()
            for j in reach.count..<line.count {
                let p = line[j] + (centre - line[j]).unit * (widths[j] * 0.9)
                if j == reach.count { groove.move(to: L(p)) } else { groove.addLine(to: L(p)) }
            }
            grooves[1].addPath(groove.copy(strokingWithWidth: max(0.5, r * 0.022), lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        let line = max(0.5, r * 0.02)
        for (j, layer) in k.tentacles.enumerated() where j % 3 == 0 {
            layer.lineWidth = line
            // on a dark window her black needs the light edge Tako's own outline gives it
            layer.strokeColor = onDark ? NSColor(white: 1, alpha: 0.28).cgColor : Costume.whaleLine
        }
        k.armsLine.lineWidth = max(0.5, r * 0.016)
        k.armsLine.strokeColor = k.tentacles[0].strokeColor
        k.tailArt.shadowOpacity = onDark ? 0.45 : 0
        k.tentacles[0].path = back
        k.tentacles[1].path = grooves[0]
        k.tentacles[2].path = rims[0]
        k.tentacles[3].path = front
        k.tentacles[4].path = grooves[1]
        k.tentacles[5].path = rims[1]
        k.armsLine.path = arms
        if let down = k.beat?.swallow {
            // the fish going down: a lump under the mouth sliding down to her middle
            k.handPaths.append(ellipse(mix(onHead(0.03, 0.34), onHead(0.03, 0.62), down), 0.17 * r * (1 - 0.4 * down), 0.15 * r * (1 - 0.4 * down)))
        }
        var hands: CGPath? = nil
        for path in k.handPaths { hands = hands.map { $0.union(path) } ?? path }
        k.hands.path = hands
        let lights = CGMutablePath()
        for path in k.handLights { lights.addPath(path) }
        k.handLight.path = k.handLights.isEmpty ? nil : lights
        k.handLights = []
        k.hands.lineWidth = max(0.6, r * 0.024)
        k.hands.strokeColor = k.tentacles[0].strokeColor
        k.handPaths = []
    }

    /// Her face, when it is hers: smiling eyes, a small open pink mouth (wider when pleased). Startled, caught, dizzy, asleep
    /// and the like are Tako's own faces for the moment; then this says no and leaves the face to drawFace.
    func drawWhaleFace() -> Bool {
        let k = costume, r = radius
        let startled = !k.breaching && (mode == .grabbed || (mode == .free && !settled && !trotting) || pop > 0.3 || guilty || oops
            || hoverTime > 1 || puddle || tall > 0.4)
        guard !dizzy, !sleeping, happy || !startled else { return false }
        k.faceOwn = true
        let pose = maidPose()
        let tilt = actTilt() + k.swim + pose.tilt
        let middle = k.mid + slosh * 0.6 + gaze * (r * 0.05) + V((0.027 + pose.look * 0.11) * r * k.sx, 0)
        func F(_ x: CGFloat, _ y: CGFloat) -> V { middle + rotate(V(x * r * k.sx, y * r * k.sy), tilt) }
        // eyes: two thick white arcs, bowed up; a blink flattens them for a moment. Gone down deep to think they close to
        // calm lines; stuck, they droop
        let deep = acting == "think" && !happy, stuck = acting == "trouble" && !happy, beat = k.beat
        let bliss = (beat?.content ?? 0) > 0.3, full = (beat?.puff ?? 0) > 0.3
        let bow: CGFloat = full ? -0.4 : bliss ? -0.2 : happy || pose.shy ? -0.35 : deep ? -0.13 : stuck ? 0.02 : -0.31, open = clamp(lid, 0, 1)
        for layer in [pupilL, pupilR, sparkleL, sparkleR, eyeShadeL, eyeShadeR, lidL, lidR, swirl] { layer.path = nil }
        if let beat, beat.wide > 0.5, let fish = beat.fish {
            // a fish! eyes gone round and shining, both on it
            let to = (fish - middle).unit
            for (white, pupil, shine, x) in [(eyeL, pupilL, sparkleL, CGFloat(-0.39)), (eyeR, pupilR, sparkleR, 0.39)] {
                let e = F(x, -0.12), p = e + to * (0.07 * r)
                white.path = ellipse(e, 0.21 * r * k.sx, 0.25 * r * k.sy)
                pupil.path = ellipse(p, 0.12 * r, 0.13 * r)
                shine.path = ellipse(p + V(-0.045 * r, -0.05 * r), 0.045 * r, 0.045 * r).union(ellipse(p + V(0.04 * r, 0.05 * r), 0.022 * r, 0.022 * r))
            }
        } else {
            for (layer, x) in [(eyeL, CGFloat(-0.39)), (eyeR, 0.39)] {
                let arc = CGMutablePath()
                arc.move(to: L(F(x - 0.215, -0.06)))
                arc.addQuadCurve(to: L(F(x + 0.215, -0.06)), control: L(F(x, mix(-0.09, bow, open))))
                layer.path = arc.copy(strokingWithWidth: max(1.2, r * 0.11), lineCap: .round, lineJoin: .round, miterLimit: 1)
            }
        }
        // the mouth: a pink opening hanging from a little cat's lip, the tongue lighter at the bottom; it opens downward,
        // for a fish to half her face; with her cheeks full it is a small shut thing
        let s: CGFloat = full ? 0.42 : (happy || bliss ? 1 : deep || stuck || pose.shy ? 0.7 : 0.85) * (1 + 2.1 * (beat?.mouth ?? 0))
        func M(_ x: CGFloat, _ y: CGFloat) -> V { F(x * s, 0.07 + (y - 0.07) * s) }
        let opening = CGMutablePath()
        opening.move(to: L(M(-0.105, 0.083)))
        opening.addQuadCurve(to: L(M(0, 0.062)), control: L(M(-0.05, 0.092)))
        opening.addQuadCurve(to: L(M(0.105, 0.083)), control: L(M(0.05, 0.092)))
        opening.addCurve(to: L(M(0, 0.215)), control1: L(M(0.115, 0.15)), control2: L(M(0.07, 0.215)))
        opening.addCurve(to: L(M(-0.105, 0.083)), control1: L(M(-0.07, 0.215)), control2: L(M(-0.115, 0.15)))
        opening.closeSubpath()
        k.mouthIn.path = opening
        mouthAt = M(0, 0.14)
        k.mouthTongue.path = opening.intersection(ellipse(M(0, 0.255), 0.12 * r * s * k.sx, 0.105 * r * s * k.sy))
        // the little cat's lip over it, its ends turned up
        let lip = CGMutablePath()
        lip.move(to: L(M(-0.13, 0.062)))
        lip.addQuadCurve(to: L(M(0, 0.055)), control: L(M(-0.07, 0.11)))
        lip.addQuadCurve(to: L(M(0.13, 0.062)), control: L(M(0.07, 0.11)))
        k.lip.lineWidth = max(0.5, r * 0.022)
        k.lip.path = lip
        mouth.path = nil
        return true
    }

    // MARK: her maid's manners

    /// What her hands are doing and what they hold, this moment: hands in points, the prop as a picture with where it sits.
    struct MaidPose {
        var left: V?, right: V?
        // each hand's palm, in head radii (half width, half height, turn), and where its elbow goes if not the usual way
        var leftPalm: (CGFloat, CGFloat, CGFloat) = (0.19, 0.17, 0), rightPalm: (CGFloat, CGFloat, CGFloat) = (0.19, 0.17, 0)
        var leftElbow: V?, rightElbow: V?
        var prop: (name: String, at: V, width: CGFloat, turn: CGFloat, anchor: CGPoint)?
        var pencil: V?
        var dip: CGFloat = 0, tilt: CGFloat = 0, look: CGFloat = 0, blush: CGFloat = 0
        var stars = false, shy = false
    }

    /// Her maid's manners: stroked, she hides her face in her hands, blushing; a job done, a little curtsey holding out her
    /// apron; and the scenes of work she plays as a maid: shading her eyes to look about (search), taking it down on her
    /// order pad (answer, write, file), dusting (run), waiting with a tray, with a small bow now and then (wait).
    func maidPose() -> MaidPose {
        let k = costume, r = radius
        var p = MaidPose()
        guard k.dressed > 0.5, !sleeping, !dizzy, mode != .grabbed, !puddle, !k.breaching else { return p }
        func H(_ x: CGFloat, _ y: CGFloat) -> V { onHead(x, y) }
        let shy = CGFloat(clock - k.pettedAt), bow = CGFloat(clock - k.curtseyAt)
        if shy >= 0 && shy < 1.4 {
            // both hands up over her cheeks, blushing hard, a little sway
            let rock = sin(shy * 9) * 0.03
            p.left = H(-0.7 + rock, 0.2); p.right = H(0.7 + rock, 0.2)   // round palms flat on her cheeks
            p.leftPalm = (0.21, 0.2, 0); p.rightPalm = (0.21, 0.2, 0)
            p.leftElbow = H(-1.22, 0.62); p.rightElbow = H(1.22, 0.62)
            p.shy = true; p.blush = 1; p.tilt = 0.08 * sin(shy * 5)
            return p
        }
        if bow >= 0 && bow < 1.0 {
            // a curtsey: the apron held out at both sides, down she dips and up again
            let e = sin(bow / 1.0 * .pi)
            p.left = H(-0.88, 0.98 - 0.1 * e); p.right = H(0.9, 0.98 - 0.1 * e)
            p.dip = 0.09 * e; p.tilt = -0.06 * e; p.blush = 0.5
            return p
        }
        if let beat = k.beat, beat.content > 0.05 {
            // after the fish: a hand going round on her tummy, blushing with pleasure
            p.right = H(0.14 + 0.09 * cos(t * 7), 0.74 + 0.05 * sin(t * 7)); p.blush = 1
            p.rightElbow = H(0.78, 0.98)
            return p
        }
        guard let a = acting else { return p }
        switch a {
        case "search":
            // a hand to her brow, looking this way and that, up on her toes now and then, little stars twinkling
            let side: CGFloat = sin(t * .pi / 1.7) >= 0 ? 1 : -1
            p.look = side * 0.8
            p.tilt = side * 0.1
            // a small flat hand across her brow, reaching out past the edge of her head; the eyes look out from under it
            p.right = H(0.64, -0.41)
            p.rightPalm = (0.34, 0.1, -0.1)
            p.rightElbow = H(1.32, 0.02)
            let tiptoe = (t / 2.6).truncatingRemainder(dividingBy: 1)
            p.dip = tiptoe < 0.18 ? -0.08 * sin(tiptoe / 0.18 * .pi) : 0
            p.stars = true; p.blush = 0.5
        case "answer", "write", "file":
            // the order pad in her left hand, the pencil going in her right
            p.prop = ("pad", H(-0.25, 0.6), 0.9 * r, 0.1, CGPoint(x: 0.5, y: 0.5))
            p.left = H(-0.66, 0.84)
            p.right = H(0.16, 0.58) + V(sin(t * 9) * 0.07 * r, cos(t * 15) * 0.03 * r)
            p.pencil = p.right
            p.tilt = 0.06; p.look = -0.3
        case "run":
            // dusting with the feather duster, held up high on the right and swished to and fro
            let swish = sin(t * 9)
            p.right = H(0.98 + 0.06 * swish, -0.12)
            p.rightElbow = H(1.3, 0.38)
            p.prop = ("duster", p.right!, 1.25 * r, 0.25 + 0.35 * swish, CGPoint(x: 0.16, y: 0.22))
            p.tilt = -0.05 * swish
        case "wait":
            // waiting with a tray, tea on it; now and then a small bow
            let u = (t / 3.4).truncatingRemainder(dividingBy: 1), bowing = u > 0.72 ? sin((u - 0.72) / 0.28 * .pi) : 0
            p.prop = ("tray", H(0, 0.66 + 0.08 * bowing), 1.55 * r, 0, CGPoint(x: 0.5, y: 0.5))
            p.left = H(-0.7, 0.86 + 0.08 * bowing); p.right = H(0.7, 0.86 + 0.08 * bowing)
            p.dip = 0.08 * bowing; p.blush = 0.3
        default: break
        }
        return p
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
        // putting her on: the splash hides the change of shape, then the apron pops on, the tail springs out, a spout, a wiggle
        k.dressed = clamp((since - 0.1) / 0.22, 0, 1)
        let apronIn = popIn(since, 0.35), tailIn = popIn(since, 0.7)
        func passes(_ at: CGFloat) -> Bool { since >= at && since - dt < at }
        if passes(0.35) || passes(0.7) { kick(32) }   // a little jolt as each part pops on
        if passes(1.15) { spout(1); kick(40) }
        if passes(1.6) { celebrate() }
        let pose = maidPose()
        if k.dressed > 0.5 { seaLife(dt, pose) }

        // what her moods ask of the tail: how high it is held, how hard and how fast it wags. Pleased, it goes right up.
        let scared = guilty || !ink.isEmpty
        let moving = mode == .free && wanderTo != nil && creep > 0.3
        var lift: CGFloat = 0, wagAmount: CGFloat = 0.08, wagSpeed: CGFloat = 2.4
        if sleeping { lift = -0.45; wagAmount = 0.03; wagSpeed = 1 }
        else if scared { lift = -0.7; wagAmount = 0.05; wagSpeed = 20 }                // tucked away, trembling
        else if mode == .grabbed { lift = -0.5; wagAmount = 0.25; wagSpeed = 9 }      // dangling, wriggling
        else if dizzy { lift = -0.2; wagAmount = 0.3; wagSpeed = 5 }
        else if pose.shy { lift = 0.25; wagAmount = 0.3; wagSpeed = 18 }              // stroked: a delighted flutter
        else if happy { lift = 0.2; wagAmount = 0.12; wagSpeed = 12 }                // up as in the drawing, wagging
        else if oops { lift = -0.45; wagAmount = 0.04; wagSpeed = 2 }
        else if pop > 0.3 { lift = 0.35; wagAmount = 0.1; wagSpeed = 3 }
        else if let a = acting {
            switch a {
            case "think": lift = 0.15; wagAmount = 0.12; wagSpeed = 1.4                  // curling slowly, down in the deep
            case "look", "read": lift = 0.3; wagAmount = 0.04; wagSpeed = 3              // held still, attentive
            case "search": lift = 0.25; wagAmount = 0.12; wagSpeed = 5                   // curious
            case "run": lift = 0.15; wagAmount = 0.16; wagSpeed = 9                      // busy dusting
            case "answer", "write", "file": lift = 0.15; wagAmount = 0.12; wagSpeed = 3
            case "listen": lift = 0.2; wagAmount = 0.2; wagSpeed = 6.8                   // tapping to the beat
            case "wait": lift = 0.2; wagAmount = 0.06; wagSpeed = 2                      // waiting politely
            case "trouble": lift = -0.5; wagAmount = 0.04; wagSpeed = 1.5                // drooping
            default: break
            }
        } else if moving { lift = 0.1; wagAmount = 0.3; wagSpeed = 4.5 }                // a slow rudder as she swims along
        if clock - k.swishAt < 1.4 { lift = 0.3; wagAmount = 0.3; wagSpeed = 10 }
        k.spring(&k.tailLift, &k.tailLiftV, to: lift, k: 200, damping: 15, dt)
        k.wag += (wagAmount - k.wag) * min(1, dt * 6)
        k.wagPhase += wagSpeed * dt

        // The tail, the drawing's own: turned about where it goes in under the right arm and leg, and carried along with that
        // leg so its root stays hidden; down when it is not pleased, wagging; it springs out from there when she is put on.
        // It never swings in further than the drawing has it: closer, it would touch the head and close in a chink of window.
        if tailIn > 0.02 && !puddle {
            let box = Goo.tailBox, pivot = onHead(Goo.tailPivot.x, Goo.tailPivot.y) + (k.tailRoot ?? V())
            k.dress(k.tailArt, "tail", points: box.width * r, scale: scale)
            k.tailArt.bounds = CGRect(x: 0, y: 0, width: box.width * r, height: box.height * r)
            k.tailArt.anchorPoint = CGPoint(x: (Goo.tailPivot.x - box.minX) / box.width, y: 1 - (Goo.tailPivot.y - box.minY) / box.height)
            k.tailArt.position = L(pivot)
            let turn = min(0.04, clamp(k.tailLift, -1, 1) * 0.42 - 0.12 + k.wag * sin(k.wagPhase) * 0.7)   // at rest a little lower than drawn
            k.tailArt.transform = CATransform3DScale(CATransform3DMakeRotation(turn, 0, 0, 1), tailIn, tailIn, 1)
            k.tailArt.isHidden = false
        } else { k.tailArt.isHidden = true }

        // The apron, the drawing's own: on the lower body, its top corners under the arms, squashed with the head and
        // tipped with the face; it pops on from its middle.
        if apronIn > 0.02 && !puddle {
            let box = Goo.apronBox
            k.dress(k.apronArt, "apron", points: box.width * r, scale: scale)
            k.apronArt.bounds = CGRect(x: 0, y: 0, width: box.width * r, height: box.height * r)
            k.apronArt.position = L(onHead(box.midX, box.midY))
            let turn = CATransform3DMakeRotation(-(actTilt() + k.swim + pose.tilt) * 0.4, 0, 0, 1)
            k.apronArt.transform = CATransform3DScale(turn, k.sx * apronIn, k.sy * apronIn, 1)
            k.apronArt.isHidden = false
        } else { k.apronArt.isHidden = true }

        // blush: two short pink strokes on each cheek with a soft glow, with her face (and asleep); deeper when she is shy
        let cheeks = CGMutablePath(), glow = CGMutablePath(), b = pose.blush
        if k.dressed > 0.5 && (k.faceOwn || sleeping) {
            let tilt = actTilt() + k.swim + pose.tilt, middle = k.mid + slosh * 0.6 + V((0.027 + pose.look * 0.11) * r * k.sx, 0)
            func F(_ x: CGFloat, _ y: CGFloat) -> V { middle + rotate(V(x * r * k.sx, y * r * k.sy), tilt) }
            for side in [CGFloat(-1), 1] {
                for x in [CGFloat(0.553), 0.684] {
                    let p = F(side * x, 0.137), stroke = CGMutablePath()
                    stroke.move(to: L(p + rotate(V(-0.03 * r, 0.035 * r), tilt)))
                    stroke.addLine(to: L(p + rotate(V(0.03 * r, -0.035 * r), tilt)))
                    cheeks.addPath(stroke.copy(strokingWithWidth: max(0.9, r * 0.062 * (1 + 0.25 * b)), lineCap: .round, lineJoin: .round, miterLimit: 1))
                }
                glow.addPath(ellipse(F(side * 0.62, 0.137), r * (0.17 + 0.06 * b) * k.sx, r * (0.1 + 0.04 * b) * k.sy))
            }
        }
        k.blush.shadowRadius = max(1, r * 0.05)
        k.blush.fillColor = NSColor(srgbRed: 0.95 + 0.03 * b, green: 0.6 - 0.2 * b, blue: 0.59 - 0.12 * b, alpha: 1).cgColor
        k.trim.fillColor = NSColor(srgbRed: 0.97, green: 0.45, blue: 0.5, alpha: 0.05 + 0.3 * b).cgColor
        k.blush.path = cheeks.isEmpty ? nil : cheeks
        k.trim.path = glow.isEmpty ? nil : glow
        if !k.faceOwn { k.mouthIn.path = nil; k.mouthTongue.path = nil; k.lip.path = nil }

        // what sets the water going: a job done (then a curtsey; a long job brings a rainbow in the spout), and putting her
        // on. Stroked, she does not blow: she hides her face.
        if happy && !k.wasHappy && clock - k.pettedAt > 0.6 {
            spout(1)
            k.curtseyAt = clock + 1.1
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

        // what is in her hands
        if let prop = pose.prop { sprite(prop.name, prop.at, width: prop.width, turn: prop.turn, anchor: prop.anchor, held: true) }
        if let hand = pose.pencil { sprite("pencil", hand + V(-0.1 * r, 0.05 * r), width: 0.42 * r, anchor: CGPoint(x: 0.6, y: 0.55), held: true) }

        var silhouette = arms.path.map { skin.union($0) } ?? skin
        for limbs in [k.tentacles[0].path, k.tentacles[3].path, k.armsLine.path].compactMap({ $0 }) { silhouette = silhouette.union(limbs) }
        drawSea(silhouette, pose, dt)
    }

    // MARK: her sea

    /// The scenes she plays her own way instead of with Tako's props (Acts.swift skips its own for these): deep in thought
    /// and stuck as a whale, the rest as a maid.
    static let whaleActs: Set<String> = ["think", "search", "run", "answer", "write", "file", "wait", "trouble"]
    /// A job this long (seconds) ends in a spout with a rainbow in it.
    static let longJob = 60.0

    /// Coming down from a height, or out of a leap: a splash crown round her feet, as big as the fall.
    func landsInWater(_ hit: CGFloat) {
        let k = costume
        guard k.dressed > 0.5 else { return }
        if k.breaching {
            k.breaching = false
            splash(at: V(c.x, surface - 1), width: 3.6, count: 8)
            kick(90)
            happyUntil = max(happyUntil, clock + 0.9)
        } else if hit > 450 {
            splash(at: V(c.x, surface - 1), width: 2.2 + min(1.2, (hit - 450) / 800), count: 4 + min(4, Int((hit - 450) / 200)))
        }
    }

    /// A rare trick: a whale's leap straight up out of the water, the tail flicked at the top, a big splash coming down.
    func whaleBreach() {
        guard costume.isWhale, mode == .free, settled, !sleeping else { return }
        costume.breaching = true
        costume.swishAt = clock
        v.y = -(2 * 1700 * radius * 3).squareRoot()
        settled = false
        kick(60)
        splash(at: V(c.x, surface - 1), width: 1.8, count: 2)
    }

    /// Where she is in her fish gag, a cartoon in five beats: she sees it (eyes round and shining, drawing back), opens wide
    /// (half her face, her head pulled long), snaps it up (a lunge, her head squashed flat and springing back), cheeks full
    /// (the fish wriggling in one), down it goes (a lump sliding down), and she is pleased (eyes shut, a hand on her tummy,
    /// a burp, blushing, the tail flicked). Nil when there is no fish.
    struct FishBeat {
        var fish: V?
        var wide: CGFloat = 0, mouth: CGFloat = 0, stretch = V(1, 1), lunge: CGFloat = 0
        var puff: CGFloat = 0, wobble: CGFloat = 0, swallow: CGFloat?, content: CGFloat = 0, star = false
        var tail: CGFloat = 0   // the fish's tail still out of the corner of her mouth, 1 all out, going back in to 0
    }

    func fishBeat() -> FishBeat? {
        let u = CGFloat(clock - costume.fishAt), r = radius, side = facing
        guard u >= 0, u < 3 else { return nil }
        func ease(_ x: CGFloat) -> CGFloat { let s = clamp(x, 0, 1); return s * s * (3 - 2 * s) }
        func hump(_ a: CGFloat, _ peak: CGFloat, _ e: CGFloat) -> CGFloat { u < a || u > e ? 0 : u < peak ? ease((u - a) / (peak - a)) : 1 - ease((u - peak) / (e - peak)) }
        var b = FishBeat()
        // it swims up and stops a little way off, wiggling; the lunge pulls it in
        if u < 1.1 {
            let mouth = onHead(0.03, 0.14), stop = mouth + V(side * 1.05 * r, -0.08 * r), start = stop + V(side * 2.6 * r, -0.35 * r)
            b.fish = u < 0.98 ? mix(start, stop, ease(u / 0.7)) + V(0, sin(u * 14) * 0.06 * r) : mix(stop, mouth, ease((u - 0.98) / 0.12))
        }
        b.wide = u > 0.42 && u < 1.04 ? 1 : 0
        b.star = u > 0.42 && u < 0.85
        let back = hump(0.42, 0.58, 0.9)                                                  // drawing back, gathering herself
        b.mouth = u < 0.68 ? 0 : u < 0.9 ? ease((u - 0.68) / 0.22) : u < 1.04 ? 1 : max(0, 1 - (u - 1.04) / 0.06)
        let lunge = hump(0.95, 1.07, 1.4), snap = hump(1.04, 1.11, 1.42)
        b.lunge = (0.34 * lunge - 0.14 * back) * r * side
        b.stretch = V(1 + 0.05 * back - 0.07 * b.mouth + 0.18 * snap, 1 - 0.08 * back + 0.15 * b.mouth - 0.2 * snap)
        b.puff = u < 1.1 ? 0 : u < 1.22 ? ease((u - 1.1) / 0.12) : u < 1.85 ? 1 : max(0, 1 - ease((u - 1.85) / 0.15))
        b.wobble = u > 1.42 && u < 1.72 ? sin((u - 1.42) * 31) : 0
        b.tail = u < 1.12 || u > 1.62 ? 0 : u < 1.18 ? (u - 1.12) / 0.06 : u < 1.48 ? 1 : 1 - (u - 1.48) / 0.14   // flicks, then slurped in
        if u > 1.98 && u < 2.3 { b.swallow = (u - 1.98) / 0.32 }
        b.content = u > 2.25 ? min(1, (u - 2.25) / 0.12) * min(1, (3 - u) / 0.2) : 0
        return b
    }

    /// A rare trick: a little blue fish swims up to her and she gulps it down (`fishBeat`).
    func whaleSnack() {
        guard costume.isWhale, !sleeping, mode != .grabbed, clock - costume.fishAt > 3 else { return }
        costume.fishAt = clock
    }

    /// Every frame she is dressed: how far she has sunk or dips, the bubbles and drops her state gives off, how long the job
    /// has been running, and now and then, left to herself, one of her rare tricks.
    func seaLife(_ dt: CGFloat, _ pose: MaidPose) {
        let k = costume, r = radius, scene = acting ?? ""
        // the fish gag: its beats, and the bumps and sounds of it
        k.beat = fishBeat()
        let fu = CGFloat(clock - k.fishAt)
        func at(_ when: CGFloat) -> Bool { fu >= when && fu - dt < when }
        if at(0.42) { kick(18) }                                                              // ooh
        if at(1.07) { kick(70) }                                                              // snap!
        if at(1.98) { kick(30) }                                                              // gulp
        if at(2.32) { k.swishAt = clock }
        if at(2.5) {                                                                          // burp
            kick(24)
            k.bubbles.append((onHead(facing * 0.62, 0.12), V(facing * 0.55 * r, -0.55 * r), 0.08 * r, 1.4, 0.24 * r))
        }
        k.stretch = k.beat?.stretch ?? V(1, 1)
        if k.breaching && !settled {
            // in the leap: drawn out long going up, round at the top with a flick of the tail, long again coming down
            let rise = clamp(abs(v.y) / (radius * 14), 0, 1)
            k.stretch = V(1 - 0.12 * rise, 1 + 0.16 * rise)
            if abs(v.y) < radius * 3 && clock - k.swishAt > 0.5 { k.swishAt = clock }
        }
        k.lunge = k.beat?.lunge ?? 0
        k.puff = k.beat?.puff ?? 0
        k.wobble = k.beat?.wobble ?? 0
        // the job's length, for the rainbow at its end
        if !act.isEmpty, k.busySince == nil { k.busySince = clock }
        if act.isEmpty, let since = k.busySince { k.busyLength = clock - since; k.busyEndedAt = clock; k.busySince = nil }
        // done thinking: up she comes from the deep, and blows
        if k.lastAct == "think" && scene != "think" && !sleeping { spout(0.6); kick(45) }
        k.lastAct = scene
        // a heart when she goes shy, and one with her curtsey
        if pose.shy && !k.wasShy { k.hearts.append((onHead(0.95, -0.45), clock)) }
        k.wasShy = pose.shy
        let bow = clock - k.curtseyAt
        if bow >= 0.25 && bow < 0.25 + Double(dt) * 1.5 { k.hearts.append((onHead(-0.95, -0.5), clock)) }
        // how far down: deep in thought she sinks; swimming along she bobs; her manners dip her
        let moving = mode == .free && wanderTo != nil && creep > 0.3
        var down = pose.dip * r, sway: CGFloat = 0
        if scene == "think" { down = 0.13 * r + 0.015 * r * sin(t * 1.6) }
        else if moving { down = 0.05 * r * sin(t * 5); sway = 0.07 * sin(t * 2.5) }
        k.sink += (down - k.sink) * min(1, dt * 7)
        k.swim += (sway - k.swim) * min(1, dt * 4)
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
            k.drops.append((c + V(CGFloat.random(in: -0.6...0.6) * r, 1.62 * r), V(0, 0.4 * r), CGFloat.random(in: 0.11...0.14) * r, 1.0))
        }
        // stuck: the spout will not go; a drop or two sputters up and falls back on her head
        if scene == "trouble" && clock > k.nextDrip {
            k.nextDrip = clock + Double.random(in: 0.9...1.3)
            for _ in 0..<Int.random(in: 1...2) {
                k.sputter.append((top + V(0, -0.1 * r), V(CGFloat.random(in: -0.45...0.45) * r, -CGFloat.random(in: 2.8...3.6) * r), 0.13 * r, 1.4))
            }
        }
        // her rare tricks, left to herself: a few minutes apart, now one, now the other
        if k.nextRare == 0 { k.nextRare = clock + Double.random(in: 180...480) }
        if clock > k.nextRare && act.isEmpty && !sleeping && !dizzy && !happy && mode != .grabbed && armOut < 3 && clock - k.fishAt > 3 {
            k.nextRare = clock + Double.random(in: 180...480)
            if mode == .free && settled && wanderTo == nil && Bool.random() { whaleBreach() } else { whaleSnack() }
        }
    }

    /// Her water and things in the air this frame, as pictures: drops, sputtered drops, bubbles, splash crowns, the fish,
    /// twinkles while she looks about or dusts, hearts.
    func drawSea(_ silhouette: CGPath, _ pose: MaidPose, _ dt: CGFloat) {
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
        // the fish, while it is still outside her, and the star of her finding it
        if let beat = k.beat {
            if let fish = beat.fish { sprite("fish", fish, width: 0.66 * r, turn: 0.15 * sin(t * 13), flip: facing < 0) }
            if beat.tail > 0.02 {
                // its tail out of the corner of her mouth, flicking, then slurped in
                let corner = mouthAt + V(facing * 0.1 * r, -0.02 * r)
                sprite("fish", corner + V(facing * 0.22 * r * beat.tail, 0), width: 0.5 * r, turn: 0.35 * sin(t * 26) * beat.tail, flip: facing < 0)
            }
            if beat.star {
                let u = CGFloat(clock - k.fishAt - 0.45)
                sprite("star", onHead(-facing * 0.95, -0.95), width: 0.42 * r * min(1, u * 6) * (1 + 0.15 * sin(u * 20)), turn: u * 2)
            }
        }
        // twinkles: about her head while she looks for something, round the feathers while she dusts
        if pose.stars {
            for (i, (x, y, w)) in [(CGFloat(1.15), CGFloat(-0.85), CGFloat(0.36)), (0.78, -1.3, 0.24)].enumerated() {
                let tw = abs(sin(t * 3.2 + CGFloat(i) * 1.7))
                sprite("star", onHead(x * (pose.look >= 0 ? 1 : -1), y), width: w * r * (0.55 + 0.45 * tw), turn: t * 0.6, opacity: 0.4 + 0.6 * tw)
            }
        }
        if let prop = pose.prop, prop.name == "duster" {
            let tip = prop.at + rotate(V(0.62 * r, 0), -(prop.turn + 0.55))
            for i in 0..<2 {
                let tw = abs(sin(t * 6 + CGFloat(i) * 2))
                sprite("star", tip + V((CGFloat(i) - 0.5) * 0.45 * r, -0.12 * r * CGFloat(i)), width: 0.2 * r * tw, turn: t, opacity: tw)
            }
        }
        // hearts float up and fade
        k.hearts.removeAll { clock - $0.start > 1.3 }
        for h in k.hearts {
            let u = CGFloat(clock - h.start)
            sprite("heart", h.p + V(sin(u * 5) * 0.08 * r, -0.55 * r * u), width: 0.4 * r * min(1, 0.4 + u * 3), turn: 0.15 * sin(u * 4), opacity: 1.3 - u)
        }
    }
}
