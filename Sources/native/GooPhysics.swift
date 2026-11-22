// How the goo moves: the body, its strands on the window, its bits of ink.
import AppKit

extension Goo {
    // MARK: physics

    func step(_ dt: CGFloat) {
        clock += Double(dt)
        let tapeGoal: CGFloat = silenced ? 1 : 0
        tapeVelocity += ((tapeGoal - tapeAmount) * 150 - tapeVelocity * 19) * dt
        tapeAmount = clamp(tapeAmount + tapeVelocity * dt, 0, 1.12)

        let m = host.mouse()
        mouseSpeed = mouseSpeed * 0.9 + ((m - lastMouse) * (1 / dt)) * 0.1
        if (m - lastMouse).length > 0.01 { lastMoved = clock }
        lastMouse = m
        mouseAt = m
        updateIdleScenes(m)
        updateMoods(m, dt)

        // where the window is, and whether we are close enough to grab it
        let held = candidateID
        candidate = nil
        candidateID = nil
        if mode == .grabbed, !stuck.contains(true), let near = host.windowNear(c, keeping: held) {
            candidate = near.frame.maxX
            candidateID = near.id
        }
        // Coming into reach of an edge: it notices, a little start and a look, and keeps its eyes on it while it is carried there.
        if let edge = candidate {
            if held == nil { kick(34) }
            lookAt = V(edge > c.x ? 1 : -1, 0.08)
            lookTime = max(lookTime, 0.12)
        }
        let window = candidateID.flatMap { id in host.platforms.first { $0.id == id }?.frame } ?? host.target?.frame

        let holdingStill = handOffering && mode != .grabbed
        if mode == .grabbed { dockDestination = nil }
        if holdingStill {
            v = V()
            if let from = handDeparture, let destination = handHome {
                // Get there with the hand tucked away. Floor collisions must not pull against this move.
                let t = clamp(CGFloat((clock - handAt) / 0.55), 0, 1)
                c = mix(from, destination, t * t * (3 - 2 * t))
                if t == 1 { handDeparture = nil; handAt = clock }
            }
        } else if let destination = handHome, mode != .grabbed {
            standingID = nil; settled = false
            spring(to: destination, k: 70, damping: 16, dt)
        } else if let destination = dockDestination, mode == .free {
            standingID = nil; settled = false
            spring(to: destination, k: 35, damping: 12, dt)
            if (c - destination).length < 3 && v.length < 15 { dockDestination = nil }
        } else if let seat, mode == .free {
            // At the open desktop panel's corner, off the ground altogether: never `settled` (that is standing on the floor,
            // and the legs, its shadow and the resting limb all reach down to `surface`). It lets go first, a
            // puddle gathered up, asleep woken, a walk or a peek dropped, then goes over whole, no faster than it can carry its skin.
            standingID = nil; wanderTo = nil; peekSide = 0; zoomUntil = 0; settled = false
            puddle = false   // gathered up quietly where it lies: no hop or kick on the way to the panel
            splatUntil = 0
            if sleeping { wake(startled: false) }
            // Gathered up and its limb in before it leaves (at most 0.4 s, so nothing held can keep it from going).
            if (splatAmount > 0.15 || armOut > radius * 1.5) && clock - seatAsked < 0.4 {
                v = v * pow(0.02, dt)
            } else {
                spring(to: seat, k: 300, damping: 26, dt)
                if v.length > Goo.seatSpeed { v = v.unit * Goo.seatSpeed }
            }
        } else { switch mode {
        case .attached:
            if let l = leap {
                flyLeap(l, dt)
            } else if let w = window {
                // On a window that fills the screen there is nothing to its right: it holds on from just inside.
                home = V(min(w.maxX + radius + 7, visible.maxX - radius - 4), min(w.minY + 66 + radius, w.maxY - radius))
                if let l = latch {
                    // Just set down: it holds where it touched while the strands take hold, then slides along the edge to its place and settles a touch past it.
                    let t = clamp(CGFloat((clock - l.start - Goo.latchHold) / Goo.latchSlide), 0, 1)
                    let p = mix(l.from, home, easeOutBack(t))
                    v = (p - c) * (1 / dt)
                    if t >= 1 { latch = nil; kick(26) }
                } else {
                    settle(in: w, k: 240, damping: 21, dt)
                }
            }
        case .open:
            if let w = window {
                home = V(host.sideX + 27, w.minY + host.barHeight / 2)
                settle(in: w, k: 300, damping: 26, dt)
            }
        case .grabbed:
            perch = nil
            hop = nil
            var goal = m + grabOffset
            if !grabMoved && (m - grabStart).length > 4 {
                grabMoved = true
                // Dragged off with its panel open: the panel goes, as before; the desktop's too, and if the body is set on a
                // window it opens again there as that window's (`stick`).
                if wasSeated { host.reopenOnStick = true; seat = nil }
                if wasOpen || wasSeated { host.closeSide() }
            }
            if let edge = candidate {
                // Near an edge it leans towards its place there, a little more the closer it gets, so letting go feels like it was pulled in.
                let spot = edge + radius + 7
                goal.x += (spot - goal.x) * 0.2 * clamp(1 - abs(goal.x - spot) / 190, 0, 1)
            }
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
                v.x = (goal > c.x ? 1 : -1) * (zooming ? 330 : costume.isCorgi ? radius * 2.1 : 20)
                if costume.isCorgi {
                    // A corgi trots: quick steps, a bounce in each, looking where it goes, tongue out.
                    if !zooming && clock > nextStep {
                        nextStep = clock + 0.16
                        v.y = -(2 * 1700 * radius * 0.06).squareRoot()
                        settled = false
                    }
                    lookAt = V(goal > c.x ? 1 : -1, 0.15)
                    lookTime = max(lookTime, 0.15)
                }
                if zooming, abs(goal - c.x) < 14 {
                    let (lo, hi) = roamBounds()
                    wanderTo = clamp(c.x + CGFloat.random(in: 110...170) * (goal > c.x - 1 ? -1 : 1), lo, hi)
                    kick(40)
                } else if abs(goal - c.x) < 3 { wanderTo = nil; nextWander = clock + Double.random(in: 14...40) }
            } else {
                if wanderTo == nil { creep += (0 - creep) * min(1, dt * 3) }   // mid-step in the air it is still walking
                if settled && clock > nextWander && !sleeping && !dizzy {
                    let away = CGFloat.random(in: 40...150) * (Bool.random() ? 1 : -1)
                    let (lo, hi) = roamBounds()
                    wanderTo = clamp(c.x + away, lo, hi)
                }
            }
        }
        } // A hand-over travels without changing the job's attached window.
        let before = c
        gait += min(abs(v.x) * dt / (radius * 0.4) * .pi, CGFloat(dt) * 2 * .pi * 7)
        trot += ((trotting ? 1 : 0) - trot) * min(1, dt * 6)
        c = c + v * dt

