// Drawing the goo into its layers, every frame.
import AppKit
import QuartzCore

extension Goo {
    // MARK: drawing

    func L(_ p: V) -> CGPoint { CGPoint(x: p.x - screenRect.minX, y: screenRect.maxY - p.y) }

    func draw() {
        let profile = host.paceLog
        var mark = profile ? host.threadCPU() : 0
        func part(_ i: Int) { guard profile else { return }; let t = host.threadCPU(); drawCPU[i] += t - mark; mark = t }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Each part is drawn again only when something it is drawn from has changed: while little moves, a frame touches
        // only what moved (the strands swaying, an eye following the pointer).
        let shape = bodyKey, bodyMoved = shape != drawnBody
        if bodyMoved { drawBody(); drawnBody = shape }
        part(0)
        for i in 0..<3 { strands[i].path = strandPath(i) }
        // The face is the dearest part to draw (its lids and shading are cut from one shape by another): drawn again only
        // when something it is drawn from has changed.
        let face = faceKey
        if face != drawnFace { drawFace(); drawnFace = face }
        part(1)
        let dress = costumeKey(shape)
        if dress != drawnCostume { drawCostume(); drawnCostume = dress } else { coastCostume() }
        part(2)
        drawTape()
        drawAct()
        drawBits()
        drawIdleScene(); part(3)
        // The legs are joined into one shape piece by piece: only worked out again when something they hang from has moved.
        let limbs = armsKey, limbsMoved = limbs != drawnArms
        if limbsMoved { drawArms(); drawnArms = limbs }
        part(4)
        if handArmEdge.superlayer == nil {
            handArmEdge.fillColor = nil
            handArmEdge.strokeColor = NSColor(white: 1, alpha: 0.65).cgColor
            handArmEdge.lineWidth = 1.2
            view.layer!.addSublayer(handArmEdge)
        }
        handArmEdge.path = onDark && handGoal != nil ? arms.path : nil
        drawBubbleArm()
        drawHand(); part(5)
        if rippling && bodyMoved { stopRippling() }   // the light was fitted for the body as it was
        if !rippling && (bodyMoved || limbsMoved) { fitShade() }
        fitLiquid(); part(6)
        CATransaction.commit(); part(7)
    }

