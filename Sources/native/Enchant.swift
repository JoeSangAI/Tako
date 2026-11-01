// The ink around the window it is stuck to. Other apps' windows can't be changed, so this is a
// click-through panel above the window: an inked edge that spreads from where it grabbed on, a
// moment of jelly made from the window's real picture, a runner along the edge while it works,
// and hand-drawn circles when it points at something. Only ever outside the window, or brief.
import AppKit
import CoreImage
import QuartzCore
import ScreenCaptureKit

final class Enchant {
    unowned let host: Controller
    let panel: SideWindow
    let root = CALayer()
    let band = CAShapeLayer()      // the inked edge, with its uneven width and drips
    let wipe = CAShapeLayer()      // reveals and takes away the band along the edge
    let runner = CAShapeLayer()    // what runs along it while it reads or works
    let jelly = CALayer()
    let circles = CALayer()
    var edge: CGPath?              // the edge as one line, starting opposite where it grabbed on
    var startFraction: CGFloat = 0.5
    var contact = V()
    var shown = CGRect.null        // the rect the band was made for, in screen coordinates
    var jellyAt: CFTimeInterval = 0, jellyCentre = CGPoint.zero, jellyRadius: CGFloat = 400
    var mood = "idle"
    var seed = UInt64.random(in: 1...99_999)
    let margin: CGFloat = 16

    init(host: Controller) {
        self.host = host
        panel = SideWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer = root
        root.isOpaque = false
        panel.contentView = view
        for layer in [band, runner] {
            layer.fillColor = nil
            root.addSublayer(layer)
        }
        band.fillColor = ink
        band.mask = wipe
        wipe.fillColor = nil
        wipe.strokeColor = NSColor.black.cgColor
        wipe.lineWidth = margin * 3
        wipe.lineCap = .butt
        runner.strokeColor = ink
        runner.lineWidth = 2.6
        runner.lineCap = .round
        runner.opacity = 0
        jelly.isHidden = true
        jelly.contentsGravity = .resize
        root.insertSublayer(jelly, at: 0)
        root.addSublayer(circles)
    }