        splatAmount += ((clock < splatUntil ? 1 : 0) - splatAmount) * min(1, dt * (clock < splatUntil ? 26 : 6))

        // what it can stand on: the top of a window, otherwise the bottom of the screen
        if !holdingStill { surface = visible.maxY }
        if !holdingStill && mode == .free && handHome == nil && seat == nil {
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
        if !holdingStill && mode == .free && seat == nil {
            if clock >= splatUntil && !puddle {
                if c.y > floor {
                    let hit = v.y
                    c.y = floor
                    if costume.isWhale { landsInWater(hit) }   // the whale girl comes down with a splash (Whale.swift)
                    if hit > 90 && !(trotting && hit < 400) {
                        v.y = -hit * 0.3
                        settled = false
                        kick(min(hit * 0.14, 130))
                        if hit > 420 { spray(at: V(c.x, surface - 2), 3, speed: hit * 0.2, along: V(0, -1)); pop = max(pop, 0.5) }
                        if hit > 1500 { makeDizzy(1.6, "hard landing") }
                    } else {
                        v.y = 0
                        if trotting && hit > 60 { kick(hit * 0.05) }   // each trotting step lands with a small give
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
        } else if !holdingStill {
            c.x = clamp(c.x, visible.minX + 2, visible.maxX - 2)
            c.y = clamp(c.y, visible.minY + 2, visible.maxY - 2)
        }

        // the skin: each point chases its place on the circle, tugged by its neighbours
        // While it slides out from over the window after being set down, the skin may cross the edge; only after that does the edge hold it.
        let edgeX = (mode == .attached && latch == nil || candidate != nil) ? (window?.maxX ?? -9999) : -9999
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

    /// The owner pressed to go to another window: it lets go here, arcs over and takes hold where it lands. Returns how long the flight takes.
    @discardableResult
    func leap(to id: Int, frame: CGRect) -> Double {
        let landing = Goo.landing(on: frame, radius: radius)
        let length = Double(clamp(0.3 + (landing - c).length / 2400, 0.34, 0.62))
        mode = .attached
        perch = nil
        hop = nil
        latch = nil
        for i in 0..<3 { stuck[i] = false }
        leap = (id, frame, c, clock, length)
        kick(34)
        squash(towards: V(0, 1), 90)  // crouches before it goes
        return length
    }

    static func landing(on frame: CGRect, radius: CGFloat) -> V {
        V(frame.maxX + radius + 7, min(frame.minY + 66 + radius, frame.maxY - radius))
    }

    func flyLeap(_ l: (id: Int, frame: CGRect, from: V, start: Double, length: Double), _ dt: CGFloat) {
        let landing = Goo.landing(on: l.frame, radius: radius)
        let t = clamp(CGFloat((clock - l.start) / l.length), 0, 1)
        if t >= 1 {
            leap = nil
            v = (landing - c) * (1 / dt)
            stick(to: l.frame.maxX, window: l.id)
            kick(46)
            squash(towards: V(-1, 0), 140)
            spray(at: landing + V(-radius, 0), 3, speed: 80, along: V(-1, 0))
            return
        }
        // Eased at both ends: it gathers itself, flies, and settles onto the glass rather than slamming into it.
        let e = t * t * (3 - 2 * t)
        let height = clamp((landing - l.from).length * 0.24, 28, 140)
        let p = mix(l.from, landing, e) - V(0, sin(e * .pi) * height)
        v = (p - c) * (1 / dt)
        lookAt = (landing - c).unit
        lookTime = max(lookTime, 0.1)
    }

    func beginHop(to place: V) {
        hop = (c, clock, Double(clamp(0.2 + (place - c).length / 1800, 0.26, 0.6)))
        kick(30)
    }

    func spring(to goal: V, k: CGFloat, damping: CGFloat, _ dt: CGFloat) {
        v = v + ((goal - c) * k - v * damping) * dt
    }

    func updateStrands(_ window: CGRect?, _ dt: CGFloat) {
        let offsets: [CGFloat] = [-0.42, 0, 0.42]   // gripping within the body's own height, so it looks no bigger stuck on than anywhere else
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
                if i == armStrand && (armWanted || armOut > 3) && mode == .attached && latch == nil { goal = 0 }
            } else if candidate != nil {
                // In reach of an edge: feelers stretch for it before you let go, further the closer it is, each a beat apart.
                let distance = abs(c.x - (window?.maxX ?? c.x))
                goal = clamp(1 - distance / 150, 0.3, 0.92) * (0.9 + 0.1 * sin(CGFloat(clock) * 5 + CGFloat(i) * 2))
            }
            reachV[i] += ((goal - reach[i]) * 210 - reachV[i] * 17) * dt
            reach[i] = clamp(reach[i] + reachV[i] * dt, 0, 1.08)
        }
    }

    func anchorY(_ i: Int, _ w: CGRect, _ offset: CGFloat) -> CGFloat {
        let base = min(w.minY + 66 + radius, w.maxY - radius)
        // Attached, the strands hold level with the body, so they slide up the edge with it after it is set down rather than jumping ahead.
        let reference = mode == .open ? base : mode == .attached && latch == nil ? base : c.y
        return clamp(reference + offset * radius + sin(CGFloat(clock) * 0.8 + CGFloat(i) * 2) * 1.2, w.minY + 4, w.maxY - 4)
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
        turn += (turnGoal - turn) * min(1, dt * 5)

        var look: V
        // the whale girl's looks are softened: no side-eye from the corners, she looks down a little instead
        let soft = costume.isWhale && costume.dressed > 0.5
        switch state {
        case "reading", "working": look = soft ? V(-0.5, 0.35 + sin(CGFloat(clock) * 2) * 0.15) : V(-1, sin(CGFloat(clock) * 2) * 0.4)
        case "thinking": look = V(sin(CGFloat(clock) * 2.4) * 0.7, -1)
        default:
            let toMouse = mouseAt - c
            look = toMouse.length > 6 ? toMouse.unit * min(1, toMouse.length / 90) : V()
        }
        if let goal = reachGoal, (goal - c).length > 2 { look = (goal - c).unit }  // eyes on what it is touching
        if let ear = earTo, reachGoal == nil, (ear - c).length > 2 { look = (ear - c).unit }  // eyes on the words it is hearing
        if mode == .grabbed && mouseSpeed.length > 90 { look = (mouseSpeed * -1).unit }
        if mode == .free && !settled { look = (v * 1).unit }
        if lookTime > 0 { look = lookAt } else if let scene = actLook() { look = scene }
        // caught: looks anywhere but at you
        if guilty { look = ((c - mouseAt).unit + V(0, -0.5)).unit }
        // close up it won't meet your eye for long: a side glance, then away
        if mode != .grabbed && hoverTime > 0.15 && hoverTime < 1 { look = soft ? V(0.25, 0.75) : V(sin(CGFloat(hoverTime) * 9) > 0 ? 1 : -1, 0.1) }   // she looks down, bashful
        // dizzy: the pupils go round and round
        if dizzy { look = V(cos(CGFloat(clock) * 11), sin(CGFloat(clock) * 11)) }
        if oops { look = V(-0.8, 0.5) }
        gazeGoal = look
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
        if (armOut > 6 && acting == nil) || clock < smirkUntil { wantHeavy = 0.36 }
        if puddle { wantHeavy = 0.42 }
        heavyGoal = wantHeavy; lidGoal = open
        heavy += (wantHeavy - heavy) * min(1, dt * 12)
        lid += (open - lid) * min(1, dt * 22)
    }
}

// MARK: how often it needs a frame

/// `still`: nothing moves on it but its breath (and asleep, its dreams), which Core Animation carries; `ambient`: only slow
/// things go on (the strands swaying on a window's edge, a held limb's ripple, her tail), a few frames a second do;
/// `looking`: only the eyes and lids are catching up; `busy`: anything else, every frame the display gives.
enum Pace: Equatable { case busy, looking, ambient(Double), still }

extension Goo {
    /// Something of its own may start: nothing held or being said, and the owner not to be disturbed (Attention). The display
    /// check behind that is made only here, when all else already allows it.
    var mayPlay: Bool { couldPlay && host.attention.allowsPlay }
    var couldPlay: Bool { !handOffering && !carrying && host.entrusted.items.isEmpty && !silenced && !host.speaking.active }

    var pace: Pace { paceWhy.0 }

    /// The pace and the first thing that set it (for TAKO_PACE_LOG).
    var paceWhy: (Pace, String) {
        if mode == .grabbed || candidate != nil || (!handOffering && (hop != nil || leap != nil || latch != nil || dockDestination != nil)) { return (.busy, "busy1") }
        if mode == .free && !settled && seat == nil && !handOffering { return (.busy, "busy2") }   // seated it is never settled: at rest there, `v` says it is still
        if v.length > 0.3 || state != "idle" || acting != nil || !idleScene.isEmpty || peekSide != 0 || puddle || wanderTo != nil { return (.busy, "busy3") }
        if clock < splatUntil || splatAmount > 0.002 || dizzy || happy || oops || guilty || zooming || clock < smirkUntil { return (.busy, "busy4") }
        if hoverTime > 0 || lookTime > 0 || tallTime > 0 || tall > 0.002 || pop > 0 { return (.busy, "busy5") }
        if !drops.isEmpty || !stains.isEmpty || !ink.isEmpty || reachGoal != nil || bubbleGoal != nil || earTo != nil || perch != nil { return (.busy, "busy6") }
        if !handPhase.isEmpty && (handPhase != "offer" || clock - handAt < 1.2) { return (.busy, "busy7") }
        if creep > 0.002 || trot > 0.002 || wiggle > 0.002 || abs(turn - turnGoal) > 0.002 { return (.busy, "busy8") }
        if abs(tapeVelocity) > 0.01 || abs(tapeAmount - (silenced ? 1 : 0)) > 0.002 { return (.busy, "busy9") }
        if armTipV.length > 2 || abs(armThickV) > 0.02 || reach.indices.contains(where: { abs(reachV[$0]) > 0.02 }) { return (.busy, "busy10") }
        if let held = handGoal, (held - armTip).length > 1.5 { return (.busy, "busy11") }
        if ring.indices.contains(where: { (ringV[$0] - v).length > 3 }) { return (.busy, "busy12") }
        if costume.busy(self) { return (.busy, "busy13") }
        if blink > 0 || abs(lid - lidGoal) > 0.01 || abs(heavy - heavyGoal) > 0.004 || (gaze - gazeGoal).length > 0.004
            || abs(lean - leanGoal) > 0.002 || slosh.length > 0.02 || sloshV.length > 0.2 { return (.looking, "looking") }
        if armOut > 3 && !rippling { return (.ambient(12), "ambient15") }                               // a held limb ripples along its length
        if mode == .attached || mode == .open || carrying || !handPhase.isEmpty { return (.ambient(3), "ambient17") }   // strands sway on the edge
        return (.still, "still")
    }

    /// When, on its own clock, the next thing it does by itself begins: a blink, a glance, a stroll, falling asleep, an ear
    /// twitching. Times already past are left out: whatever holds them back changes only by something happening.
    var nextEvent: Double? {
        var times: [Double] = []
        if !sleeping { times.append(nextBlink) }
        let idle = state == "idle" && armOut < 3
        if mode == .attached && idle && !guilty && couldPlay { times.append(nextAct) }
        if mode == .free && seat == nil && settled && !sleeping && !puddle {
            if idle && couldPlay && idleScene.isEmpty && peekSide == 0 && wanderTo == nil { times.append(nextAct) }
            if !dizzy && wanderTo == nil { times.append(nextWander) }
            if state == "idle" { times.append(lastMoved + 40) }
            if idleScene.isEmpty && !idleBlocked && peekSide == 0 { times.append(max(nextIdleScene, lastMoved + 3)) }
            let distance = (mouseAt - c).length
            if couldPlay && idleScene.isEmpty && handPhase.isEmpty && acting == nil && distance < 260 && distance > radius + 14 {
                times.append(max(lastMoved + 2.5, nextIdleScene - 4))
            }
        }
        if costume.isCorgi { times.append(clock + costume.nextTwitch) }
        return times.filter { $0 > clock + 0.001 }.min()
    }

    /// Time that passed while nothing moved: its clock and countdowns go on without stepping the body through it.
    func fastForward(_ seconds: Double) {
        guard seconds > 0 else { return }
        clock += seconds
        costume.nextTwitch -= seconds
        costume.lastClock = clock
        actLast = clock
    }
}
