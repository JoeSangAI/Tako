// What Tako wears: a small wardrobe that grows with every occasion. Each outfit has its days, when anyone who leaves the
// choice to Tako sees it wear it; from its first day on it stays in the menu to put on any time.
// The choice is the owner's, in the right-click menu: follow the occasions (the default), one outfit, or none.
// An outfit is worn, not stuck on: it is cut from the goo's own skin, moves with it and brings a few habits of its own.
// The corgi is after a real one, so it has that dog's looks and no tail: it wags its back end instead.
// The whale girl goes with a DeepSeek key (Wardrobe.swift, Whale.swift): her apron, tail and spout, taken from the drawing of her.
import AppKit
import QuartzCore

extension Outfit {
    /// Today where the owner lives: the zone in config.json, never the device's (it may be set elsewhere on purpose).
    static func today() -> DateComponents {
        var zone = TimeZone.current
        if let data = try? Data(contentsOf: takoHome.appendingPathComponent("config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = config["timezone"] as? String, let set = TimeZone(identifier: name) { zone = set }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day], from: Date())
    }
}

/// The outfit's layers and the little physics of its loose parts (ears, a hat's tip).
final class Costume {
    // behind the goo: what grows out of it, with its root hidden under the skin
    let ears = CAShapeLayer(), earsInner = CAShapeLayer()
    // the whale girl's apron, tail and spout: pieces cut from the drawing of her (Sources/art), hung on the goo
    let apronArt = CALayer(), tailArt = CALayer(), spoutArt = CALayer()
    // and, drawn like her: her legs and arms tucked in behind the head, the head's own fine dark outline
    let armsLine = CAShapeLayer(), headLine = CAShapeLayer()
    // her tentacles, back pair then front pair, each: the goo with its outline, the line round the inside of each curl,
    // a soft light along the top
    let tentacles = (0..<6).map { _ in CAShapeLayer() }
    static let whaleInk = NSColor(srgbRed: 0.106, green: 0.1, blue: 0.1, alpha: 1).cgColor, whaleLine = NSColor(white: 0.025, alpha: 1).cgColor
    var inked = false   // the goo is in her black just now
    // over the goo, under the face: a hood is shaded fur cut from the skin, a hat is a plain shape
    let hood = CAGradientLayer(), hoodMask = CAShapeLayer(), fur = CALayer(), furMask = CAShapeLayer()
    let cover = CAShapeLayer(), fold = CAShapeLayer(), stitch = CAShapeLayer(), trim = CAShapeLayer(), blush = CAShapeLayer()
    // over the face
    let tongue = CAShapeLayer(), tongueLine = CAShapeLayer()
    // the whale girl's open mouth and the tongue in it
    let mouthIn = CAShapeLayer(), mouthTongue = CAShapeLayer(), lip = CAShapeLayer()
    // in front of everything, the whale girl's: what she holds (under her hands), her hands when they are in use, and her
    // pictures in the air (water, a fish, twinkles, hearts), each frame from these pools
    let props = (0..<2).map { _ in CALayer() }, hands = CAShapeLayer(), handLight = CAShapeLayer(), sprites = (0..<18).map { _ in CALayer() }
    var handLights: [CGPath] = []
    var propsUsed = 0, spritesUsed = 0, handPaths: [CGPath] = []
    var layers: [CAShapeLayer] { [ears, earsInner, hoodMask, furMask, cover, fold, stitch, trim, blush, tongue, tongueLine, mouthIn, mouthTongue, lip, armsLine, headLine, hands, handLight] + tentacles }
    var furFor: CGFloat = 0   // the radius the fur pattern was made for
    var outfit: Outfit? { didSet { if outfit?.id != oldValue?.id { clear(); paint() } } }
    var onWear: ((Outfit) -> Void)?
    var checkedAt = -100.0, checkedOnce = false, lastClock = 0.0
    var ear: [CGFloat] = [0, 0], earV: [CGFloat] = [0, 0], earLen: [CGFloat] = [1, 1], nextTwitch = 3.0
    var sway: CGFloat = 0, swayV: CGFloat = 0, lastV = V()
    var pettedAt = -10.0
    var pinned = false   // set by hand (the showcase): the day does not change it
    var isCorgi: Bool { outfit?.id == "corgi" }
    var isWhale: Bool { outfit?.id == "whale" }
    // the whale girl's loose parts: her tail (how high, how hard it wags) and her water
    var tailLift: CGFloat = 0, tailLiftV: CGFloat = 0, wag: CGFloat = 0, wagPhase: CGFloat = 0, swishAt = -10.0
    var spoutAt = -10.0, spoutPower: CGFloat = 1, wasHappy = false, dressAt = -10.0
    // how far into her shape it is (0 plain Tako, 1 dressed), and the head as it is this frame: its middle and how far the
    // body is squashed across and down from her round head
    var dressed: CGFloat = 0, mid = V(), sx: CGFloat = 1, sy: CGFloat = 1
    var faceOwn = false   // this frame the face is hers, not one of Tako's own (startled, asleep…)
    var tailRoot: V?      // where her right leg is: the tail goes in behind it
    // her sea and her manners (Whale.swift): how far down she has gone or dips, the bubbles she breathes, the scene she was
    // in, how long the last job ran, her rare tricks, the splashes and hearts in the air, her curtsey
    var sink: CGFloat = 0, swim: CGFloat = 0
    // the fish gag (Whale.swift `fishBeat`): where it is, and what it does to her head
    var beat: Goo.FishBeat?, stretch = V(1, 1), lunge: CGFloat = 0, puff: CGFloat = 0, wobble: CGFloat = 0
    var bubbles: [(p: V, v: V, r: CGFloat, life: CGFloat, full: CGFloat)] = []
    var sputter: [(p: V, v: V, r: CGFloat, life: CGFloat)] = []
    var lastAct = "", busySince: Double?, busyLength = 0.0, busyEndedAt = -100.0
    var nextBubble = 0.0, nextDrip = 0.0, nextRare = 0.0, fishAt = -100.0, rainbowAt = -100.0, curtseyAt = -100.0, breaching = false, wasShy = false
    var splashes: [(p: V, start: Double, width: CGFloat)] = [], hearts: [(p: V, start: Double)] = []
    var drops: [(p: V, v: V, r: CGFloat, life: CGFloat)] = []

    func attach(behind goo: CALayer, over: CALayer) {
        guard let root = goo.superlayer else { return }
        for layer in [ears, earsInner] { root.insertSublayer(layer, below: goo) }
        // behind the goo, back to front: the tail (its root goes in under the arm and the leg), the legs, the arms
        for layer in [tailArt] + tentacles + [armsLine] { root.insertSublayer(layer, below: goo) }
        for layer in [blush, trim, stitch, fold, cover, fur, hood, apronArt, headLine] { root.insertSublayer(layer, above: over) }
        hood.mask = hoodMask
        fur.mask = furMask
        root.addSublayer(tongue)
        root.addSublayer(tongueLine)
        root.addSublayer(mouthIn)
        root.addSublayer(mouthTongue)
        root.addSublayer(lip)
        for layer in [spoutArt] + props + [hands, handLight] + sprites { root.addSublayer(layer) }
        handLight.fillColor = NSColor(white: 1, alpha: 0.3).cgColor   // the same soft light as on her tentacles
        for layer in props + sprites { layer.contentsGravity = .resize; layer.isHidden = true }
        hands.fillColor = Costume.whaleInk
        hands.lineJoin = .round
        for layer in [apronArt, tailArt, spoutArt] {
            layer.contentsGravity = .resize
            layer.isHidden = true
        }
        tailArt.shadowColor = NSColor.white.cgColor   // shown on dark windows only (Whale.swift)
        tailArt.shadowRadius = 0.7
        tailArt.shadowOffset = .zero
        tailArt.shadowOpacity = 0
        for layer in [ears, cover] { layer.lineJoin = .round }
        tongueLine.lineCap = .round
        tongueLine.fillColor = nil
        paint()
    }

    func paint() {
        guard let outfit else { return }
        let ink = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1).cgColor
        // fur lit from above: lighter on the crown, deeper where it wraps round the cheeks
        hood.colors = [outfit.primary.blended(withFraction: 0.14, of: NSColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 1))!.cgColor, outfit.primary.cgColor,
                       outfit.primary.blended(withFraction: 0.1, of: NSColor(srgbRed: 0.55, green: 0.25, blue: 0.08, alpha: 1))!.cgColor]
        hood.locations = [0, 0.45, 1]
        hood.startPoint = CGPoint(x: 0.5, y: 1)
        hood.endPoint = CGPoint(x: 0.5, y: 0)
        ears.fillColor = outfit.primary.cgColor
        ears.strokeColor = ink   // drawn in Tako's own ink, like the rest of its outline
        cover.fillColor = outfit.primary.cgColor
        cover.strokeColor = outfit.primary.blended(withFraction: 0.42, of: .black)?.cgColor
        cover.lineWidth = 0.8
        earsInner.fillColor = outfit.inner.cgColor
        fold.fillColor = outfit.primary.blended(withFraction: 0.3, of: .black)?.withAlphaComponent(0.55).cgColor
        trim.fillColor = outfit.light.cgColor
        stitch.fillColor = outfit.primary.blended(withFraction: 0.38, of: .black)?.withAlphaComponent(0.5).cgColor
        // a soft glow of pink, not a flat patch
        blush.fillColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.68, alpha: 0.75).cgColor
        blush.shadowColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.65, alpha: 1).cgColor
        blush.shadowOpacity = 0.9
        blush.shadowOffset = .zero
        tongue.fillColor = NSColor(srgbRed: 0.94, green: 0.46, blue: 0.54, alpha: 1).cgColor
        tongueLine.strokeColor = NSColor(srgbRed: 0.78, green: 0.3, blue: 0.39, alpha: 1).cgColor
        guard outfit.id == "whale" else { return }
        // The whale girl as Tako wears her, in the drawing's colours: pink blush strokes with a glow, a pink mouth and tongue,
        // and her fine dark outline (the apron, tail, spout and all her things are pictures, Sources/art).
        blush.fillColor = NSColor(srgbRed: 0.95, green: 0.6, blue: 0.59, alpha: 1).cgColor
        blush.shadowColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1).cgColor
        blush.shadowOpacity = 0.5
        trim.fillColor = NSColor(srgbRed: 0.95, green: 0.5, blue: 0.5, alpha: 0.05).cgColor
        mouthIn.fillColor = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.56, alpha: 1).cgColor
        mouthTongue.fillColor = NSColor(srgbRed: 0.97, green: 0.66, blue: 0.73, alpha: 1).cgColor
        for layer in [armsLine, tentacles[0], tentacles[3]] { layer.fillColor = Costume.whaleInk; layer.strokeColor = Costume.whaleLine; layer.lineJoin = .round }
        tentacles[0].fillColor = NSColor(srgbRed: 0.085, green: 0.08, blue: 0.08, alpha: 1).cgColor   // the pair behind a shade deeper
        for layer in [tentacles[1], tentacles[4]] { layer.fillColor = Costume.whaleLine }                              // the curl's inner line
        for layer in [tentacles[2], tentacles[5]] { layer.fillColor = NSColor(white: 1, alpha: 0.3).cgColor }   // light along the top
        for layer in [headLine, lip] { layer.fillColor = nil; layer.strokeColor = Costume.whaleLine; layer.lineCap = .round; layer.lineJoin = .round }
    }

    /// Once a minute (and at once after the menu): which outfit today. Putting one on is worth showing off; starting up is not.
    func check(_ clock: Double) {
        guard !pinned, clock - checkedAt > 60 || clock < checkedAt else { return }
        checkedAt = clock
        let before = outfit?.id
        outfit = Outfit.wearing(on: Outfit.today())
        if checkedOnce, let outfit, outfit.id != before { onWear?(outfit) }
        checkedOnce = true
    }

    func clear() {
        for layer in layers { layer.path = nil }
        for layer in [apronArt, tailArt, spoutArt] + props + sprites { layer.isHidden = true }
        drops = []
        splashes = []
        hearts = []
        bubbles = []
        sputter = []
        dressed = 0
        sink = 0
        beat = nil
        stretch = V(1, 1)
        lunge = 0
        puff = 0
    }

    /// One of the pieces cut from the drawing of the whale girl, shipped in the app's resources.
    static func art(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: "whale-\(name)", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The piece made once at the pixel width it is shown at, averaged down with care: shrunk on the fly a thin blue outline
    /// fades into what is next to it. Kept per size, and the size only changes with the goo's radius or the screen.
    static var sized: [String: CGImage] = [:], aspects: [String: CGFloat] = [:]
    /// A picture's height to its width.
    static func aspect(_ name: String) -> CGFloat {
        if let known = aspects[name] { return known }
        let image = art(name), known = image.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 1
        aspects[name] = known
        return known
    }
    func dress(_ layer: CALayer, _ name: String, points: CGFloat, scale: CGFloat) {
        let across = max(4, Int((points * scale).rounded())), key = "\(name)@\(across)"
        guard layer.name != key else { return }
        layer.name = key
        if Costume.sized[key] == nil, let source = Costume.art(name) {
            let tall = max(1, Int((CGFloat(source.height) * CGFloat(across) / CGFloat(source.width)).rounded()))
            if across < source.width, let context = CGContext(data: nil, width: across, height: tall, bitsPerComponent: 8, bytesPerRow: 0,
                                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: across, height: tall))
                Costume.sized[key] = context.makeImage()
            } else { Costume.sized[key] = source }
        }
        layer.contents = Costume.sized[key]
        layer.contentsScale = scale
    }

    /// Short plush fur, lying down the way it was brushed: a tile of fine light and dark strands, sized to the goo.
    func furPattern(_ r: CGFloat) {
        guard abs(furFor - r) > 0.5 else { return }
        furFor = r
        let side = max(24, r * 2.4)
        var random = SystemRandomNumberGenerator()
        let tile = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // velvety, not straw: many short fine strands, barely lighter or darker than the fur itself
            for _ in 0..<Int(side * side / 3) {
                let p = CGPoint(x: CGFloat.random(in: 0..<side, using: &random), y: CGFloat.random(in: 0..<side, using: &random))
                let a = CGFloat.random(in: -0.4...0.4, using: &random) - .pi / 2, length = CGFloat.random(in: 0.025...0.06, using: &random) * r
                let strand = NSBezierPath()
                strand.move(to: p)
                strand.line(to: CGPoint(x: p.x + cos(a) * length, y: p.y + sin(a) * length))
                strand.lineWidth = max(0.4, r * 0.014)
                strand.lineCapStyle = .round
                (Bool.random(using: &random) ? NSColor(srgbRed: 1, green: 0.95, blue: 0.85, alpha: 0.12) : NSColor(srgbRed: 0.45, green: 0.2, blue: 0.05, alpha: 0.07)).setStroke()
                strand.stroke()
            }
            return true
        }
        fur.backgroundColor = NSColor(patternImage: tile).cgColor
    }

    func spring(_ x: inout CGFloat, _ xv: inout CGFloat, to goal: CGFloat, k: CGFloat, damping: CGFloat, _ dt: CGFloat) {
        xv += ((goal - x) * k - xv * damping) * dt
        x += xv * dt
    }
}

