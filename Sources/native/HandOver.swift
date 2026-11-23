// A promise is a little pocket of ink, held by the body's existing hand. Every
// outfit wears this same hand; the prop is outside the liquid body's blur.
import AppKit
import QuartzCore

extension Goo {
    func presentHand(text: String, soft: Bool = false, destination: V? = nil) {
        handText = text
        handPhase = "offer"; handAt = clock; handSoft = soft
        handRect = .zero
        handDeparture = destination.map { _ in c }
        if let destination {
            handHome = destination
            surface = visible.maxY
            standingID = nil; settled = false
        }
        sleeping = false; puddle = false; peekSide = 0
        wanderTo = nil; guiltyUntil = 0; zoomUntil = 0; splatUntil = 0
        creep = 0; v = V()
    }

    func expandHand() {
        handSoft = false
        if handDeparture == nil { handAt = clock - 1.1 }   // Grow the same bubble in place.
    }

    /// 稍后: the bubble first says when it comes back (the real wait, from the brain), then goes in.
    func sayThenTuck(_ line: String) {
        handText = line; handPhase = "saying"; handAt = clock
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.handPhase == "saying" else { return }
            self.takeHandBack("later")
        }
    }

    func takeHandBack(_ action: String) {
        if handDeparture != nil || action == "seen" { handHome = nil }
        handDeparture = nil
        handRect = .zero
        handPhase = action == "seen" ? "" : action
        handAt = clock; handSoft = false
        if action == "done" {
            carrying = false
            happyUntil = clock + 1.1
            kick(75); pop = 0.8
            if costume.isWhale { spout(0.55) }
        }
    }

    /// The list is open only while the count would be there to press: an offer takes its place, and quiet shows no words.
    var heldShown: Bool { heldOpen && carrying && !handOffering && !silenced && !heldItems.isEmpty }

    /// A press on the count opens what it holds, in place; the same press again, or one anywhere else, puts it away.
    func showHeld(_ open: Bool) {
        let was = heldShown
        heldOpen = open
        heldOpen = heldShown
        guard heldOpen != was else { return }
        // Standing still nothing draws it, so it is drawn here, as quiet does.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawHand()
        CATransaction.commit()
        host.wakeLoop()
    }

    var handScale: CGFloat { radius / 15 }
    var handOffering: Bool { handPhase == "offer" || handPhase == "saying" }
    /// It holds things out from where it is. Stuck, seated or standing it is somewhere; free and still falling it is not yet.
    var handGrounded: Bool { mode != .free || handHome != nil || settled || seat != nil }
    // An attached body sits at the window's right edge; hand toward that edge.
    // Near the display's left boundary turn the prop inward to keep it visible.
    var handSide: CGFloat { (mode == .attached || handHome != nil) && c.x > visible.minX + 120 * handScale ? -1 : c.x > visible.midX ? -1 : 1 }
    var handProgress: CGFloat {
        let age = CGFloat(clock - handAt)
        switch handPhase {
        case "offer":
            if handSoft { return 0.5 * clamp(age / 0.25, 0, 1) }
            // A small first reach, a pause, then an elastic hand-over.
            if age < 0.22 { return age / 0.22 * 0.12 }
            if age < 0.38 { return 0.12 }
            return 0.12 + easeOutBack(clamp((age - 0.38) / 0.72, 0, 1), overshoot: 0.75) * 0.88
        case "saying": return 1
        case "later": return 1 - clamp(age / 0.62, 0, 1)
        case "ignored": return 1 - clamp(age / 1.1, 0, 1)
        default: return 0
        }
    }

    var handGoal: V? {
        guard handDeparture == nil,
              carrying || handOffering || ((handPhase == "later" || handPhase == "ignored") && clock - handAt < 1.2) else { return nil }
        let p: CGFloat = handOffering ? 1 : handProgress
        let tucked: CGFloat = handPhase == "later" ? sin(clamp(CGFloat(clock - handAt) / 0.62, 0, 1) * .pi) * 12 : 0
        return c + V(handSide * (radius * 1.22 + 48 * handScale * p), radius * 0.36 - 12 * handScale * p + tucked * handScale)
    }

    func handHit(_ point: V) -> String? { handHit(at: L(point)) }

    func handHit(at point: CGPoint) -> String? {
        guard !handRect.isEmpty else { return nil }
        if heldShown { return HandHit.held(at: point, list: handRect, count: heldBadge, rows: heldRows) }
        if carrying && !handOffering && handRect.insetBy(dx: -5, dy: -5).contains(point) { return "held" }
        return HandHit.action(at: point, offered: handPhase == "offer" && !silenced, soft: handSoft,
                              card: handRect, done: handDoneRect, later: handLaterRect, drop: handDropRect)
    }

    func drawHand() {
        if handInk.superlayer == nil {
            for layer in [handInk, handEdge, handSpecks, handButtons, handLabel, handDone, handLater, handDrop] { view.layer!.addSublayer(layer) }
            handInk.fillColor = NSColor(white: 0.975, alpha: 1).cgColor
            handInk.strokeColor = Goo.ink
            handInk.lineWidth = 1.6
            handEdge.fillColor = nil; handEdge.strokeColor = Goo.ink; handEdge.lineCap = .round
            handSpecks.fillColor = Goo.ink
            handButtons.fillColor = nil; handButtons.strokeColor = Goo.ink; handButtons.lineCap = .round
            for layer in [handLabel, handDone, handLater, handDrop] {
                layer.contentsScale = 2; layer.foregroundColor = Goo.ink
                layer.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                layer.alignmentMode = .center; layer.truncationMode = .end
            }
            handLabel.isWrapped = true
            for layer in heldWords + heldDones + heldLaters + [heldMore] {
                view.layer!.addSublayer(layer)
                layer.contentsScale = 2; layer.foregroundColor = Goo.ink
                layer.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                layer.alignmentMode = heldWords.contains(layer) ? .left : .center; layer.truncationMode = .end
            }
        }
        heldOpen = heldShown
        for layer in heldWords + heldDones + heldLaters + [heldMore] { layer.isHidden = true }
        heldRows = []; heldBadge = .zero
        let age = CGFloat(clock - handAt), scale = handScale
        let showing = carrying || handPhase == "offer" || handPhase == "saying" || (age < 1.2 && ["done", "later", "ignored"].contains(handPhase))
        let visible = showing && handDeparture == nil && (!handOffering || mode != .grabbed)
            && !(handPhase == "offer" && (age < 0.38 || !handGrounded))
        for layer in [handInk, handEdge, handSpecks, handButtons, handLabel, handDone, handLater, handDrop] { layer.isHidden = !visible }
        handRect = .zero; handDoneRect = .zero; handLaterRect = .zero; handDropRect = .zero
        guard showing else { handHome = nil; handPhase = ""; return }
        guard visible else { return }
        let p = handProgress, resting = carrying && !handOffering
        let preview = AttentionPolicy.heldPreview(hovered: handHovered, quiet: silenced)
        let soft = handPhase == "offer" && handSoft
        let listed = heldOpen
        let expanded = listed ? 1 : resting ? (preview ? CGFloat(1) : CGFloat(0)) : soft ? p : clamp((p - 0.42) / 0.58, 0, 1)
        // An offer grows from one point, even while the elastic arm is catching up.
        let tip = L(handOffering ? handGoal ?? armTip : armTip)
        let message = resting ? "待办 \(heldCount) · \(heldPreview)" : handText
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .medium)
        // Measured once for each message: setting text out is dear, and the words stay the same while it is held out.
        if handMeasure?.text != message || handMeasure?.size != font.pointSize {
            handMeasure = (message, font.pointSize, (message as NSString).size(withAttributes: [.font: font]).width)
        }
        let measured = handMeasure!.width
        let targetWidth = clamp(measured + 28 * scale, 150 * scale, 205 * scale)
        var width = min((24 * (1 - expanded) + targetWidth / scale * expanded) * scale, screenRect.width - 16)
        let twoLines = measured > targetWidth - 24 * scale
        var height = (22 + (twoLines ? 58 : 43) * expanded) * scale
        // Words stay where they can be read and tapped: the Dock and the menu bar are screen, not room. On the floor by
        // the Dock the bubble used to slide under it.
        let free = self.visible
        let room = free.isEmpty ? CGRect(origin: .zero, size: screenRect.size)
            : CGRect(x: free.minX - screenRect.minX, y: screenRect.maxY - free.maxY, width: free.width, height: free.height)
        // The list: the count's line, a line for each of the first three, and one more saying how many are left.
        let shown = min(3, heldItems.count), line = 24 * scale
        var desiredY = tip.y - height * 0.5, upward = false
        if listed {
            width = min(272 * scale, room.width - 16)
            height = line * CGFloat(1 + shown + (heldItems.count > shown ? 1 : 0)) + 6 * scale
            // The count's line stays where the count was pressed, so a second press there closes the list and never lands
            // on a row's button. The rows open below it, or above it when the floor or the Dock is too near.
            upward = tip.y + line * 0.5 + 3 * scale - height < room.minY + 8
            desiredY = upward ? tip.y - line * 0.5 - 3 * scale : tip.y + line * 0.5 + 3 * scale - height
        }
        let desiredX = handSide < 0 ? tip.x - width + 2 * scale : tip.x - 2 * scale
        let x = clamp(desiredX, room.minX + 8, max(room.minX + 8, room.maxX - width - 8))
        let y = clamp(desiredY, room.minY + 8, max(room.minY + 8, room.maxY - height - 8))
        let rect = CGRect(x: x, y: y, width: width, height: height)
        // Two unequal loops, a dry-brush gap, and one wet speck: the same ink world as Enchant.
        let loop = CGMutablePath()
        loop.move(to: CGPoint(x: rect.minX + width * 0.16, y: rect.minY + 1 * scale))
        loop.addCurve(to: CGPoint(x: rect.maxX - width * 0.07, y: rect.minY + 2 * scale), control1: CGPoint(x: rect.minX + width * 0.42, y: rect.minY - 2 * scale), control2: CGPoint(x: rect.maxX - width * 0.26, y: rect.minY + 3 * scale))
        loop.addCurve(to: CGPoint(x: rect.maxX - width * 0.05, y: rect.maxY - 2 * scale), control1: CGPoint(x: rect.maxX + 6 * scale, y: rect.minY + height * 0.2), control2: CGPoint(x: rect.maxX + 2 * scale, y: rect.maxY - height * 0.18))
        loop.addCurve(to: CGPoint(x: rect.minX + width * 0.12, y: rect.maxY), control1: CGPoint(x: rect.maxX - width * 0.35, y: rect.maxY + 2 * scale), control2: CGPoint(x: rect.minX + width * 0.32, y: rect.maxY - 1 * scale))
        loop.addCurve(to: CGPoint(x: rect.minX + width * 0.16, y: rect.minY + scale), control1: CGPoint(x: rect.minX - 5 * scale, y: rect.maxY + scale), control2: CGPoint(x: rect.minX - 5 * scale, y: rect.minY - scale))
        loop.closeSubpath()
        handInk.path = loop
        handInk.lineWidth = 1.6 * scale
        let stroke = CGMutablePath()
        stroke.move(to: CGPoint(x: rect.minX + width * 0.13, y: rect.maxY + 2 * scale))
        stroke.addQuadCurve(to: CGPoint(x: rect.minX + width * 0.67, y: rect.maxY + 2.5 * scale), control: CGPoint(x: rect.midX, y: rect.maxY - 1 * scale))
        handEdge.path = stroke; handEdge.lineWidth = 0.7 * scale
        let burst = CGMutablePath()
        if handPhase == "done" {
            handInk.opacity = 0; handEdge.opacity = 0
            let origin = handBurstOrigin
            for n in 0..<9 where age < 0.65 {
                let angle = CGFloat(n) * 2.39996
                let distance = (8 + age * 88) * scale
                let r = max(0, (2.8 - age * 4.2) * scale) * (n % 3 == 0 ? 1.25 : 0.7)
                burst.addEllipse(in: CGRect(x: origin.x + cos(angle) * distance - r, y: origin.y + sin(angle) * distance - age * age * 90 * scale - r, width: r * 2, height: r * 2))
            }
        } else {
            handInk.opacity = 1; handEdge.opacity = 1
            handBurstOrigin = CGPoint(x: rect.midX, y: rect.midY)
        }
        handSpecks.path = burst
        let labels = resting || !silenced && (soft ? expanded >= 0.48 : expanded > 0.8 && handOffering)
        let buttons = labels && handPhase == "offer" && !soft
        let asking = handChoice == "stalled"
        handLabel.isHidden = !labels; handDone.isHidden = !buttons; handLater.isHidden = !buttons; handDrop.isHidden = !(buttons && asking)
        if !(buttons && asking) { handDropRect = .zero }
        handButtons.isHidden = !buttons && !listed
        if handPhase == "offer" && !silenced {
            // Leave room for the ink edge without letting its changing contour shrink the target.
            handRect = rect.insetBy(dx: -4 * scale, dy: -4 * scale)
        }
        if labels {
            if resting { handRect = rect }
            // The words are set only when they change: a text layer told its words again draws them again.
            func put(_ layer: CATextLayer, _ text: String, _ size: CGFloat, _ frame: CGRect) {
                if layer.string as? String != text { layer.string = text }
                if layer.fontSize != size { layer.fontSize = size }
                if layer.frame != frame { layer.frame = frame }
            }
            if listed {
                // Line 0 is the count, first or last; the others read from the top down either way.
                func slot(_ n: Int) -> CGFloat { upward && n == 0 ? rect.minY + 3 * scale : rect.maxY - 3 * scale - line * CGFloat(upward ? n : n + 1) }
                heldBadge = CGRect(x: rect.minX, y: slot(0), width: rect.width, height: line)
                put(handLabel, "待办 \(heldItems.count)", 12 * scale, CGRect(x: rect.minX + 12 * scale, y: slot(0) + 3 * scale, width: rect.width - 24 * scale, height: 18 * scale))
                let path = CGMutablePath()
                for n in 0..<shown {
                    let y = slot(n + 1) + 3.5 * scale
                    let later = CGRect(x: rect.maxX - 50 * scale, y: y, width: 34 * scale, height: 17 * scale)
                    let done = CGRect(x: later.minX - 72 * scale, y: y, width: 62 * scale, height: 17 * scale)
                    // One line each: what does not fit ends in an ellipsis (`truncationMode`).
                    put(heldWords[n], heldItems[n].text.replacingOccurrences(of: "\n", with: " "), 12 * scale,
                        CGRect(x: rect.minX + 18 * scale, y: y, width: done.minX - rect.minX - 26 * scale, height: 17 * scale))
                    put(heldDones[n], "✓ 做完了", 11 * scale, done)
                    put(heldLaters[n], "稍后", 11 * scale, later)
                    for layer in [heldWords[n], heldDones[n], heldLaters[n]] { layer.isHidden = false }
                    let row = (id: heldItems[n].id, done: done.insetBy(dx: -3 * scale, dy: -2 * scale), later: later.insetBy(dx: -3 * scale, dy: -2 * scale))
                    heldRows.append(row)
                    path.addRoundedRect(in: row.done, cornerWidth: 8 * scale, cornerHeight: 8 * scale)
                    path.move(to: CGPoint(x: row.later.minX + 7 * scale, y: row.later.minY + scale))
                    path.addQuadCurve(to: CGPoint(x: row.later.maxX - 7 * scale, y: row.later.minY + scale), control: CGPoint(x: row.later.midX, y: row.later.minY + 2 * scale))
                }
                if heldItems.count > shown {
                    put(heldMore, "还有 \(heldItems.count - shown) 件", 11 * scale, CGRect(x: rect.minX + 12 * scale, y: slot(shown + 1) + 3.5 * scale, width: rect.width - 24 * scale, height: 17 * scale))
                    heldMore.isHidden = false
                }
                handButtons.path = path; handButtons.lineWidth = 1.1 * scale
                return
            }
            let compact = resting && !preview
            let labelHeight = (compact ? 18 : twoLines ? 32 : 18) * scale
            put(handLabel, compact ? String(max(1, heldCount)) : message, 12 * scale, CGRect(x: rect.minX + (compact ? 2 : 12) * scale, y: buttons ? rect.minY + 25 * scale : rect.midY - labelHeight / 2, width: rect.width - (compact ? 4 : 24) * scale, height: labelHeight))
            if buttons {
                if asking {
                    put(handDone, "今天做", 11 * scale, CGRect(x: rect.midX - 68 * scale, y: rect.minY + 5 * scale, width: 44 * scale, height: 17 * scale))
                    put(handLater, "改天", 11 * scale, CGRect(x: rect.midX - 14 * scale, y: rect.minY + 5 * scale, width: 34 * scale, height: 17 * scale))
                    put(handDrop, "不做了", 11 * scale, CGRect(x: rect.midX + 28 * scale, y: rect.minY + 5 * scale, width: 44 * scale, height: 17 * scale))
                    handDropRect = handDrop.frame.insetBy(dx: -3 * scale, dy: -2 * scale)
                } else {
                    put(handDone, "✓ 做完了", 11 * scale, CGRect(x: rect.midX - 50 * scale, y: rect.minY + 5 * scale, width: 62 * scale, height: 17 * scale))
                    put(handLater, "稍后", 11 * scale, CGRect(x: rect.midX + 20 * scale, y: rect.minY + 5 * scale, width: 34 * scale, height: 17 * scale))
                }
                handDoneRect = handDone.frame.insetBy(dx: -3 * scale, dy: -2 * scale)
                handLaterRect = handLater.frame.insetBy(dx: -3 * scale, dy: -2 * scale)
                let path = CGMutablePath()
                let hovered = handHit(host.mouse())
                let primary = handDoneRect.insetBy(dx: hovered == "done" ? -2 * scale : 0, dy: 0)
                path.addRoundedRect(in: primary, cornerWidth: 8 * scale, cornerHeight: 8 * scale)
                path.move(to: CGPoint(x: handLaterRect.minX + 7 * scale, y: handLaterRect.minY + scale))
                path.addQuadCurve(to: CGPoint(x: handLaterRect.maxX - 7 * scale, y: handLaterRect.minY + scale),
                                  control: CGPoint(x: handLaterRect.midX, y: handLaterRect.minY + (hovered == "later" ? -2 : 2) * scale))
                if asking {
                    path.move(to: CGPoint(x: handDropRect.minX + 7 * scale, y: handDropRect.minY + scale))
                    path.addQuadCurve(to: CGPoint(x: handDropRect.maxX - 7 * scale, y: handDropRect.minY + scale),
                                      control: CGPoint(x: handDropRect.midX, y: handDropRect.minY + (hovered == "cancel" ? -2 : 2) * scale))
                }
                handButtons.path = path; handButtons.lineWidth = (hovered != nil ? 1.8 : 1.1) * scale
            }
        }
        if ["done", "later", "ignored"].contains(handPhase), age >= 1.2 { handPhase = ""; handHome = nil }
    }
}