    func drawBubbleArm() {
        if bubbleArm.superlayer == nil {
            bubbleArm.fillColor = Goo.ink
            view.layer!.addSublayer(bubbleArm)
        }
        guard let goal = bubbleGoal else { bubbleArm.path = nil; return }
        bubbleArm.strokeColor = onDark ? NSColor(white: 1, alpha: 0.45).cgColor : nil
        bubbleArm.lineWidth = 0.7
        let side: CGFloat = goal.x < c.x ? -1 : 1
        let root = L(c + V(side * radius * 0.68, radius * 0.24))
        let tip = L(goal)
        let dx = tip.x - root.x, dy = tip.y - root.y
        let length = max(1, hypot(dx, dy)), nx = -dy / length, ny = dx / length
        let base = max(1.8, radius * 0.16), end: CGFloat = max(1.2, radius * 0.09)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: root.x + nx * base, y: root.y + ny * base))
        p.addCurve(to: CGPoint(x: tip.x + nx * end, y: tip.y + ny * end),
                   control1: CGPoint(x: root.x + dx * 0.26 + nx * (base + 4), y: root.y + dy * 0.14 + ny * (base + 4)),
                   control2: CGPoint(x: root.x + dx * 0.75 + nx * end, y: root.y + dy * 0.8 + ny * end))
        p.addLine(to: CGPoint(x: tip.x - nx * end, y: tip.y - ny * end))
        p.addCurve(to: CGPoint(x: root.x - nx * base, y: root.y - ny * base),
                   control1: CGPoint(x: root.x + dx * 0.75 - nx * end, y: root.y + dy * 0.8 - ny * end),
                   control2: CGPoint(x: root.x + dx * 0.26 - nx * (base + 4), y: root.y + dy * 0.14 - ny * (base + 4)))
        p.closeSubpath(); bubbleArm.path = p
    }

    func drawTape() {
        if tapeLayer.superlayer == nil {
            tapeLayer.fillColor = NSColor(calibratedRed: 0.93, green: 0.87, blue: 0.69, alpha: 1).cgColor
            tapeCross.strokeColor = Goo.ink; tapeCross.lineCap = .round; tapeCross.fillColor = nil
            view.layer!.addSublayer(tapeLayer); view.layer!.addSublayer(tapeCross)
        }
        guard tapeAmount > 0.02 else { tapeLayer.path = nil; tapeCross.path = nil; return }
        let r = radius, center = L(mouthAt), w = r * 0.87 * min(1, tapeAmount), h = r * 0.32
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x - w, y: center.y - h * 0.65))
        p.addLine(to: CGPoint(x: center.x + w, y: center.y - h))
        p.addLine(to: CGPoint(x: center.x + w * 0.96, y: center.y + h * 0.75))
        p.addLine(to: CGPoint(x: center.x - w * 1.04, y: center.y + h))
        p.closeSubpath(); tapeLayer.path = p
        let cross = CGMutablePath(), d = r * 0.17 * min(1, tapeAmount)
        cross.move(to: CGPoint(x: center.x - d, y: center.y - d)); cross.addLine(to: CGPoint(x: center.x + d, y: center.y + d))
        cross.move(to: CGPoint(x: center.x - d, y: center.y + d)); cross.addLine(to: CGPoint(x: center.x + d, y: center.y - d))
        tapeCross.lineWidth = max(0.8, r * 0.075); tapeCross.path = cross
    }

    /// The skin and every limb as one shape; the same two shapes as last time give the same answer without working it out again.
    func withLimbs(_ skin: CGPath) -> CGPath {
        guard let limbs = arms.path, !limbs.isEmpty else { return skin }
        if let last = limbsUnion, last.skin == skin, last.limbs == limbs { return last.whole }
        let whole = skin.union(limbs)
        limbsUnion = (skin, limbs, whole)
        return whole
    }

    /// Everything the face is drawn from; anything that moves by the clock alone puts the clock in, so it is drawn every frame.
    var faceKey: [CGFloat] {
        let soft = costume.isWhale && costume.dressed > 0.5
        let flags: [Bool] = [happy, dizzy, sleeping, oops, guilty, puddle, mode == .grabbed, mode == .free && !settled && !trotting,
                             state == "thinking", armOut > 6 && acting == nil, clock < smirkUntil, soft, costume.isWhale, costume.isCorgi]
        var bits: CGFloat = 0
        for (i, on) in flags.enumerated() where on { bits += CGFloat(1 << i) }
        var key: [CGFloat] = [bits, eye.x, eye.y, c.x, c.y, radius, pop, turn, lid, heavy, gaze.x, gaze.y, tall, actTilt(), pupilBoost,
                              costume.dressed, hoverTime > 0.15 ? CGFloat(hoverTime) : 0, screenRect.minX, screenRect.maxY]
        if mode == .grabbed || (mode == .free && !settled) { key += [v.length, mouseSpeed.length] }
        if dizzy || sleeping || hoverTime > 0.15 || acting != nil { key.append(CGFloat(clock)) }
        return key.map { ($0 * 256).rounded() }   // far below what a pixel shows, above what a settling spring leaves behind
    }

    /// Everything the body's own outline is drawn from: the skin, where it stands, the lean the whale girl's head takes.
    var bodyKey: [CGFloat] {
        var key: [CGFloat] = [c.x, c.y, radius, lean, leanDir.x, leanDir.y, surface, settled ? 1 : 0, mode == .free ? 1 : 0, onDark ? 1 : 0,
                              costume.isWhale ? 1 : 0, costume.isCorgi ? 1 : 0, costume.dressed, screenRect.minX, screenRect.maxY]
        for p in ring { key.append(p.x); key.append(p.y) }
        return key.map { ($0 * 256).rounded() }
    }

    /// Everything the legs, the reaching limb and the ink puffs are drawn from; the clock goes in whenever they move by it.
    var armsKey: [CGFloat] {
        var key: [CGFloat] = [c.x, c.y, radius, surface, creep, trot, mode == .free ? 1 : mode == .grabbed ? 2 : mode == .open ? 3 : 0,
                              settled ? 1 : 0, sleeping ? 1 : 0, puddle ? 1 : 0, perch != nil ? 1 : 0, CGFloat(armLeg), armOut > 3 ? 1 : 0,
                              trotting ? 1 : 0, peekSide, screenRect.minX, screenRect.maxY]
        if armOut > 3 { key += [armTip.x, armTip.y, armThick, armArrived ? 1 : 0, rippling ? 0 : CGFloat(clock)] }
        if !(mode == .free && settled) || creep > 0.002 || trotting || !ink.isEmpty { key += [CGFloat(clock), v.x, v.y, gait] }
        return key.map { ($0 * 256).rounded() }
    }

    /// One shape cut from another, worked out again only when what it is cut from has moved.
    func memo(_ slot: Int, _ key: [CGFloat], _ make: () -> CGPath?) -> CGPath? {
        let key = key.map { ($0 * 256).rounded() }
        if let hit = cuts[slot], hit.key == key { return hit.path }
        let path = make()
        cuts[slot] = (key, path)
        return path
    }

    /// The filtered layers cover only what is on them, so the blur costs little however big the screen is.
    func fitLiquid() {
        var box = CGRect(origin: L(c), size: .zero).insetBy(dx: -radius * 2.6, dy: -radius * 2.6)
        for i in 0..<3 where reach[i] > 0.02 && handHome == nil { box = box.union(CGRect(origin: L(anchor[i]), size: .zero)) }
        if armOut > 3 { box = box.union(CGRect(origin: L(armTip), size: .zero)) }
        box = box.insetBy(dx: -18, dy: -18)
        if liquid.bounds != box {
            liquid.bounds = box
            liquid.position = CGPoint(x: box.midX, y: box.midY)
        }
    }

    /// The skin, with any corners from collisions evened out before drawing.
    func smoothedSkin() -> [V] { smoothed(ring) }

    func smoothed(_ ring: [V]) -> [V] {
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

    /// The skin as one closed curve through its points.
    func skinPath(_ skin: [V]) -> CGPath {
        let path = CGMutablePath()
        let n = Goo.count
        path.move(to: L(skin[0]))
        for i in 0..<n {
            let p0 = skin[(i + n - 1) % n], p1 = skin[i], p2 = skin[(i + 1) % n], p3 = skin[(i + 2) % n]
            path.addCurve(to: L(p2), control1: L(p1 + (p2 - p0) * (1.0 / 6)), control2: L(p2 - (p3 - p1) * (1.0 / 6)))
        }
        path.closeSubpath()
        return path
    }

    func drawBody() {
        let n = Goo.count
        let skin = smoothedSkin()
        let path = skinPath(skin)
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
        _ = arc
        if costume.isWhale { whaleForm(skin) }
        // the goo is Tako's own in every outfit; the whale girl's light is broader and brighter, as in the drawing of her
        let broad = costume.isWhale ? costume.dressed : 0
        gloss.path = highlight(skin, thick: 0.11 + 0.03 * broad)
        gloss.fillColor = NSColor(white: 1, alpha: 0.62 + 0.2 * broad).cgColor


        if mode == .free && settled {
            let w = radius * 1.2, floor = screenRect.maxY - surface
            ground.shadowRadius = max(1.6, radius * 0.16)
            ground.shadowPath = CGPath(ellipseIn: CGRect(x: c.x - screenRect.minX - w, y: floor - 1.5, width: w * 2, height: 3), transform: nil)
        } else { ground.shadowPath = nil }
    }

    /// One light over the body and every limb together, so legs and arms read as the same goo, not parts stuck on.
    func fitShade() {
        guard let skin = body.path else { return }
        let limbs = arms.path.flatMap { $0.isEmpty ? nil : $0 }
        let own = skin.boundingBoxOfPath
        let box = (limbs.map { own.union($0.boundingBoxOfPath) } ?? own).insetBy(dx: -1, dy: -1)
        guard box.width > 1, box.height > 1 else { return }
        shade.frame = box
        // the light sits on the body's upper left whatever the limbs are doing
        let light = CGPoint(x: (own.minX + own.width * 0.34 - box.minX) / box.width, y: (own.minY + own.height * 0.72 - box.minY) / box.height)
        shade.startPoint = light
        shade.endPoint = CGPoint(x: light.x + own.width * 0.78 / box.width, y: light.y + own.height * 0.78 / box.height)
        var home = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        shadeMask.frame = CGRect(origin: .zero, size: box.size)
        shadeBody.path = skin.copy(using: &home)
        shadeLimbs.path = limbs.flatMap { $0.copy(using: &home) }
    }

    /// The wet highlight: a thin crescent just inside the upper-left skin, swelling in the middle and fading to points.
    func highlight(_ skin: [V], thick: CGFloat = 0.11) -> CGPath {
        let n = CGFloat(Goo.count)
        func at(_ f: CGFloat, _ inset: CGFloat) -> V {
            let x = (f * n).truncatingRemainder(dividingBy: n), i = Int(x), t = x - CGFloat(i)
            return mix(c, mix(skin[i % Goo.count], skin[(i + 1) % Goo.count], t), inset)
        }
        let path = CGMutablePath(), steps = 14, a: CGFloat = 0.55, b: CGFloat = 0.69
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for k in 0...steps {
            let s = CGFloat(k) / CGFloat(steps), f = mix(a, b, s)
            outer.append(L(at(f, 0.86)))
            inner.append(L(at(f, 0.86 - thick * sin(s * .pi))))
        }
        path.addLines(between: outer + inner.reversed())
        path.closeSubpath()
        return path
    }

    func strandPath(_ i: Int) -> CGPath? {
        guard reach[i] > 0.02, handHome == nil else { return nil }
        let a = anchor[i]
        let d = (a - c).unit, n = d.normal
        let base = c + d * (radius * 0.55)
        let tip = mix(base, a, reach[i])
        let length = (tip - base).length
        // Stretching thins it, like anything with a fixed amount of goo in it.
        let neck = clamp(radius * 0.32 * (22 / max(22, length)), 1.7, radius * 0.32)
        let gripped = stuck[i] ? reach[i] : reach[i] * 0.3
        let foot = (i == 1 ? radius * 0.34 : radius * 0.24) * gripped + neck * 0.5
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
        // The looks are Tako's, when and why; an outfit may draw them in its own manner. The whale girl's are softened with
        // lined eyes with a lift at the outer corner where Tako's lids drop, a
        // second catch of light, her cat's mouth where Tako smirks or bares its teeth.
        let soft = costume.isWhale && costume.dressed > 0.5
        let wide = 1 + pop * 0.22 + (mode == .grabbed ? 0.12 : 0)
        // the whole face turns with the head when it tips it over
        let tilt = actTilt()
        func tipped(_ p: V) -> V { V(p.x * cos(tilt) - p.y * sin(tilt), p.x * sin(tilt) + p.y * cos(tilt)) }
        // turned side on, each eye comes round with the head and the far one narrows
        func across(_ p: V) -> (V, CGFloat) { let q = (p - c) * (1 / r), t = turned(q.x, q.y); return (V(c.x + t.x * r, p.y), t.squeeze) }
        let (left, squeezeL) = across(eye + tipped(V(-r * 0.33, -r * 0.02))), (right, squeezeR) = across(eye + tipped(V(r * 0.33, r * 0.05)))
        let lRX = r * 0.3 * wide * squeezeL, lRY = r * 0.37 * wide, rRX = r * 0.25 * wide * squeezeR, rRY = r * 0.32 * wide
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
        let open = !(happy && !dizzy) && !sleeping
        eyeShadeL.path = open ? memo(0, [left.x, left.y, lRX, lRY * lid, r, screenRect.minX, screenRect.maxY]) { ellipse(left, lRX, max(0.7, lRY * lid)).subtracting(ellipse(left + V(0, r * 0.07), lRX * 1.04, max(0.7, lRY * lid))) } : nil
        eyeShadeR.path = open ? memo(1, [right.x, right.y, rRX, rRY * lid, r, screenRect.minX, screenRect.maxY]) { ellipse(right, rRX, max(0.7, rRY * lid)).subtracting(ellipse(right + V(0, r * 0.07), rRX * 1.04, max(0.7, rRY * lid))) } : nil
        let pL = left + gaze * (lRX * 0.43), pR = right + gaze * (rRX * 0.43)
        let prL = lRX * 0.5 * pupilBoost, prR = rRX * 0.5 * pupilBoost
        pupilL.path = showing ? ellipse(pL, prL, prL) : nil
        pupilR.path = showing ? ellipse(pR, prR, prR) : nil
        // a catch of light in each eye, so they look wet too
        func shine(_ p: V, _ pr: CGFloat) -> CGPath {
            let big = ellipse(p + V(-pr * 0.32, -pr * 0.36), pr * 0.27, pr * 0.27)
            guard soft else { return big }
            // the second catch of light lies apart from the first: the two filled together are their union
            let both = CGMutablePath()
            both.addPath(big); both.addPath(ellipse(p + V(pr * 0.34, pr * 0.3), pr * 0.13, pr * 0.13))
            return both
        }
        sparkleL.path = showing ? shine(pL, prL) : nil
        sparkleR.path = showing ? shine(pR, prR) : nil

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
            guard self.heavy > 0.03, !self.sleeping, !(self.happy && !self.dizzy) else { return nil }
            let top = p.y - ry - 1.5, bottom = p.y - ry + ry * 2 * self.heavy
            let q = CGMutablePath()
            q.move(to: self.L(V(p.x - rx - 1.5, top)))
            q.addLine(to: self.L(V(p.x + rx + 1.5, top)))
            q.addLine(to: self.L(V(p.x + rx + 1.5, bottom)))
            q.addQuadCurve(to: self.L(V(p.x - rx - 1.5, bottom)), control: self.L(V(p.x, bottom + r * 0.04)))
            q.closeSubpath()
            return q
        }
        // only where it covers the white: anywhere else it would be a flat patch on the shaded body
        // her line: along the top of the white, thickening toward the outer corner, where it lifts
        let liner = { (p: V, rx: CGFloat, ry: CGFloat, out: CGFloat) -> CGPath? in
            guard open, !self.dizzy, self.lid > 0.3 else { return nil }
            let white = self.ellipse(p, rx, max(0.7, ry * self.lid))
            return white.subtracting(self.ellipse(p + V(-out * r * 0.035, r * 0.06), rx * 1.03, max(0.7, ry * self.lid)))
        }
        let lidKey: [CGFloat] = [soft ? 1 : 0, open ? 1 : 0, dizzy ? 1 : 0, sleeping ? 1 : 0, happy ? 1 : 0, heavy, lid, r, screenRect.minX, screenRect.maxY]
        lidL.path = memo(2, lidKey + [left.x, left.y, lRX, lRY]) { soft ? liner(left, lRX, lRY, -1) : lidShape(left, lRX, lRY)?.intersection(ellipse(left, lRX + 0.8, max(0.7, lRY * lid) + 0.8)) }
        lidR.path = memo(3, lidKey + [right.x, right.y, rRX, rRY]) { soft ? liner(right, rRX, rRY, 1) : lidShape(right, rRX, rRY)?.intersection(ellipse(right, rRX + 0.8, max(0.7, rRY * lid) + 0.8)) }

        // A small smile; surprised while dragged; the venom teeth when it has something to say.
        let m = onFront(eye + tipped(V(0, r * 0.5)))
        mouthAt = m
        let path = CGMutablePath()
        // Left resting on it for a moment, it starts nibbling the cursor.
        let chomp = hoverTime > 1 ? abs(sin(CGFloat(clock) * 11)) * 0.75 + 0.15 : pop
        // an outfit may draw the plain smile its own way (the whale girl's pink cat's mouth); every other look is Tako's
        var plain = true
        if happy {
            // a wide open smile
            path.move(to: L(m + V(-r * 0.24, -r * 0.02)))
            path.addQuadCurve(to: L(m + V(r * 0.24, -r * 0.02)), control: L(m + V(0, r * 0.05)))
            path.addQuadCurve(to: L(m + V(-r * 0.24, -r * 0.02)), control: L(m + V(0, r * 0.36)))
            path.closeSubpath()
        } else if oops {
            plain = false
            // an awkward little frown
            path.move(to: L(m + V(-r * 0.15, r * 0.08)))
            path.addQuadCurve(to: L(m + V(r * 0.15, r * 0.08)), control: L(m + V(0, -r * 0.04)))
            path.addQuadCurve(to: L(m + V(-r * 0.15, r * 0.08)), control: L(m + V(0, r * 0.04)))
            path.closeSubpath()
        } else if guilty {
            plain = false
            // whistling innocently, off to one side
            path.addPath(ellipse(m + V(r * 0.2, r * 0.04), r * 0.07, r * 0.08))
        } else if !soft && ((armOut > 6 && acting == nil) || clock < smirkUntil) && chomp <= 0.14 {
            plain = false
            // the smirk
            path.move(to: L(m + V(-r * 0.2, r * 0.05)))
            path.addQuadCurve(to: L(m + V(r * 0.27, -r * 0.09)), control: L(m + V(r * 0.08, r * 0.1)))
            path.addQuadCurve(to: L(m + V(-r * 0.2, r * 0.05)), control: L(m + V(r * 0.08, r * 0.19)))
            path.closeSubpath()
        } else if puddle {
            plain = false
            path.addRect(CGRect(origin: L(m + V(-r * 0.16, r * 0.02)), size: CGSize(width: r * 0.32, height: 1.1)))
        } else if sleeping {
            plain = false
            path.addPath(ellipse(m + V(0, r * 0.05), r * 0.07, r * 0.07 * (1 + 0.5 * sin(CGFloat(clock) * 1.1))))
        } else if tall > 0.4 {
            plain = false
            path.addPath(ellipse(m + V(0, r * 0.08), r * 0.16, r * 0.24 * tall))
        } else if dizzy {
            plain = false
            path.move(to: L(m + V(-r * 0.24, 0)))
            for i in 1...4 {
                let up: CGFloat = i % 2 == 0 ? -1 : 1
                path.addQuadCurve(to: L(m + V(-r * 0.24 + r * 0.12 * CGFloat(i), 0)), control: L(m + V(-r * 0.3 + r * 0.12 * CGFloat(i), up * r * 0.1)))
            }
            for i in (0...3).reversed() {
                path.addLine(to: L(m + V(-r * 0.24 + r * 0.12 * CGFloat(i), r * 0.02)))
            }
            path.closeSubpath()
        } else if !soft && chomp > 0.14 {
            plain = false
            let w = r * (0.34 + chomp * 0.16), h = r * (0.06 + chomp * 0.3), teeth = 4
            let step = (w * 2) / CGFloat(teeth)
            path.move(to: L(m + V(-w, 0)))
            for i in 0..<teeth {
                path.addLine(to: L(m + V(-w + step * (CGFloat(i) + 0.5), -r * 0.07)))
                path.addLine(to: L(m + V(-w + step * (CGFloat(i) + 1), 0)))
            }
            path.addQuadCurve(to: L(m + V(-w, 0)), control: L(m + V(0, h * 2)))
            path.closeSubpath()
        } else if mode == .grabbed || (mode == .free && !settled && !trotting) {
            plain = false
            let s = clamp(max(mouseSpeed.length, v.length) / 900, 0.09, 0.2) * r
            path.addPath(ellipse(m + V(0, r * 0.05), s * 0.85, s))
        } else {
            // a smile drawn as one soft stroke with round ends, so its tips never break up into specks
            let w = r * (state == "thinking" ? 0.1 : 0.19), h = r * (state == "thinking" ? 0.03 : 0.16)
            let arc = CGMutablePath()
            arc.move(to: L(m + V(-w, 0)))
            arc.addQuadCurve(to: L(m + V(w, 0)), control: L(m + V(0, h)))
            path.addPath(arc.copy(strokingWithWidth: max(1.1, r * 0.075), lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        if plain && costume.isWhale && costume.dressed > 0.5 {
            mouth.path = nil
            whaleMouth(at: m, wide: happy)
        } else {
            mouth.path = path
            for layer in [costume.mouthIn, costume.mouthTongue, costume.lip] { layer.path = nil }
        }
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

    }
}

// MARK: what Core Animation carries while nothing else moves

extension Goo {
    /// Breathing in and out while nothing else on the body moves: the skin's outline (and its wet highlight, and its light
    /// edge on a dark window) drawn by Core Animation through one breath, from where the breath is now, as the stepped skin
    /// would take it, while the stepped skin holds its breath (`breathHeld`): handing over and back join without a seam. Asleep
    /// and still, its small round mouth opens and closes with it. Costs no frames.
    func keepBreathing(mouthToo: Bool) {
        if breathing && breathAsleep != sleeping { stopBreathing() }
        if costume.isWhale { keepWagging() }
        keepRippling()
        guard !breathing else { return }
        breathing = true
        breathAsleep = sleeping
        breathHeld = clock
        let (amount, speed): (CGFloat, CGFloat) = sleeping ? (0.04, 1.1) : (0.018, 1.5)
        let period = Double(2 * CGFloat.pi / speed), samples = 40, start = CGFloat(clock)
        let base = 1 + amount * sin(start * speed), now = ring, middle = c
        let broad = costume.isWhale ? costume.dressed : 0
        var skins: [CGPath] = [], shines: [CGPath] = [], times: [NSNumber] = []
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples), f = (1 + amount * sin((start + u * CGFloat(period)) * speed)) / base
            let skin = smoothed(now.map { middle + ($0 - middle) * f })
            skins.append(skinPath(skin)); shines.append(highlight(skin, thick: 0.11 + 0.03 * broad))
            times.append(NSNumber(value: Double(u)))
        }
        func breathe(_ layer: CAShapeLayer, _ shapes: [CGPath]) {
            guard layer.path != nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = shapes
            animation.keyTimes = times
            animation.duration = period
            animation.repeatCount = .infinity
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)   // a slow breath needs few
            layer.add(animation, forKey: "breath")
        }
        breathe(body, skins)
        breathe(outline, skins)
        breathe(gloss, shines)
        guard mouthToo, sleeping, mouth.path != nil else { return }
        let m = mouthAt + V(0, radius * 0.05), r = radius
        breathe(mouth, (0...samples).map { i in
            let u = CGFloat(i) / CGFloat(samples)
            return ellipse(m, r * 0.07, r * 0.07 * (1 + 0.5 * sin((start + u * CGFloat(period)) * 1.1)))
        })
    }

    /// A limb held out on a window's edge (a promise, the pocket of things held) ripples along its length as it always does,
    /// by Core Animation while nothing else moves: one whole turn of the ripple (and of its tip's tapping), from where it is,
    /// over and over, and the light over body and limb with it. With legs to join it to, it stays the stepped body's.
    func keepRippling() {
        guard armOut > 3, !rippling, mode == .attached || mode == .open, perch == nil, !puddle, !sleeping,
              let skin = body.path else { return }
        rippling = true
        let period = armArrived ? 2 * Double.pi : 2 * Double.pi / 5, samples = Int(period * 30)
        let own = skin.boundingBoxOfPath
        // The same limb held out the same way as last time: the turn already worked out is played from where the clock is.
        let key = armsKey + [(own.minX * 256).rounded(), (own.minY * 256).rounded(), (own.width * 256).rounded()]
        if ripples?.key != key {
            var shapes: [CGPath] = [], times: [NSNumber] = []
            var box = own
            for i in 0...samples {
                let u = Double(i) / Double(samples), shape = limbsPath(at: clock + period * u)
                shapes.append(shape); times.append(NSNumber(value: u))
                if !shape.isEmpty { box = box.union(shape.boundingBoxOfPath) }
            }
            ripples = (key, clock, shapes, times, box.insetBy(dx: -1, dy: -1), nil, .zero)
        }
        let made = ripples!, start = made.start, shapes = made.shapes, times = made.times, box = made.box
        let offset = (clock - start).truncatingRemainder(dividingBy: period)
        func ripple(_ layer: CAShapeLayer, _ values: [CGPath]) {
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = values; animation.keyTimes = times; animation.duration = period; animation.repeatCount = .infinity
            animation.timeOffset = offset
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            layer.add(animation, forKey: "ripple")
        }
        ripple(arms, shapes)
        if handArmEdge.path != nil { ripple(handArmEdge, shapes) }
        // one frame for the light the whole way round, so only the limb's part of its mask moves
        shade.frame = box
        let light = CGPoint(x: (own.minX + own.width * 0.34 - box.minX) / box.width, y: (own.minY + own.height * 0.72 - box.minY) / box.height)
        shade.startPoint = light
        shade.endPoint = CGPoint(x: light.x + own.width * 0.78 / box.width, y: light.y + own.height * 0.78 / box.height)
        var home = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        shadeMask.frame = CGRect(origin: .zero, size: box.size)
        shadeBody.path = skin.copy(using: &home)
        if ripples?.shade == nil || ripples?.shadeAt != box.origin { ripples?.shade = shapes.map { $0.copy(using: &home) ?? $0 }; ripples?.shadeAt = box.origin }
        ripple(shadeLimbs, ripples?.shade ?? [])
    }

    func stopRippling() {
        guard rippling else { return }
        rippling = false
        for layer in [arms, handArmEdge, shadeLimbs] { layer.removeAnimation(forKey: "ripple") }
        drawnArms = []   // drawn again, and the light fitted again, on the next frame
    }

    /// The skin breathes for itself again, from the breath Core Animation had got to.
    func stopBreathing() {
        if costume.isWhale { stopWagging() }
        stopRippling()
        guard breathing else { return }
        breathing = false
        breathHeld = nil
        for layer in [body, outline, gloss, mouth] { layer.removeAnimation(forKey: "breath") }
    }

    /// Asleep: a Z rises every second and a half (the whale girl breathes out a bubble every 1.9 seconds), as the stepped
    /// body used to make them, but drawn by Core Animation from two layers taking turns, so sleep costs no frames.
    func dream() {
        stopDreaming(finishing: false)
        guard sleeping, let root = view.layer else { return }
        let whale = costume.isWhale && costume.dressed > 0.5
        let spacing = whale ? 1.9 : 1.5, life = whale ? 2.4 : 2.2, period = spacing * 2
        let now = CACurrentMediaTime()
        dreamingAt = c
        for (k, layer) in dreams.enumerated() {
            layer.removeAllAnimations()
            layer.opacity = 0
            if whale {
                layer.path = nil
                if layer.superlayer !== root { layer.removeFromSuperlayer(); root.addSublayer(layer) }
            } else {
                layer.contents = nil
                layer.fillColor = nil; layer.strokeColor = zLayer.strokeColor; layer.lineWidth = zLayer.lineWidth; layer.lineCap = .round
                if layer.superlayer !== zLayer { layer.removeFromSuperlayer(); zLayer.addSublayer(layer) }
            }
            let cycle = whale ? bubbleCycle(layer, life: life, period: period) : zCycle(life: life, period: period)
            cycle.beginTime = now + Double(k) * spacing
            cycle.repeatCount = .infinity
            layer.add(cycle, forKey: "dream")
        }
    }

    /// Woken: what is already rising goes on up and is gone, nothing new comes.
    func stopDreaming(finishing: Bool = true) {
        guard dreamingAt != nil else { return }
        dreamingAt = nil
        let now = CACurrentMediaTime()
        for layer in dreams {
            guard let cycle = layer.animation(forKey: "dream")?.copy() as? CAAnimationGroup else { continue }
            layer.removeAnimation(forKey: "dream")
            guard finishing, now >= cycle.beginTime else { continue }
            cycle.beginTime += floor((now - cycle.beginTime) / cycle.duration) * cycle.duration
            cycle.repeatCount = 1
            layer.add(cycle, forKey: "dream")
        }
    }

    private func zCycle(life: Double, period: Double) -> CAAnimationGroup {
        let start = c + V(radius * 0.7, -radius * 0.8), steps = Int(life * 10)
        var shapes: [CGPath] = [], times: [NSNumber] = []
        for i in 0...steps {
            let age = life * Double(i) / Double(steps), left = CGFloat(life - age)
            // as each step used to move it: up 11 points a second, swaying with what is left of its life
            let p = start + V((5 / 3) * (cos(left * 3) - cos(CGFloat(life) * 3)), -11 * CGFloat(age))
            let s = 2 + CGFloat(age) * 1.1
            let z = CGMutablePath()
            z.move(to: L(p + V(-s, -s))); z.addLine(to: L(p + V(s, -s))); z.addLine(to: L(p + V(-s, s))); z.addLine(to: L(p + V(s, s)))
            shapes.append(z); times.append(NSNumber(value: age / period))
        }
        shapes.append(shapes[shapes.count - 1]); times.append(1)
        let path = CAKeyframeAnimation(keyPath: "path")
        path.values = shapes; path.keyTimes = times
        return cycle([path], life: life, period: period)
    }

    private func bubbleCycle(_ layer: CAShapeLayer, life: Double, period: Double) -> CAAnimationGroup {
        let r = radius, full = 0.24 * r, first = 0.1 * r, start = rim(smoothedSkin(), 1.5 * .pi) + V(0.15 * r, -0.08 * r)
        let scale = view.window?.backingScaleFactor ?? 2, widest = full * 2 * 1.36
        costume.dress(layer, "bubble", points: (widest * scale / 6).rounded(.up) * 6 / scale, scale: scale)
        layer.bounds = CGRect(x: 0, y: 0, width: widest, height: widest * Costume.aspect("bubble"))
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.transform = CATransform3DIdentity
        let steps = Int(life * 12)
        var places: [NSValue] = [], sizes: [NSValue] = [], fades: [NSNumber] = [], times: [NSNumber] = []
        for i in 0...steps {
            let age = life * Double(i) / Double(steps), left = CGFloat(life - age), a = CGFloat(age)
            // as each step used to move it: drifting up and a little aside, wobbling, swelling to full, popping at the end
            let p = start + V(0.08 * r * a - (0.18 * r / 5) * (cos(5 * a) - 1), -0.42 * r * a)
            let size = full - (full - first) * exp(-2.5 * a)
            let popping: CGFloat = left < 0.12 ? 1 + (0.12 - left) * 3 : 1
            let k = size * 2 * popping / widest
            places.append(NSValue(point: L(p))); sizes.append(NSValue(caTransform3D: CATransform3DMakeScale(k, k, 1)))
            fades.append(NSNumber(value: Float(min(1, left / 0.12)))); times.append(NSNumber(value: age / period))
        }
        places.append(places[places.count - 1]); sizes.append(sizes[sizes.count - 1]); fades.append(0); times.append(1)
        let position = CAKeyframeAnimation(keyPath: "position"), grow = CAKeyframeAnimation(keyPath: "transform"), fade = CAKeyframeAnimation(keyPath: "opacity")
        position.values = places; grow.values = sizes; fade.values = fades
        for animation in [position, grow, fade] { animation.keyTimes = times }
        return cycle([position, grow, fade], life: life, period: period, fading: false)
    }

    /// One turn of a dream layer: shown for its life, then hidden until its next turn.
    private func cycle(_ parts: [CAAnimation], life: Double, period: Double, fading: Bool = true) -> CAAnimationGroup {
        var all = parts
        if fading {
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [1, 1, 0, 0]
            show.keyTimes = [0, NSNumber(value: life / period), NSNumber(value: life / period + 0.0001), 1]
            all.append(show)
        }
        let group = CAAnimationGroup()
        group.animations = all
        group.duration = period
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        group.isRemovedOnCompletion = true
        return group
    }
}