func rotate(_ p: V, _ a: CGFloat) -> V { V(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a)) }

extension Goo {
    func drawCostume() {
        let k = costume
        k.check(clock)
        let dt = CGFloat(clamp(CGFloat(clock - k.lastClock), 0, 0.05))
        k.lastClock = clock
        let wagging = k.isCorgi && !sleeping && (happy || clock - k.pettedAt < 0.35)   // the whale girl has her tail for that
        wiggle += ((wagging ? 1 : trotting ? 0.7 : 0) - wiggle) * min(1, dt * 8)
        guard let outfit = k.outfit, let skin = body.path else { return k.clear() }
        switch outfit.id {
        case "corgi": drawCorgi(skin, dt)
        case "whale": drawWhale(skin, dt)
        default: drawSanta(dt)
        }
        k.lastV = v
    }

    /// Being stroked on the head (the cursor resting on it): a corgi melts, eyes shut, ears back, tongue out, its back end going;
    /// the whale girl shuts her eyes and spouts.
    func pet() {
        guard costume.isCorgi || costume.isWhale, !sleeping, mode != .grabbed, !dizzy else { return }
        costume.pettedAt = clock
        happyUntil = max(happyUntil, clock + 0.3)
    }

    /// A corgi hood after a real one: huge ears standing out to the sides, golden fur with a narrow white blaze,
    /// a fluffy cream edge round the face. Ears flop, perk and droop with its moods; when it is happy the tongue comes out.
    func drawCorgi(_ skin: CGPath, _ dt: CGFloat) {
        let k = costume, r = radius, ring = smoothedSkin(), n = Goo.count
        gloss.path = nil   // a shine belongs to wet goo, not to fur

        // ears
        let petted = clock - k.pettedAt < 0.35
        // What the ears say. Angles open outward and down from where they stand; length shortens as they press flat.
        var splay: CGFloat = lean > 0.12 ? -0.04 : 0.1             // out to the sides, pricked up when the cursor comes
        var length: CGFloat = 1
        let scared = guilty || !ink.isEmpty
        if sleeping { splay = 1.05 }                              // fallen down while it sleeps
        else if scared { splay = 1.15; length = 0.78 }            // caught, or frightened into inking: pressed flat back
        else if petted || mode == .grabbed || zooming { splay = 0.85 }  // laid back
        else if oops { splay = 0.8; length = 0.9 }                // down and sorry
        else if pop > 0.3 { splay = -0.1 }                        // surprised: straight up
        else if happy { splay = 0.3 + 0.28 * sin(t * 16) }        // pleased: flapping
        var flop: CGFloat = 0                                      // one ear only: the head-tilt "hm?"
        switch acting {
        case "think": flop = 0.55
        case "look", "read", "listen": splay = -0.05               // pricked, listening hard
        case "search": splay = 0.14
        case "trouble": splay = 0.95
        case "wait": splay = 0.5
        default: break
        }
        let lag = clamp(-v.x / 700, -0.7, 0.7) + (dizzy ? sin(CGFloat(clock) * 9) * 0.35 : 0)
        let jolt = dt > 0 ? (v.y - k.lastV.y) / dt : 0            // a hop or a landing flicks them out
        k.nextTwitch -= Double(dt)
        let twitch = k.nextTwitch < 0 ? Int.random(in: 0..<2) : -1   // asleep too: dreaming
        if twitch >= 0 { k.nextTwitch = sleeping ? Double.random(in: 3...8) : Double.random(in: 2.5...7) }
        let ink = max(0.8, r * 0.045)
        let path = CGMutablePath(), inner = CGMutablePath()
        for e in 0..<2 {
            let sideSign: CGFloat = e == 0 ? -1 : 1
            if abs(jolt) > 3000 { k.earV[e] += sideSign * min(abs(jolt), 30000) * 0.00012 }
            if e == twitch { k.earV[e] += sideSign * (sleeping ? -4 : 7) }
            // the ear on the cursor's side turns to it; listening, they swivel by turns like two little dishes
            var own: CGFloat = e == 1 ? flop : 0
            if lean > 0.12 && !scared && !sleeping && (mouseAt.x > c.x) == (e == 1) { own -= sideSign * 0.18 }
            if acting == "listen" { own += sideSign * 0.3 * sin(t * 2.2 + CGFloat(e) * .pi) }
            k.spring(&k.ear[e], &k.earV[e], to: sideSign * splay + lag + own, k: 240, damping: 10, dt)
            k.earLen[e] += (length - k.earLen[e]) * min(1, dt * 12)
            // set wide on the head, the way a corgi's are
            let at = ring[e == 0 ? n * 18 / 28 : n * 24 / 28]
            let root = mix(c, at, 0.72)
            let d = rotate((at - c).unit, k.ear[e]), across = d.normal
            let long = k.earLen[e]
            func E(_ along: CGFloat, _ side: CGFloat) -> CGPoint { L(root + d * (along * r * long) + across * (side * r * sideSign)) }
            // big and upright, plump at the root, the tip well rounded; the edge is soft with fur, not cut clean
            func cubic(_ a: V, _ b: V, _ c2: V, _ d2: V, _ s: CGFloat) -> V {
                let u = 1 - s
                return a * (u * u * u) + b * (3 * u * u * s) + c2 * (3 * u * s * s) + d2 * (s * s * s)
            }
            func P(_ along: CGFloat, _ side: CGFloat) -> V { root + d * (along * r * long) + across * (side * r * sideSign) }
            var edge: [V] = []
            for s in stride(from: CGFloat(0), through: 1, by: 1.0 / 14) { edge.append(cubic(P(0, -0.46), P(0.44, -0.5), P(0.9, -0.3), P(1.04, -0.08), s)) }
            for s in stride(from: CGFloat(1.0 / 8), through: 1, by: 1.0 / 8) { edge.append(cubic(P(1.04, -0.08), P(1.12, 0.02), P(1.08, 0.12), P(0.98, 0.16), s)) }
            for s in stride(from: CGFloat(1.0 / 14), through: 1, by: 1.0 / 14) { edge.append(cubic(P(0.98, 0.16), P(0.82, 0.38), P(0.4, 0.48), P(0, 0.42), s)) }
            let middle = P(0.5, 0)
            // a soft, slightly lumpy edge, smoothed through the midpoints so it never turns into teeth
            let soft = edge.enumerated().map { i, p in p + (p - middle).unit * (r * 0.012 * sin(CGFloat(i) * 1.3)) }
            path.move(to: L(mix(soft[soft.count - 1], soft[0], 0.5)))
            for i in 0..<soft.count { path.addQuadCurve(to: L(mix(soft[i], soft[(i + 1) % soft.count], 0.5)), control: L(soft[i])) }
            path.closeSubpath()
            // the inside: pink, set toward the inner edge, a soft point near the tip
            inner.move(to: E(0.22, -0.2))
            inner.addCurve(to: E(0.9, 0.0), control1: E(0.5, -0.24), control2: E(0.8, -0.1))
            inner.addCurve(to: E(0.24, 0.28), control1: E(0.8, 0.24), control2: E(0.46, 0.32))
            inner.closeSubpath()
        }
        k.ears.lineWidth = ink
        k.ears.path = path
        k.earsInner.path = inner

        // The hood, cut from the skin itself so it squashes and stretches with it: over the crown and down the sides,
        // thinning to nothing at the cheeks, the face left open. It stops just inside the skin, so Tako's own ink
        // runs round it as an outline.
        let middle = eye + V(0, r * 0.5), rx = r * 0.8, ry = r * 1.02
        let face = ellipse(middle, rx, ry)
        let within = skin.subtracting(skin.copy(strokingWithWidth: ink * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        let hood = within.subtracting(face)
        let box = skin.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        k.hood.frame = box
        var home = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        k.hoodMask.path = hood.copy(using: &home)
        k.furPattern(r)
        k.fur.frame = box
        k.furMask.path = k.hoodMask.path
        // heavy lids are goo: they stay inside the face, never over the fur
        if let lid = lidL.path { lidL.path = lid.intersection(face) }
        if let lid = lidR.path { lidR.path = lid.intersection(face) }

        // A cream ruff round the face, deepest over the brow and thinning down the cheeks; a fine shadow where it lies
        // on the fur; the narrow white blaze rising from it up the forehead.
        // the ruff's outer edge goes in and out a little, as fur does
        // Set higher than the face and only a little wider, the ruff is deepest over the brow and thins away down the
        // cheeks to nothing where the hood ends, so no loose sliver of it is left there.
        let ruffOut = CGMutablePath(), ruffMiddle = middle + V(0, -r * 0.09)
        var puffs: [V] = []
        for i in 0..<96 {
            // soft rounded puffs, about twenty round the face
            let a = CGFloat(i) / 96 * 2 * .pi, fluff = r * 0.018 * abs(sin(CGFloat(i) / 96 * .pi * 20))
            puffs.append(ruffMiddle + V(cos(a) * (rx + r * 0.05 + fluff), sin(a) * (ry + r * 0.06 + fluff)))
        }
        ruffOut.move(to: L(mix(puffs[95], puffs[0], 0.5)))
        for i in 0..<96 { ruffOut.addQuadCurve(to: L(mix(puffs[i], puffs[(i + 1) % 96], 0.5)), control: L(puffs[i])) }
        ruffOut.closeSubpath()
        let blaze = CGMutablePath()
        let top = eye + V(0, -r * 0.9), base = middle.y - ry - r * 0.06
        blaze.move(to: L(top + V(-r * 0.035, 0)))
        blaze.addQuadCurve(to: L(top + V(r * 0.035, 0)), control: L(top + V(0, -r * 0.04)))
        blaze.addCurve(to: L(V(eye.x + r * 0.14, base)), control1: L(top + V(r * 0.05, r * 0.12)), control2: L(V(eye.x + r * 0.07, base - r * 0.04)))
        blaze.addLine(to: L(V(eye.x - r * 0.14, base)))
        blaze.addCurve(to: L(top + V(-r * 0.035, 0)), control1: L(V(eye.x - r * 0.07, base - r * 0.04)), control2: L(top + V(-r * 0.05, r * 0.12)))
        blaze.closeSubpath()
        let ruff = ruffOut.subtracting(face).union(blaze).intersection(within)
        k.trim.path = ruff
        k.fold.path = ruffOut.copy(strokingWithWidth: max(0.6, r * 0.05), lineCap: .round, lineJoin: .round, miterLimit: 1).intersection(hood)
        // a row of stitches where the hood was sewn to its lining
        let seam = ellipse(ruffMiddle, rx + r * 0.19, ry + r * 0.2)
            .copy(dashingWithPhase: 0, lengths: [r * 0.07, r * 0.06])
            .copy(strokingWithWidth: max(0.5, r * 0.028), lineCap: .round, lineJoin: .round, miterLimit: 1)
        k.stitch.path = seam.intersection(hood)
        // and a rosy cheek on each side, the way a plush toy has them
        let cheeks = CGMutablePath()
        for side in [CGFloat(-1), 1] { cheeks.addPath(ellipse(mouthAt + V(side * r * 0.44, -r * 0.13), r * 0.11, r * 0.06)) }
        k.blush.shadowRadius = max(1, r * 0.07)
        k.blush.path = sleeping ? nil : cheeks

        // happy, on the move or hard at it, it pants with its tongue out
        let busy = ["search", "run", "answer", "write", "wait"].contains(acting ?? "")
        if (happy || trotting || busy) && !sleeping && !dizzy {
            let m = mouthAt, t = CGMutablePath()
            let hang = r * (0.3 + 0.03 * sin(CGFloat(clock) * 14))
            t.move(to: L(m + V(-r * 0.11, r * 0.05)))
            t.addLine(to: L(m + V(-r * 0.11, hang - r * 0.09)))
            t.addCurve(to: L(m + V(r * 0.11, hang - r * 0.09)), control1: L(m + V(-r * 0.11, hang + r * 0.06)), control2: L(m + V(r * 0.11, hang + r * 0.06)))
            t.addLine(to: L(m + V(r * 0.11, r * 0.05)))
            t.closeSubpath()
            k.tongue.path = t
            let line = CGMutablePath()
            line.move(to: L(m + V(0, r * 0.1)))
            line.addLine(to: L(m + V(0, hang - r * 0.1)))
            k.tongueLine.lineWidth = max(0.5, r * 0.025)
            k.tongueLine.path = line
        } else { k.tongue.path = nil; k.tongueLine.path = nil }
    }

    /// A red hat on top of the head, its tip hanging over to one side and swinging, white fur round the brim and a pompom.
    func drawSanta(_ dt: CGFloat) {
        let k = costume, r = radius, ring = smoothedSkin(), n = Goo.count
        for layer in [k.ears, k.earsInner, k.hoodMask, k.furMask, k.fold, k.stitch, k.blush, k.tongue, k.tongueLine] { layer.path = nil }
        k.spring(&k.sway, &k.swayV, to: clamp(-v.x / 900, -0.45, 0.45), k: 190, damping: 9, dt)
        let top = ring[n * 3 / 4], s = rotate((ring[n * 6 / 7] - ring[n * 9 / 14]).unit, k.sway * 0.35), u = V(s.y, -s.x)
        func P(_ a: CGFloat, _ b: CGFloat) -> CGPoint { L(top + s * (a * r) + u * (b * r)) }
        let cone = CGMutablePath(), fur = CGMutablePath()
        let tipA = 1.0 - k.sway * 0.9, tipB = 0.72 + abs(k.sway) * 0.2
        cone.move(to: P(-0.86, -0.3))
        cone.addCurve(to: P(tipA, tipB), control1: P(-0.7, 0.9), control2: P(0.2, 1.4))
        cone.addCurve(to: P(0.86, -0.3), control1: P(0.55, 0.9), control2: P(0.75, 0.4))
        cone.closeSubpath()
        func dot(_ a: CGFloat, _ b: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            let q = P(a, b)
            fur.addEllipse(in: CGRect(x: q.x - rx * r, y: q.y - ry * r, width: rx * r * 2, height: ry * r * 2))
        }
        for i in 0...6 {
            let a = -0.86 + CGFloat(i) * (1.72 / 6)
            dot(a, -0.33 - 0.06 * (1 - a * a), 0.2, 0.17)
        }
        dot(tipA, tipB, 0.21, 0.21)
        k.cover.path = cone
        k.trim.path = fur
    }
}
