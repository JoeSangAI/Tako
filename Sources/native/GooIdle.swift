// Small, infrequent bodily scenes. All marks are fixed local shapes, never screen content.
import AppKit
import QuartzCore

extension Goo {
    var idleBlocked: Bool {
        carrying || !handPhase.isEmpty || host.attention.quiet || host.entrusted.items.count > 0 ||
        state != "idle" || host.operating || host.sideOpen || host.speaking.active || bubbleGoal != nil || dockDestination != nil || seat != nil || mode != .free
    }

    func clearIdleEdgePath(_ side: CGFloat) -> Bool {
        let edge = side > 0 ? visible.maxX : visible.minX
        let corridor = CGRect(x: min(c.x, edge) - radius * 2, y: c.y - radius * 3,
                              width: abs(edge - c.x) + radius * 4, height: radius * 6)
        return !host.platforms.contains { $0.frame.intersects(corridor) }
    }

    func startIdleScene(_ kind: String) {
        idleScene = kind; idleAt = clock; idleTouched = false
        idleSide = c.x > visible.midX ? -1 : 1
        idleDoodleOrigin = c; sleeping = false; wanderTo = nil
        if kind == "peek" { startPeek(); idleScene = "" }
    }

    func stopIdleScene() {
        if let goal = idleGoal, reachGoal?.x == goal.x, reachGoal?.y == goal.y { reachGoal = nil }
        if idleScene == "doodle" { wanderTo = nil }
        idleGoal = nil; idleScene = ""
    }

    func updateIdleScenes(_ mouse: V) {
        if (carrying || host.attention.quiet) && peekSide != 0 { peekSide = 0; ducking = false }
        // A reminder always takes the hand back, including in the middle of a scene.
        if carrying || !host.entrusted.items.isEmpty || !handPhase.isEmpty || mode != .free {
            if !idleScene.isEmpty { stopIdleScene() }
            return
        }
        if state != "idle" || host.operating || host.sideOpen {
            if !idleScene.isEmpty { stopIdleScene() }
            return
        }
        if host.attention.quiet { if !idleScene.isEmpty { stopIdleScene() }; return }
        let age = clock - idleAt
        switch idleScene {
        case "highfive":
            let goal = c + V(idleSide * radius * 1.6, -radius * 0.9)
            idleGoal = goal; reachGoal = goal
            if !idleTouched && clock - lastMoved < 0.25 && (mouse - goal).length < radius * 0.65 {
                idleTouched = true; idleAt = clock; spray(at: goal, 7, speed: 110, along: V(idleSide, -1)); happyUntil = clock + 1.2; pop = 0.6
            }
            if idleTouched && clock - idleAt > 1.2 { stopIdleScene() }
            else if !idleTouched && age > 4 {
                idleGoal = c + V(-idleSide * radius * (0.55 + 0.12 * sin(CGFloat(age - 4) * 9)), -radius)
                reachGoal = idleGoal; oopsUntil = clock + 0.1
                if age > 5.6 { stopIdleScene() }
            }
        case "doodle":
            let p = idleDoodlePoints()
            if age < 2, p.count > 1 {
                let progress = CGFloat(age / 2) * CGFloat(p.count - 1)
                let i = min(p.count - 2, Int(progress))
                let point = mix(p[i], p[i + 1], progress - CGFloat(i))
                idleGoal = point; reachGoal = point
            }
            else if age > 2 && !idleTouched {
                idleTouched = true; wanderTo = c.x - idleSide * radius * 0.55; lookAt = V(idleSide, -0.4); lookTime = 1.6
                if idleShape % 2 == 0 { happyUntil = clock + 1.2 } else { oopsUntil = clock + 1.2 }
            }
            else if age > 4.8 { stopIdleScene() }
        default: break
        }
        guard idleScene.isEmpty, !idleBlocked, !sleeping, settled, !puddle, peekSide == 0,
              clock > nextIdleScene, clock - lastMoved > 3, host.attention.allowsPlay else { return }
        nextIdleScene = clock + Double.random(in: 90...150)
        // Do not draw over a visible window: scenes use only genuinely empty desktop space.
        let area = CGRect(x: c.x - radius * 5, y: c.y - radius * 5, width: radius * 10, height: radius * 10)
        guard !host.platforms.contains(where: { $0.frame.intersects(area) }) else { return }
        let choice = (lastIdleScene + 1) % 3
        lastIdleScene = choice
        if choice == 1 { idleShape = (idleShape + 1) % 4 }
        startIdleScene(["highfive", "doodle", "peek"][choice])
    }