    var ink: CGColor { NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1).cgColor }
    var inkOnWindow: CGColor { host.goo?.onDark == true ? NSColor(white: 0.93, alpha: 1).cgColor : ink }

    /// The screen rect the ink goes around: the window, and the side window once it is welded on.
    func outline() -> CGRect? {
        guard var frame = host.target?.frame else { return nil }
        if host.sideOpen && host.cardWidth > 0 {
            frame = frame.union(CGRect(x: host.sideX, y: frame.minY, width: host.cardWidth, height: frame.height))
        }
        return frame
    }

    /// Follows the window. Rebuilding the shape only when its size changes keeps dragging cheap.
    func sync() {
        // Grabbed still counts: a click on the goo closes the panel while it is held, and the ink has to come back in.
        guard let frame = outline(), let primary = NSScreen.screens.first, host.goo.mode != .free else { return }
        let outer = frame.insetBy(dx: -margin, dy: -margin)
        let ns = NSRect(x: outer.minX, y: primary.frame.maxY - outer.maxY, width: outer.width, height: outer.height)
        if panel.frame != ns { panel.setFrame(ns, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: outer.size)
        band.frame = root.bounds
        wipe.frame = band.bounds
        runner.frame = root.bounds
        circles.frame = root.bounds
        if frame.size != shown.size { rebuild(frame) }
        CATransaction.commit()
        shown = frame
    }

    func local(_ p: V) -> CGPoint {
        guard let frame = outline() else { return .zero }
        return CGPoint(x: p.x - frame.minX + margin, y: frame.maxY - p.y + margin)
    }

    /// One line around the window, walking from the middle of the far side, so the ink can spread both ways from the grip.
    func rebuild(_ frame: CGRect) {
        let w = frame.width, h = frame.height, r: CGFloat = 11, m = margin
        let inset: CGFloat = 0.5
        let rect = CGRect(x: m - inset, y: m - inset, width: w + inset * 2, height: h + inset * 2)
        let line = CGMutablePath()
        // In layer coordinates (y up). Start on the left edge, go up and around clockwise.
        let startY = clamp(frame.maxY - contact.y + m, rect.minY + r, rect.maxY - r)
        line.move(to: CGPoint(x: rect.minX, y: startY))
        line.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        line.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        line.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        line.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        line.addLine(to: CGPoint(x: rect.minX, y: startY))
        edge = line
        // How far along the line the grip is: up the near side, across the top, down to the same height.
        startFraction = (2 * (rect.maxY - startY) + rect.width) / (2 * (rect.width + rect.height))
        wipe.path = line
        runner.path = line
        band.path = inkedBand(rect: rect, radius: r)
    }

    /// The edge as a filled shape: uneven like a brush line, thick by the grip, with a few drips hanging off the bottom.
    func inkedBand(rect: CGRect, radius r: CGFloat) -> CGPath {
        var random = SeededRandom(seed: seed)
        let perimeter = 2 * (rect.width + rect.height)
        let count = max(120, Int(perimeter / 7))
        let phase = (CGFloat(random.next()) * 6.28, CGFloat(random.next()) * 6.28)
        var drips: [(x: CGFloat, width: CGFloat, length: CGFloat)] = []
        for _ in 0..<max(3, Int(rect.width / 260)) {
            drips.append((rect.minX + r + CGFloat(random.next()) * (rect.width - 2 * r), 7 + CGFloat(random.next()) * 7, 3 + CGFloat(random.next()) * 9))
        }
        let grip = local(contact)
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count)
            let (p, n) = pointOnRoundedRect(rect, radius: r, at: t)
            var width = 1.15 + 0.5 * sin(t * 37 + phase.0) * sin(t * 11 + phase.1) + 0.3 * sin(t * 89 + phase.1)
            let toGrip = hypot(p.x - grip.x, p.y - grip.y)
            width += 4.5 * exp(-(toGrip * toGrip) / (70 * 70))
            if n.y < -0.5 {
                for drip in drips {
                    let dx = (p.x - drip.x) / drip.width
                    width += drip.length * exp(-dx * dx * 2.2)
                }
            }
            width = max(0.55, width)
            outer.append(CGPoint(x: p.x + n.x * width, y: p.y + n.y * width))
            inner.append(p)
        }
        let path = CGMutablePath()
        path.addLines(between: outer)
        path.closeSubpath()
        path.addLines(between: inner.reversed())
        path.closeSubpath()
        return path
    }

    /// t runs clockwise from the top-left corner's end; returns the point and the outward normal.
    func pointOnRoundedRect(_ rect: CGRect, radius r: CGFloat, at t: CGFloat) -> (CGPoint, CGPoint) {
        let w = rect.width - 2 * r, h = rect.height - 2 * r, arc = .pi / 2 * r
        var d = t * (2 * w + 2 * h + 4 * arc)
        // top (y is up in layers)
        if d < w { return (CGPoint(x: rect.minX + r + d, y: rect.maxY), CGPoint(x: 0, y: 1)) }
        d -= w
        func corner(_ cx: CGFloat, _ cy: CGFloat, _ from: CGFloat) -> (CGPoint, CGPoint) {
            let a = from - d / r
            return (CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r), CGPoint(x: cos(a), y: sin(a)))
        }
        if d < arc { return corner(rect.maxX - r, rect.maxY - r, .pi / 2) }
        d -= arc
        if d < h { return (CGPoint(x: rect.maxX, y: rect.maxY - r - d), CGPoint(x: 1, y: 0)) }
        d -= h
        if d < arc { return corner(rect.maxX - r, rect.minY + r, 0) }
        d -= arc
        if d < w { return (CGPoint(x: rect.maxX - r - d, y: rect.minY), CGPoint(x: 0, y: -1)) }
        d -= w
        if d < arc { return corner(rect.minX + r, rect.minY + r, -.pi / 2) }
        d -= arc
        if d < h { return (CGPoint(x: rect.minX, y: rect.minY + r + d), CGPoint(x: -1, y: 0)) }
        d -= h
        return corner(rect.minX + r, rect.maxY - r, .pi)
    }

    // MARK: what happens to the window

    /// Grabbed on: the window shudders once like jelly, and ink spreads round it from the grip.
    func attach(contact point: V?) {
        // No point given: it found its way back to a window, without any ceremony.
        let ceremony = point != nil
        if let point { contact = point }
        if ceremony { seed = UInt64.random(in: 1...99_999) }
        shown = .null
        host.placeSide()
        sync()
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFront(nil) }
        if let id = host.target?.id { panel.order(.above, relativeTo: host.sideOpen ? host.side.windowNumber : id) }
        host.gooPanel.order(.above, relativeTo: panel.windowNumber)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.fillColor = inkOnWindow
        band.opacity = 1
        wipe.removeAllAnimations()
        wipe.strokeStart = 0
        wipe.strokeEnd = 1
        runner.opacity = 0
        CATransaction.commit()
        if ceremony {
            spread(duration: 0.75)
            shudder()
            host.goo.spray(at: host.goo.c, 5, speed: 170, along: V(1, -0.2))
        }
        setMood(mood)
    }

    func spread(duration: CFTimeInterval) {
        for (key, from, to) in [("strokeStart", startFraction, 0.0), ("strokeEnd", startFraction, 1.0)] as [(String, CGFloat, CGFloat)] {
            let grow = CABasicAnimation(keyPath: key)
            grow.fromValue = from
            grow.toValue = to
            grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
            wipe.add(grow, forKey: key)
        }
        wipe.strokeStart = 0
        wipe.strokeEnd = 1
    }

    /// Pulled off: the ink runs back to the grip and snaps.
    func peel(at point: V) {
        guard panel.isVisible else { return }
        setMood("idle")
        for (key, from, to) in [("strokeStart", 0.0, startFraction), ("strokeEnd", 1.0, startFraction)] as [(String, CGFloat, CGFloat)] {
            let back = CABasicAnimation(keyPath: key)
            back.fromValue = from
            back.toValue = to
            back.duration = 0.32
            back.timingFunction = CAMediaTimingFunction(name: .easeIn)
            back.fillMode = .forwards
            back.isRemovedOnCompletion = false
            wipe.add(back, forKey: key)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.host.goo.mode == .free || self.host.goo.mode == .grabbed else { return }
            self.wipe.removeAllAnimations()
            self.hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        circles.sublayers?.removeAll()
        jelly.isHidden = true
        shown = .null
    }

    /// A moment of jelly: the window's real picture, rippling out from the grip, then gone.
    func shudder() {
        guard CGPreflightScreenCaptureAccess(), let id = host.target?.id, let frame = host.target?.frame else { return }
        let grip = contact
        Task.detached { [weak self] in
            guard let image = await Hands.capture(windowID: id, size: frame.size, scale: 1) else { return }
            await MainActor.run {
                guard let self, self.host.target?.id == id else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.jelly.contents = image
                self.jelly.frame = CGRect(x: frame.minX - (self.outline()?.minX ?? frame.minX) + self.margin, y: self.margin, width: frame.width, height: frame.height)
                self.jelly.isHidden = false
                let localGrip = CGPoint(x: frame.width - 2, y: frame.maxY - grip.y)
                self.jellyCentre = localGrip
                self.jellyRadius = max(frame.width, frame.height) * 0.42
                CATransaction.commit()
                self.jellyAt = CACurrentMediaTime()
            }
        }
    }

    /// Runs every frame, but does work only during the jelly.
    func step(_ dt: CGFloat) {
        guard jellyAt > 0 else { return }
        let t = CGFloat(CACurrentMediaTime() - jellyAt), length: CGFloat = 0.85
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if t >= length {
            jellyAt = 0
            jelly.filters = nil
            jelly.isHidden = true
            jelly.contents = nil
        } else {
            let ripple = -0.24 * exp(-t * 5.2) * cos(t * 17)
            let scale = jelly.contentsScale
            let filter = CIFilter(name: "CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: jellyCentre.x * scale, y: jellyCentre.y * scale),
                kCIInputRadiusKey: (jellyRadius + t * jellyRadius * 1.2) * scale,
                kCIInputScaleKey: ripple])
            jelly.filters = filter.map { [$0] }
        }
        CATransaction.commit()
    }

    /// While it reads or works, something runs along the edge. Done by Core Animation, so it costs nothing here.
    func setMood(_ next: String) {
        mood = next
        runner.removeAnimation(forKey: "start")
        runner.removeAnimation(forKey: "end")
        guard next == "reading" || next == "thinking" || next == "working", panel.isVisible else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = runner.presentation()?.opacity ?? runner.opacity
            fade.toValue = 0
            fade.duration = 0.3
            runner.add(fade, forKey: "fade")
            runner.opacity = 0
            return
        }
        runner.strokeColor = inkOnWindow
        runner.opacity = 1
        runner.lineWidth = next == "working" ? 2.8 : 2.2
        let period: CFTimeInterval = next == "working" ? 2.2 : next == "thinking" ? 3.4 : 5
        let tail: CGFloat = next == "working" ? 0.16 : 0.09
        for (key, name, offset) in [("strokeEnd", "end", tail), ("strokeStart", "start", 0)] as [(String, String, CGFloat)] {
            let run = CABasicAnimation(keyPath: key)
            run.fromValue = offset - tail
            run.toValue = 1 + offset
            run.duration = period
            run.repeatCount = .infinity
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            runner.add(run, forKey: name)
        }
    }

    /// A hand-drawn ring around something on the window. It stays a few seconds and fades.
    func circle(_ rect: CGRect) {
        guard panel.isVisible else { return }
        sync()
        let a = local(V(rect.minX, rect.minY)), b = local(V(rect.maxX, rect.maxY))
        let centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let rx = abs(b.x - a.x) / 2 + 12, ry = abs(b.y - a.y) / 2 + 8
        let path = CGMutablePath()
        let wobble = CGFloat.random(in: 0...6.28)
        let steps = 90
        for i in 0...steps {
            // A little past one full turn, like a pen that doesn't quite close where it began.
            let t = CGFloat(i) / CGFloat(steps), angle = t * 2.13 * .pi + 2.4
            let grow = 1 + 0.05 * sin(t * 9 + wobble) + 0.06 * t
            let point = CGPoint(x: centre.x + cos(angle) * rx * grow, y: centre.y + sin(angle) * ry * grow)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let ring = CAShapeLayer()
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = inkOnWindow
        ring.lineWidth = 2.4
        ring.lineCap = .round
        ring.lineJoin = .round
        circles.addSublayer(ring)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.5
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(draw, forKey: "draw")
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak ring] in
            guard let ring else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.opacity = 0
            CATransaction.commit()
        }
    }
}

/// So that one window keeps the same brush marks while it is resized.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 2_654_435_761 &+ 1 }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 40) / Double(1 << 24)
    }
}
