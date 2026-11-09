// Drawing the goo into its layers, every frame.
import AppKit
import QuartzCore

extension Goo {
    // MARK: drawing

    func L(_ p: V) -> CGPoint { CGPoint(x: p.x - screenRect.minX, y: screenRect.maxY - p.y) }

    func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawBody()
        for i in 0..<3 { strands[i].path = strandPath(i) }
        drawFace()
        drawCostume()
        drawAct()
        drawBits()
        drawArms()
        fitShade()
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
        let whole = arms.path.map { skin.union($0) } ?? skin
        let box = whole.boundingBoxOfPath.insetBy(dx: -1, dy: -1), own = skin.boundingBoxOfPath
        guard box.width > 1, box.height > 1 else { return }
        shade.frame = box
        // the light sits on the body's upper left whatever the limbs are doing
        let light = CGPoint(x: (own.minX + own.width * 0.34 - box.minX) / box.width, y: (own.minY + own.height * 0.72 - box.minY) / box.height)
        shade.startPoint = light
        shade.endPoint = CGPoint(x: light.x + own.width * 0.78 / box.width, y: light.y + own.height * 0.78 / box.height)
        var home = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        shadeMask.path = whole.copy(using: &home)
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
        guard reach[i] > 0.02 else { return nil }
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
        // The looks are Tako's, when and why; an outfit may draw them in its own manner. The whale girl's are softened
        // (Joe 2026-11-08: a sly look is not her): lined eyes with a lift at the outer corner where Tako's lids drop, a
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
        eyeShadeL.path = open ? ellipse(left, lRX, max(0.7, lRY * lid)).subtracting(ellipse(left + V(0, r * 0.07), lRX * 1.04, max(0.7, lRY * lid))) : nil
        eyeShadeR.path = open ? ellipse(right, rRX, max(0.7, rRY * lid)).subtracting(ellipse(right + V(0, r * 0.07), rRX * 1.04, max(0.7, rRY * lid))) : nil
        let pL = left + gaze * (lRX * 0.43), pR = right + gaze * (rRX * 0.43)
        let prL = lRX * 0.5 * pupilBoost, prR = rRX * 0.5 * pupilBoost
        pupilL.path = showing ? ellipse(pL, prL, prL) : nil
        pupilR.path = showing ? ellipse(pR, prR, prR) : nil
        // a catch of light in each eye, so they look wet too
        func shine(_ p: V, _ pr: CGFloat) -> CGPath {
            let big = ellipse(p + V(-pr * 0.32, -pr * 0.36), pr * 0.27, pr * 0.27)
            return soft ? big.union(ellipse(p + V(pr * 0.34, pr * 0.3), pr * 0.13, pr * 0.13)) : big
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
        lidL.path = soft ? liner(left, lRX, lRY, -1) : lidShape(left, lRX, lRY)?.intersection(ellipse(left, lRX + 0.8, max(0.7, lRY * lid) + 0.8))
        lidR.path = soft ? liner(right, rRX, rRY, 1) : lidShape(right, rRX, rRY)?.intersection(ellipse(right, rRX + 0.8, max(0.7, rRY * lid) + 0.8))

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