    func idleDoodlePoints() -> [V] {
        let r = radius, origin = idleDoodleOrigin + V(idleSide * r * 2.2, -r * 1.1)
        let shape: [(CGFloat, CGFloat)]
        switch idleShape {
        case 0: shape = [(-1, 0), (0, -0.7), (1, 0), (0, 0.7), (-1, 0), (-1.4, -0.6), (-1, 0), (-1.4, 0.6)]
        case 1: shape = [(0, -1), (0.25, -0.25), (1, -0.2), (0.4, 0.2), (0.65, 0.9), (0, 0.45), (-0.65, 0.9), (-0.4, 0.2), (-1, -0.2), (-0.25, -0.25), (0, -1)]
        case 2: shape = [(-0.7, 0), (-0.5, -0.6), (0, -0.8), (0.6, -0.5), (0.7, 0.2), (0, 0.7), (-0.7, 0), (-0.25, 0), (0, 0.2), (0.3, 0)]
        default: shape = [(-0.8, 0), (-0.25, 0.65), (0.9, -0.8)]
        }
        return shape.map { origin + V($0.0 * r * 0.88, $0.1 * r * 0.88) }
    }

    func drawIdleScene() {
        let root = view.layer!
        // Nothing going on: the scene's layers are let go, so between scenes they cost the frame nothing.
        guard !idleScene.isEmpty else {
            if idleInk.superlayer != nil {
                for layer in sceneLayers { layer.path = nil; layer.removeFromSuperlayer() }
            }
            return
        }
        if idleInk.superlayer == nil {
            idleInk.fillColor = Goo.ink; idleLines.fillColor = nil; idleLines.strokeColor = Goo.ink; idleLines.lineCap = .round; idleLines.lineJoin = .round
            idleLight.fillColor = NSColor.white.cgColor
            // back in the same place among the layers each time: under the hand and the bubble's arm
            for layer in [idleInk, idleLines, idleLight] {
                if handArmEdge.superlayer === root { root.insertSublayer(layer, below: handArmEdge) } else { root.addSublayer(layer) }
            }
        }
        let fill = CGMutablePath(), line = CGMutablePath(), light = CGMutablePath(), age = CGFloat(clock - idleAt), r = radius
        idleInk.opacity = 1; idleLines.opacity = 1; idleLight.opacity = 1
        idleLight.fillColor = (costume.isWhale && idleScene == "doodle" ? NSColor.systemTeal.withAlphaComponent(0.65) : NSColor.white).cgColor
        switch idleScene {
        case "doodle":
            let points = idleDoodlePoints(), progress = clamp(age / 2, 0, 1) * CGFloat(max(0, points.count - 1))
            let count = min(points.count, Int(progress) + 1)
            if let first = points.first {
                line.move(to: L(first)); for (i, p) in points.prefix(count).dropFirst().enumerated() {
                    line.addLine(to: L(p))
                    if !costume.isWhale { fill.addPath(ellipse(p, r * (i % 2 == 0 ? 0.045 : 0.065), r * 0.05)) }
                }
                if count < points.count { line.addLine(to: L(mix(points[count - 1], points[count], progress - CGFloat(count - 1)))) }
                if progress >= CGFloat(points.count - 1) * 0.8 {
                    let origin = idleDoodleOrigin + V(idleSide * r * 2.2, -r * 1.1)
                    if idleShape == 0 { fill.addPath(ellipse(origin + V(r * 0.32, -r * 0.08), r * 0.075, r * 0.075)) }
                    if idleShape == 2 {
                        fill.addPath(ellipse(origin + V(-r * 0.24, -r * 0.18), r * 0.07, r * 0.09))
                        fill.addPath(ellipse(origin + V(r * 0.24, -r * 0.18), r * 0.07, r * 0.09))
                    }
                }
                if costume.isWhale && age < 2 {
                    let pen = points[min(count - 1, points.count - 1)]
                    for i in 0..<3 { light.addPath(ellipse(pen + V(CGFloat(i - 1) * r * 0.18, -r * (0.18 + CGFloat(i) * 0.11)), r * 0.08, r * 0.11)) }
                }
            }
            idleLines.opacity = Float(clamp((4.8 - age) / 1.5, 0, 1))
        default: break
        }
        if idleScene == "highfive" && idleTouched && age < 0.9 {
            let center = c + V(idleSide * r * 1.6, -r * 0.9)
            for i in 0..<7 {
                let angle = CGFloat(i) * 2.39996, distance = r * (0.25 + min(age, 0.7) * 1.3)
                let spot = center + V(cos(angle) * distance, sin(angle) * distance)
                fill.addPath(ellipse(spot, r * 0.075, r * 0.075))
            }
        }
        let waterDrawing = costume.isWhale && idleScene == "doodle"
        idleInk.fillColor = (waterDrawing ? NSColor.systemBlue : NSColor(cgColor: Goo.ink) ?? .black).cgColor
        idleLines.strokeColor = (waterDrawing ? NSColor.systemBlue : NSColor(cgColor: Goo.ink) ?? .black).cgColor
        idleLines.lineWidth = max(1.0, r * 0.11); idleInk.path = fill; idleLines.path = line; idleLight.path = light
    }

    var sceneLayers: [CAShapeLayer] { [idleInk, idleLines, idleLight] }
}
