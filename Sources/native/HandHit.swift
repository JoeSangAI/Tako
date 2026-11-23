// Whether the goo's own window takes a press at the pointer, or lets it through to the window underneath: pure, so the
// test can hold it (tests/test_guards.py). The window is click-through everywhere except on the body itself and on a
// visible promise; this is asked on every pointer move, including while the body is not being drawn.
import CoreGraphics

enum HandHit {
    /// The short label opens into the card. On the card itself, the ink outside the buttons also means 看看.
    static func action(at p: CGPoint, offered: Bool, soft: Bool, card: CGRect, done: CGRect, later: CGRect, drop: CGRect = .zero) -> String? {
        guard offered, card.contains(p) else { return nil }
        if soft { return "expand" }
        if done.contains(p) { return "done" }
        if later.contains(p) { return "later" }
        if drop.contains(p) { return "cancel" }
        return "look"
    }

    /// The open list of what it holds. The count closes it, a row's two buttons answer for that row (`done:id`,
    /// `later:id`), and the rest of its ink only keeps the press from the window underneath.
    static func held(at p: CGPoint, list: CGRect, count: CGRect, rows: [(id: String, done: CGRect, later: CGRect)]) -> String? {
        guard list.contains(p) else { return nil }
        if count.contains(p) { return "held" }
        for row in rows {
            if row.done.contains(p) { return "done:" + row.id }
            if row.later.contains(p) { return "later:" + row.id }
        }
        return "list"
    }

    static func takesClicks(grabbed: Bool, distance: CGFloat, radius: CGFloat, onHand: Bool) -> Bool {
        grabbed || distance < radius + 7 || onHand
    }

    /// Whether the panel's window lets a press through to what is under it. On a window the side window is wider than
    /// the card, so only the card takes presses; while Tako works that window its presses must reach it. On the desktop
    /// the window is the card and takes every press: its click-through used to be put right only by a frame or a pointer
    /// event, and with the body still nothing ticks, so the input box could be left passing presses to whatever lay under
    /// it.
    static func panelLetsThrough(floating: Bool, inCard: Bool, dragging: Bool, working: Bool) -> Bool {
        if working { return true }
        if floating || dragging { return false }
        return !inCard
    }
}

/// What a press on the body means. A
/// tap is answered at once; the second within the system's double-click interval opens or closes the panel. Poked on and on
/// it gets cross: a warning look at the fourth tap within `window` seconds, ink and off at the fifth, so a double click, or
/// one more after it by a slip of the hand, never sets it off. Times are the real clock, not the body's, which stands still
/// while nothing moves.
struct Taps {
    static let window = 1.4, warnAt = 4, inkAt = 5
    enum Meaning: Equatable { case poke, open, warn(open: Bool), ink }
    private var times: [Double] = []
    private var unpaired: Double?

    mutating func tap(at t: Double, doubleInterval: Double) -> Meaning {
        times.append(t)
        times.removeAll { t - $0 > Taps.window }
        let double: Bool
        if let first = unpaired, t - first <= doubleInterval { double = true; unpaired = nil } else { double = false; unpaired = t }
        if times.count >= Taps.inkAt { times.removeAll(); unpaired = nil; return .ink }
        if times.count == Taps.warnAt { return .warn(open: double) }
        return double ? .open : .poke
    }
}
