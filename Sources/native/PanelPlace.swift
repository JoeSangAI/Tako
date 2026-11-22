import CoreGraphics

/// Where the panel is: beside the window the body is stuck to, or on its own on the desktop (floating). Pure, so the
/// test holds it (tests/test_guards.py). Rectangles are in the body's coordinates: from the top-left of the main screen.
enum PanelPlace {
    case window, floating
    mutating func close(bodyAttached: Bool) {
        if bodyAttached { self = .window }
    }
    /// Stuck onto a window: from now on the panel is that window's. True when it was the desktop's, so the window is told
    /// afresh even if it is the one it was on before.
    mutating func stuck() -> Bool {
        let was = self == .floating
        self = .window
        return was
    }

    static let margin: CGFloat = 16, topMargin: CGFloat = 24

    /// Where the body sits on the open desktop panel: as on a window's panel, on the left of its header.
    static func seat(of panel: CGRect, bar: CGFloat) -> CGPoint { CGPoint(x: panel.minX + 27, y: panel.minY + bar / 2) }

    /// The desktop panel: where the owner dragged it this run, else from where the body is, so the body is at its corner;
    /// always whole on the screen.
    static func desktop(near goo: CGPoint, size: CGSize, visible: CGRect, remembered: CGPoint?, bar: CGFloat) -> CGRect {
        let origin = remembered ?? CGPoint(x: goo.x - 27, y: goo.y - bar / 2)
        return clamp(CGRect(origin: origin, size: size), to: visible)
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let x = min(max(frame.minX, visible.minX + margin), max(visible.minX + margin, visible.maxX - frame.width - margin))
        let y = min(max(frame.minY, visible.minY + topMargin), max(visible.minY + topMargin, visible.maxY - frame.height - topMargin))
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}
