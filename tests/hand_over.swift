// Offscreen scenes for the real body, promise drawing and GooView mouse handlers.
import AppKit

let controller = Controller(selfTest: true)  // The native shortcut callbacks refer to this entry-point global.
let host = controller
let screen = CGRect(x: 0, y: 0, width: 960, height: 500)
let view = GooView(frame: screen)
let goo = Goo(host: host, view: view)
host.gooView = view
host.goo = goo
view.owner = host
goo.visible = screen
goo.screenRect = screen
goo.surface = screen.maxY
goo.mode = .free
goo.costume.pinned = true
host.fakeMouse = V(20, 20)

func check(_ condition: @autoclosure () -> Bool, _ failure: String) {
    guard condition() else { print(failure); exit(1) }
}

func offer(soft: Bool = false, repeats: Int = 0, frame: CGRect? = nil) {
    let hand: [String: Any] = ["id": "1", "text": soft ? "喝水" : "该喝水了", "soft": soft,
                               "reason": soft ? "place" : "due", "repeat": repeats]
    host.entrusted.apply(["holding": true, "count": 1, "offer": hand], frame: frame)
}

/// It holds `n` made-up things, told the way the brain tells it.
func hold(_ n: Int) {
    host.entrusted.items = (0..<n).map { ["id": "\($0 + 1)", "text": $0 == 0 ? "给小林回电话，顺便问一下下周排期能不能提前两天" : "第 \($0 + 1) 件事"] }
    host.entrusted.apply(["holding": n > 0, "count": n], frame: nil)
}

func click(_ point: CGPoint) {
    host.fakeMouse = pointer(at: point)
    host.entrusted.pressed(at: pointer(at: point))   // what the app's own monitor does on every press, before the view gets it
    view.mouseDown(with: mouse(.leftMouseDown, point))
    view.mouseUp(with: mouse(.leftMouseUp, point))
}

func advance(_ seconds: Double, checking: () -> Void = {}) {
    for _ in 0..<Int(seconds * 240) {
        goo.step(1.0 / 240)
        goo.draw()
        checking()
    }
}

func pointer(at point: CGPoint) -> V { V(point.x, screen.maxY - point.y) }
func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

