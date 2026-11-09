// What Tako acts out while it works: a small scene for each kind of step, told by the panel in fixed words
// (think, search, run, look, read, answer, write, file, operate, listen, wait, trouble). Every scene has a plain
// version any outfit can use; an outfit plays some of them its own way (`costume.isCorgi` below; the whale girl plays a few
// with her water and her order pad, Whale.swift `whaleActs`), never with a body of its own.
import AppKit
import QuartzCore

extension Goo {
    /// The scene it is in, or nil: only while there is one, and never while it sleeps, reels or is being held.
    var acting: String? { act.isEmpty || sleeping || dizzy || mode == .grabbed || puddle ? nil : act }
    var t: CGFloat { CGFloat(clock) }
    /// Which way it faces on its own: stuck on a window it looks out from the window's edge, to the right.
    var facing: CGFloat { mode == .attached || mode == .open ? 1 : (mouseAt.x >= c.x ? 1 : -1) }

    /// Where its eyes go in the scene.
    func actLook() -> V? {
        guard let a = acting else { return nil }
        switch a {
        case "think": return V(-0.55 + 0.2 * sin(t * 1.3), -0.9)
        case "search": return costume.isCorgi ? V(facing * 0.7, 0.75) : V(facing * 0.9, -0.25)
        case "run": return costume.isCorgi ? V(facing * 0.5, 0.9) : V(0.1, 0.95)
        case "look", "read":
            // line by line: across, back to the start of the next line, four lines and over again
            let line: CGFloat = a == "read" ? 0.75 : 1.1
            let u = t.truncatingRemainder(dividingBy: line * 4), row = (u / line).rounded(.down), p = (u - row * line) / line
            return V(p < 0.85 ? -0.8 + 1.6 * (p / 0.85) : 0.8 - 1.6 * ((p - 0.85) / 0.15), -0.3 + 0.18 * row)
        case "answer", "write", "file": return V(facing * 0.75, 0.55)
        case "wait": let to = mouseAt - c; return to.length > 4 ? to.unit : V(0, -0.3)
        case "trouble": return V(-0.7, 0.45)
        case "listen": return V(sin(t * 1.6) * 0.3, -0.2)
        default: return nil
        }
    }

    /// How far the head tips over.
    func actTilt() -> CGFloat {
        switch acting {
        case "think": return costume.isCorgi ? 0.3 + 0.04 * sin(t * 1.7) : 0.12 * sin(t * 0.9)   // a dog's "hm?"
        case "listen": return 0.13 * sin(t * 3.4)                                                 // nodding to it
        case "search": return costume.isCorgi ? 0.08 * sin(t * 6) : 0
        case "wait": return 0.08 * sin(t * 2.2)
        default: return 0
        }
    }

    /// Where a limb goes to hold the scene's prop, if it needs one.
    func actHold() -> V? {
        let r = radius
        switch acting {
        case "search" where !costume.isCorgi: return c + V(facing * (r * 1.15 + sin(t * 1.8) * r * 0.22), -r * 0.05)
        case "answer", "write", "file": return c + V(facing * r * 1.05, r * 0.42) + scribble()
        default: return nil
        }
    }

    /// The nib's small loops while it writes.
    func scribble() -> V { V(sin(t * 9) * radius * 0.13, cos(t * 18) * radius * 0.05) }

    /// Puppy eyes while it waits for the owner's yes.
    var pupilBoost: CGFloat { acting == "wait" ? 1.3 : 1 }

