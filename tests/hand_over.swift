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
    goo.place(at: V(300, 450))
    goo.v = V(620, 1520)
    // The midpoint is outside the real desktop, so the offscreen view keeps its own screen.
    offer(frame: CGRect(x: -20000, y: 490, width: 20700, height: 100))
    var first: V?
    advance(4) {
        if !goo.handInk.isHidden {
            if let first { check((goo.c - first).length < 0.01, "body moved while bubble was visible") }
            else { first = goo.c }
        }
        check(!goo.dizzy, "travel to the reminder triggered a hard landing")
    }
    check(first != nil && goo.c.x > screen.midX, "the bubble appeared beside the front window")
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
default:
    exit(2)
}