switch CommandLine.arguments[1] {
case "landing":
    // Still in the air when the reminder comes: it comes down where it was, then holds it out. It goes nowhere for it.
    goo.place(at: V(300, 380))
    goo.v = V(0, 120)
    offer(frame: CGRect(x: 500, y: 100, width: 300, height: 300))
    var first: V?
    advance(4) {
        if !goo.handInk.isHidden {
            if let first { check((goo.c - first).length < 0.01, "body moved while bubble was visible") }
            else { first = goo.c }
        } else if first == nil { check(!goo.settled || goo.clock - goo.handAt < 0.5, "it stood there and held nothing out") }
        check(!goo.dizzy, "the reminder made it land hard")
    }
    check(first != nil, "the bubble never appeared")
    check(abs(goo.c.x - 300) < 1 && goo.settled, "it went somewhere to hand the reminder over")
case "wander":
    goo.place(at: V(479, screen.maxY - goo.radius * goo.stance))
    goo.settled = true
    goo.startZoomies()
    goo.v.x = 330
    goo.nextWander = 0
    offer()
    let start = goo.c
    advance(3) {
        check((goo.c - start).length < 0.01, "desktop body drifted or wandered during the reminder")
    }
    check(!goo.zooming && goo.wanderTo == nil, "the run stopped for the reminder")
case "expansion":
    // Exercise both directions, including where the card is clamped at the screen boundary.
    for x: CGFloat in [140, 820] {
        host.entrusted.offerID = nil
        goo.place(at: V(x, 475))
        offer(soft: true)
        advance(0.45)
        let short = goo.handRect
        check(!short.isEmpty && !goo.handLabel.isHidden, "the short label did not appear")
        let aim = pointer(at: center(short))
        host.entrusted.observeHand(at: aim)
        offer()
        advance(1.6) {
            check(goo.handRect.contains(short), "the short label's area slipped out of the expanded bubble")
            check(goo.handHit(aim) != nil, "the pointer lost its target during expansion")
        }
        goo.silenced = true
        goo.draw()
        check(goo.handLabel.isHidden && goo.handHit(aim) == nil, "quiet exposed the reminder text or its action")
        goo.silenced = false
    }
case "repeat":
    goo.place(at: V(720, 475))
    offer(repeats: 1)
    advance(2)
    let card = goo.handRect
    check(!card.isEmpty, "the repeat bubble did not appear")
    advance(2) {
        check(goo.handRect == card, "the repeat bubble bobbed")
    }
case "early":
    goo.place(at: V(720, 475))
    offer()
    advance(0.5)
    let point = center(goo.handInk.path!.boundingBoxOfPath)
    check(!goo.handInk.isHidden && goo.handHit(pointer(at: point)) == "look", "visible opening bubble did not take a press")
case "clicks":
    goo.place(at: V(720, 475))
    offer(soft: true)
    advance(0.45)
    let point = center(goo.handRect)
    host.fakeMouse = pointer(at: point)
    for _ in 0..<6 {
        view.mouseDown(with: mouse(.leftMouseDown, point))
        check(view.handPress != nil && goo.mode == .free, "a short-label press reached the body")
        view.mouseUp(with: mouse(.leftMouseUp, point))
    }
    check(goo.ink.isEmpty && goo.v.length == 0, "repeated presses made the body react")
    offer()
    advance(1.2)
    check(goo.handDone.string as? String == "✓ 做完了" && goo.handLater.string as? String == "稍后",
          "visible reminder buttons did not use the to-do labels")
    for (point, action) in [(center(goo.handDoneRect), "done"), (center(goo.handLaterRect), "later"),
                            (center(goo.handLabel.frame), "look"), (CGPoint(x: goo.handRect.minX + 6, y: goo.handRect.midY), "look")] {
        check(goo.handHit(pointer(at: point)) == action, "card target missed: \(action)")
        view.mouseDown(with: mouse(.leftMouseDown, point))
        check(view.handPress != nil && goo.mode == .free, "a card press reached the body")
        view.mouseUp(with: mouse(.leftMouseUp, point))
    }
case "look":
    goo.place(at: V(720, 475))
    goo.handHome = goo.c
    offer()
    goo.handHome = goo.c
    goo.takeHandBack("seen")
    advance(0.2)
    check(goo.handHome == nil, "opening the reminder still pinned the body to the old hand-over destination")
case "held":
    var sent: [String] = []
    host.entrusted.answerTap = { sent.append($0 + " " + $1) }
    goo.place(at: V(480, 250))
    goo.settled = true
    hold(3)
    advance(1)
    var badge = center(goo.handRect)
    check(!goo.handRect.isEmpty && goo.handRect.width < 40 && !goo.heldOpen, "the count was not there to press")
    click(badge)
    check(goo.heldOpen && goo.heldRows.count == 3 && goo.heldMore.isHidden, "a press on the count did not open the list")
    check(!host.sideOpen && goo.mode == .free, "a press on the count opened the panel or reached the body")
    check(goo.heldWords[0].string as? String == "给小林回电话，顺便问一下下周排期能不能提前两天" && goo.heldWords[0].truncationMode == .end
          && !goo.heldWords[0].isWrapped && goo.heldWords[0].frame.maxX < goo.heldDones[0].frame.minX, "a long line ran under its buttons")
    check(goo.heldDones[1].string as? String == "✓ 做完了" && goo.heldLaters[1].string as? String == "稍后", "the rows did not use the to-do labels")
    check(goo.handHit(pointer(at: badge)) == "held", "the count moved from under the pointer when the list opened")
    let words = center(goo.heldWords[0].frame)
    check(goo.handHit(pointer(at: words)) == "list", "the list let a press on its words through")
    click(words)
    check(goo.heldOpen && sent.isEmpty, "a press on the words closed the list or answered something")
    click(center(goo.heldRows[1].done))
    click(center(goo.heldRows[2].later))
    check(sent == ["2 done", "3 later"], "a row's button answered for the wrong thing: \(sent)")
    advance(0.2)
    check(goo.heldOpen, "the list closed while the pointer was on it")
    hold(2)
    advance(0.1)
    check(goo.heldOpen && goo.heldRows.map(\.id) == ["1", "2"] && goo.heldWords[2].isHidden, "the list kept a thing that was done")
    click(badge)
    check(!goo.heldOpen && goo.heldRows.isEmpty && goo.heldWords[0].isHidden && goo.handRect.width < 40, "a second press on the count did not close the list")
    badge = center(goo.handRect)
    click(badge)
    check(goo.heldOpen, "it did not open again")
    let outside = CGPoint(x: 40, y: 40)
    check(goo.handHit(pointer(at: outside)) == nil, "the open list took a press far from it")
    host.entrusted.pressed(at: pointer(at: outside))
    check(!goo.heldOpen && goo.heldWords[0].isHidden, "a press elsewhere did not close the list")
    badge = center(goo.handRect)
    click(badge)
    hold(0)
    advance(0.1)
    check(!goo.heldOpen && goo.handHit(pointer(at: badge)) == nil, "the list stayed open with nothing held")
    hold(3)
    advance(0.1)
    badge = center(goo.handRect)
    click(badge)
    check(goo.heldOpen, "it did not open again")
    goo.silenced = true
    goo.draw()
    check(!goo.heldOpen && goo.heldWords.allSatisfy(\.isHidden) && goo.heldDones.allSatisfy(\.isHidden), "quiet left the list's words on the screen")
    badge = center(goo.handRect)
    check(goo.handHit(pointer(at: badge)) == "held", "quiet took the count away")
    click(badge)
    check(!goo.heldOpen && goo.heldWords.allSatisfy(\.isHidden) && sent.count == 2, "the list opened while quiet")
    goo.silenced = false
    goo.draw()
    badge = center(goo.handRect)
    click(badge)
    check(goo.heldOpen, "it did not open after quiet")
    offer()
    advance(0.1)
    check(!goo.heldOpen && goo.heldWords.allSatisfy(\.isHidden), "the list stayed open over a reminder being handed over")
case "heldroom":
    // The Dock at the bottom and the menu bar at the top are screen, not room.
    goo.visible = CGRect(x: 0, y: 25, width: 960, height: 405)
    goo.surface = goo.visible.maxY
    let room = CGRect(x: 0, y: screen.maxY - goo.visible.maxY, width: 960, height: 405)
    hold(5)
    // On the floor by the Dock, left and right; under the menu bar; stuck to a window whose right edge is the screen's.
    for (x, y, mode) in [(CGFloat(140), goo.visible.maxY - goo.radius * goo.stance, Mode.free), (820, goo.visible.maxY - goo.radius * goo.stance, .free),
                         (480, 45, .attached), (952, 200, .attached), (952, 420, .attached)] {
        goo.mode = mode
        goo.place(at: V(x, y))
        goo.settled = true
        goo.heldOpen = false
        goo.armTip = goo.armRest()   // put there, not walked there: the hand is where it rests
        if mode == .free { advance(0.2) } else { goo.draw() }
        let badge = center(goo.handRect)
        check(!goo.handRect.isEmpty && room.contains(goo.handRect), "the count was out of the room at \(x), \(y)")
        check((goo.c - V(x, y)).length < 1 && abs(badge.x - x) < 60 && abs(screen.maxY - badge.y - y) < 40, "the count was not by the body at \(x), \(y)")
        let body = goo.c
        click(badge)
        check(goo.heldOpen && goo.heldRows.count == 3, "the list did not open at \(x), \(y)")
        check(goo.heldMore.string as? String == "还有 2 件" && !goo.heldMore.isHidden, "five held did not say two more")
        check(room.contains(goo.handRect), "the list ran out of the room at \(x), \(y): \(goo.handRect)")
        for layer in goo.heldWords + goo.heldDones + goo.heldLaters + [goo.heldMore, goo.handLabel] {
            check(!layer.isHidden && goo.handRect.contains(layer.frame), "a line of the list lies outside it at \(x), \(y)")
        }
        for row in goo.heldRows { check(goo.handRect.contains(row.done) && goo.handRect.contains(row.later), "a button lies outside the list") }
        check(goo.handHit(pointer(at: badge)) == "held", "the second press would not land on the count at \(x), \(y)")
        check((goo.c - body).length < 0.01, "the body moved for the list")
        click(badge)
        check(!goo.heldOpen, "the list did not close at \(x), \(y)")
    }
default:
    exit(2)
}