    /// The props and bits of business around the body, every frame.
    func drawAct() {
        let dt = CGFloat(clamp(CGFloat(clock - actLast), 0, 0.05))
        actLast = clock
        let ink = CGMutablePath(), light = CGMutablePath(), line = CGMutablePath(), r = radius
        defer { propInk.path = ink; propLight.path = light; propLine.path = line; propLine.lineWidth = max(0.8, r * 0.055) }
        guard let a = acting else { actBeat = 0; return }
        actBeat += dt
        if costume.isWhale && Goo.whaleActs.contains(a) { return }   // she plays it her own way (Whale.swift)
        let tip = armOut > 3 ? armTip : nil
        switch a {
        case "think":
            // three thought bubbles, coming up one after another
            let k = (t * 0.8).truncatingRemainder(dividingBy: 1)
            for (i, (dx, dy, size)) in [(0.78, -1.05, 0.07), (1.0, -1.38, 0.1), (1.22, -1.78, 0.14)].enumerated() where k > CGFloat(i) * 0.25 {
                light.addPath(ellipse(c + V(facing * r * dx, r * dy), r * size, r * size))
            }
            line.addPath(light)
        case "search" where costume.isCorgi:
            // nose to the ground, sniffing: little puffs drifting off the nose, a short pull of breath at a time
            let m = mouthAt
            for i in 0..<3 {
                let k = (t * 2.2 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let p = m + V(facing * r * (0.95 + k * 0.6), -r * (0.02 + k * 0.3))
                let puff = ellipse(p, r * (0.05 + k * 0.07), r * (0.05 + k * 0.07))
                light.addPath(puff)
                line.addPath(puff)
            }
            if actBeat > 0.45 { actBeat = 0; kick(12) }
        case "search":
            // a magnifying glass, held out and swept slowly back and forth
            let hold = tip ?? (actHold() ?? c)
            let lens = hold + V(facing * r * 0.2, -r * 0.44)
            // a rim, clear glass and a glint on it
            line.addPath(ellipse(lens, r * 0.36, r * 0.36))
            line.addPath(ellipse(lens, r * 0.31, r * 0.31))
            let glint = CGMutablePath()
            glint.addArc(center: L(lens), radius: r * 0.2, startAngle: 2.2, endAngle: 2.9, clockwise: false)
            light.addPath(glint.copy(strokingWithWidth: max(1, r * 0.06), lineCap: .round, lineJoin: .round, miterLimit: 1))
            line.move(to: L(hold))
            line.addLine(to: L(lens + (hold - lens).unit * (r * 0.36)))
        case "run" where costume.isCorgi:
            // digging: white front paws scrabbling at the ground in front, earth flying out behind
            let ground = c + V(facing * r * 0.95, r * 1.35)
            for i in 0..<2 {
                let k = sin(t * 18 + CGFloat(i) * .pi)
                let paw = ellipse(ground + V(facing * r * (0.05 + 0.2 * k), -r * 0.08 * CGFloat(i) - max(0, k) * r * 0.12), r * 0.16, r * 0.12)
                light.addPath(paw)
                line.addPath(paw)
            }
            if actBeat > 0.2 { actBeat = 0; spray(at: c + V(-facing * r * 0.6, r * 1.3), 2, speed: 170, along: V(-facing, -1.3).unit) }
        case "run":
            // typing on a little keyboard in front of it, two tips tapping away
            let deck = c + V(facing * r * 0.1, r * 1.3)
            let q = L(deck)
            let board = CGPath(roundedRect: CGRect(x: q.x - r * 0.68, y: q.y - r * 0.17, width: r * 1.36, height: r * 0.34), cornerWidth: r * 0.08, cornerHeight: r * 0.08, transform: nil)
            light.addPath(board)
            line.addPath(board)
            for row in 0..<2 { for col in 0..<5 {
                ink.addPath(ellipse(deck + V(r * (-0.48 + 0.24 * CGFloat(col)), r * (-0.06 + 0.13 * CGFloat(row))), r * 0.06, r * 0.025))
            } }
            for i in 0..<2 {
                let lift = max(0, sin(t * 17 + CGFloat(i) * .pi)) * r * 0.2
                ink.addPath(ellipse(deck + V(r * (i == 0 ? -0.24 : 0.26), -r * 0.12 - lift), r * 0.11, r * 0.09))
            }
        case "answer", "write", "file":
            // a quill: nib on the line, feather up and out, the hand writing small loops
            let nib = tip ?? (actHold() ?? c)
            let top = nib + V(facing * r * 0.55, -r * 1.0)
            let across = (top - nib).unit.normal * (r * 0.32)
            let feather = CGMutablePath()
            feather.move(to: L(nib))
            feather.addQuadCurve(to: L(top), control: L(mix(nib, top, 0.5) + across))
            feather.addQuadCurve(to: L(nib + (top - nib) * 0.12), control: L(mix(nib, top, 0.55) - across * 0.8))
            feather.closeSubpath()
            light.addPath(feather)
            line.addPath(feather)
            line.move(to: L(nib))
            line.addLine(to: L(mix(nib, top, 0.8)))
        case "listen":
            // notes drifting up from the side, and on plain goo, headphones
            for i in 0..<2 {
                let k = (t * 0.45 + CGFloat(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let p = c + V(facing * r * (1.05 + 0.25 * sin(k * 6)), r * (0.1 - 1.4 * k))
                ink.addPath(ellipse(p, r * 0.1, r * 0.075))
                line.move(to: L(p + V(r * 0.09, 0)))
                line.addLine(to: L(p + V(r * 0.09, -r * 0.34)))
                line.addQuadCurve(to: L(p + V(r * 0.24, -r * 0.18)), control: L(p + V(r * 0.22, -r * 0.3)))
            }
            guard !costume.isCorgi && !costume.isWhale else { break }
            let band = CGMutablePath()
            band.move(to: L(c + V(-r * 0.92, -r * 0.1)))
            band.addCurve(to: L(c + V(r * 0.92, -r * 0.1)), control1: L(c + V(-r * 0.95, -r * 1.45)), control2: L(c + V(r * 0.95, -r * 1.45)))
            line.addPath(band)
            for side in [CGFloat(-1), 1] { ink.addPath(ellipse(c + V(side * r * 0.95, -r * 0.05), r * 0.2, r * 0.3)) }
        case "trouble":
            // a bead of sweat, sliding down
            let k = (t * 0.7).truncatingRemainder(dividingBy: 1)
            let p = c + V(facing * r * 0.85, -r * 0.75 + k * r * 0.5)
            let drop = CGMutablePath()
            drop.move(to: L(p + V(0, -r * 0.2)))
            drop.addQuadCurve(to: L(p + V(r * 0.1, r * 0.04)), control: L(p + V(r * 0.1, -r * 0.06)))
            drop.addArc(center: L(p + V(0, r * 0.04)), radius: r * 0.1, startAngle: 0, endAngle: .pi, clockwise: true)
            drop.addQuadCurve(to: L(p + V(0, -r * 0.2)), control: L(p + V(-r * 0.1, -r * 0.06)))
            light.addPath(drop)
            line.addPath(drop)
        case "wait" where costume.isCorgi:
            // sitting up and begging, both front paws going
            for side in [CGFloat(-1), 1] {
                let bob = max(0, sin(t * 7 + (side > 0 ? 0 : 0.6))) * r * 0.14
                let paw = ellipse(c + V(side * r * 0.3, r * 0.62 - bob), r * 0.17, r * 0.14)
                light.addPath(paw)
                line.addPath(paw)
            }
        default: break
        }
    }
}
