import AppKit

// A compact bubble grows inward from the body and stays within its own display.
enum BubbleLayout {
    static func size(_ text: String, font: NSFont, maximum: CGFloat = 260) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        let width = max(70, min(maximum, measured + 26))
        let lines: CGFloat = measured > width - 26 ? 2 : 1
        return CGSize(width: width, height: lines == 1 ? 32 : 49)
    }
    static func frame(size: CGSize, point: CGPoint, visible: CGRect, radius: CGFloat) -> CGRect {
        let margin: CGFloat = 10
        let width = min(size.width, max(1, visible.width - margin * 2))
        let height = min(size.height, max(1, visible.height - margin * 2))
        let right = point.x + radius + 9
        let left = point.x - radius - 9 - width
        let preferLeft = point.x > visible.midX
        var x = preferLeft ? left : right
        if x < visible.minX + margin { x = right }
        if x + width > visible.maxX - margin { x = left }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - width)
        let y = min(max(point.y + radius * 0.45, visible.minY + margin), visible.maxY - margin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func goal(frame: CGRect, point: CGPoint, primaryTop: CGFloat) -> V {
        let x = frame.midX >= point.x ? frame.minX + 5 : frame.maxX - 5
        let y = min(max(point.y, frame.minY + 6), frame.maxY - 6)
        return V(x, primaryTop - y)
    }
    /// Every bubble window, the speaking one and whatever shows in it after: up over other apps' windows on every Space, and
    /// never hidden by the system because Tako is not the app in front, which the owner always is in when they speak or
    /// read the answer.
    static func prepare(_ panel: NSPanel) {
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.canHide = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    }
}

/// The answer in the speaking bubble, on the desktop with the panel closed. Short is whole and goes by itself; anything longer, or with a list, code, a link or a file, shows its start and
/// the panel holds the rest. Same width and fonts as the listening bubble, so it is the same bubble going on.
enum ReplyLayout {
    enum Kind: Equatable { case short, long }
    static let previewLines = 2
    static let progressStay = 6.0      // a step shows this long, then the body's own working look carries it
    static let longStay = 12.0
    static let saidFont = NSFont.systemFont(ofSize: 12.5)
    static var textWidth: CGFloat { ListeningLayout.width - ListeningLayout.inset * 2 }

    /// Only on the desktop with the panel closed. Stuck to a window the panel opens there as before; a panel already open
    /// shows it in the panel.
    static func answersAside(panelOpen: Bool, stuck: Bool) -> Bool { !panelOpen && !stuck }

    /// Lines these words take in the bubble, measured with its own font and width.
    static func lines(_ text: String) -> Int {
        let line = ListeningLayout.lineHeight()
        return max(1, Int((ListeningLayout.measure(text, font: ListeningLayout.words, width: textWidth) / line).rounded()))
    }
    /// `rich`: the page saw a list, code, a table, a link or a file in it (side.html `asidePlain`).
    static func judge(_ text: String, rich: Bool) -> Kind {
        rich || lines(text) > previewLines ? .long : .short
    }
    /// Seconds it stays before fading (more while the pointer is on it): a short one by its length, 4 to 8; a long one 12.
    static func stay(_ kind: Kind, text: String) -> Double {
        kind == .long ? longStay : min(8, max(4, 4 + Double(text.count) / 10))
    }
    static func size(lines: Int, hint: Bool) -> CGSize {
        let l = ListeningLayout.self
        let body = CGFloat(max(1, lines)) * l.lineHeight()
        return CGSize(width: l.width, height: l.top + l.statusHeight + l.gap + body + (hint ? l.gap + l.hintHeight : 0) + l.bottom)
    }
    /// From the bottom up: how to open it (long only), the answer or the step, and on top what the owner said.
    static func rects(in size: CGSize, lines: Int, hint: Bool) -> (said: CGRect, words: CGRect, hint: CGRect) {
        let l = ListeningLayout.self, w = size.width - l.inset * 2
        let hintRect = CGRect(x: l.inset, y: l.bottom, width: w, height: hint ? l.hintHeight : 0)
        let words = CGRect(x: l.inset, y: hint ? hintRect.maxY + l.gap : l.bottom, width: w, height: CGFloat(max(1, lines)) * l.lineHeight())
        let said = CGRect(x: l.inset, y: words.maxY + l.gap, width: w, height: l.statusHeight)
        return (said, words, hintRect)
    }
}

/// What the bubble shows once the words are handed over: the owner's sentence in grey on top, then 收到，在想… or the step it
/// is on, then the answer. A long answer says how to see all of it. A click opens the panel at this answer.
final class ReplyView: NSView {
    enum Phase: Equatable { case working(String), answer(String, ReplyLayout.Kind) }
    var said = "" { didSet { needsDisplay = true } }
    var phase = Phase.working("收到，在想…") { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    static let hintText = "展开 · 双击我也行"
    private static let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
    private static let soft = NSColor(calibratedWhite: 0.5, alpha: 1)

    var long: Bool { if case .answer(_, .long) = phase { return true }; return false }
    var lines: Int {
        switch phase {
        case .working: return 1
        case .answer(let text, let kind): return kind == .long ? ReplyLayout.previewLines : min(ReplyLayout.previewLines, ReplyLayout.lines(text))
        }
    }
    var wanted: CGSize { ReplyLayout.size(lines: lines, hint: long) }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let r = ReplyLayout.rects(in: bounds.size, lines: lines, hint: long)
        func put(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, wrap: Bool) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let saidLine = said.replacingOccurrences(of: "\n", with: " ")
        put(saidLine, in: r.said, font: ReplyLayout.saidFont, color: NSColor(calibratedWhite: 0.55, alpha: 1), wrap: false)
        switch phase {
        case .working(let step):
            put(step.replacingOccurrences(of: "\n", with: " "), in: r.words, font: ListeningLayout.words, color: Self.soft, wrap: false)
        case .answer(let text, let kind):
            // Long: its start in two lines, and the rest is one press away.
            put(kind == .long ? text.replacingOccurrences(of: "\n", with: " ") : text, in: r.words, font: ListeningLayout.words, color: Self.ink, wrap: true)
            if kind == .long {
                put(Self.hintText, in: r.hint, font: ListeningLayout.hint, color: NSColor(calibratedWhite: 0.55, alpha: 1), wrap: false)
            }
        }
    }
}

// The bubble while the owner speaks: a line saying it hears them, with the voice's level, everything heard so far, and
// how to end it. One width, so it grows only in height as the words come, up to a few lines; past that the newest lines
// stay and a leading … says there is more above.
enum ListeningLayout {
    static let width: CGFloat = 288
    static let inset: CGFloat = 16
    static let maxLines = 5
    static let words = NSFont.systemFont(ofSize: 14)
    static let status = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let hint = NSFont.systemFont(ofSize: 11)
    static let statusHeight: CGFloat = 18, hintHeight: CGFloat = 14, gap: CGFloat = 5, top: CGFloat = 11, bottom: CGFloat = 9

    static func lineHeight(_ font: NSFont = words) -> CGFloat { ceil(measure("国", font: font, width: 1000)) }

    static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
    }

    /// What fits: the whole text, or `…` and as much of its end as `maxLines` hold.
    static func fit(_ text: String, font: NSFont = words, width: CGFloat = width - inset * 2, maxLines: Int = maxLines) -> (shown: String, lines: Int, clipped: Bool) {
        let line = lineHeight(font), limit = line * CGFloat(maxLines) + 0.5
        func lines(_ s: String) -> Int { max(1, Int((measure(s, font: font, width: width) / line).rounded())) }
        if text.isEmpty || measure(text, font: font, width: width) <= limit { return (text, lines(text), false) }
        let characters = Array(text)
        var low = 0, high = characters.count   // the longest end that still fits
        while low < high {
            let mid = (low + high + 1) / 2
            if measure("…" + String(characters.suffix(mid)), font: font, width: width) <= limit { low = mid } else { high = mid - 1 }
        }
        let shown = "…" + String(characters.suffix(low))
        return (shown, lines(shown), true)
    }

    static func size(lines: Int) -> CGSize {
        CGSize(width: width, height: top + statusHeight + gap + CGFloat(max(1, lines)) * lineHeight() + gap + hintHeight + bottom)
    }

    /// From the bottom up, in the bubble's own coordinates: how to end it, the words, and the status line on top.
    static func rects(in size: CGSize, lines: Int) -> (status: CGRect, words: CGRect, hint: CGRect) {
        let w = size.width - inset * 2
        let hint = CGRect(x: inset, y: bottom, width: w, height: hintHeight)
        let words = CGRect(x: inset, y: hint.maxY + gap, width: w, height: CGFloat(max(1, lines)) * lineHeight())
        let status = CGRect(x: inset, y: words.maxY + gap, width: w, height: statusHeight)
        return (status, words, hint)
    }

    /// The voice's loudness (RMS of a buffer) as 0...1 for the level bars: quiet room near 0, ordinary speech about half.
    static func level(rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        return CGFloat(min(1, max(0, (20 * log10(rms) + 52) / 40)))
    }
}

/// The level bars measured against this room and this microphone, not a fixed loudness: a quiet built-in microphone
/// never reached the fixed scale, and the bars barely moved while the words came through fine.
/// The floor is the quietest it has heard (creeping up slowly), the top the loudest (sinking slowly); a voice is
/// whatever stands clear of the floor.
struct VoiceMeter {
    private var floor: Float?, peak: Float = -200
    mutating func hear(rms: Float) -> (level: CGFloat, voice: Bool) {
        let db = 20 * log10(max(rms, 1e-6))
        floor = min(db, (floor ?? db) + 0.05)
        peak = max(db, peak - 0.1)
        let low = floor!, span = max(14, peak - low)
        let level = min(1, max(0, (db - low - 3) / (span - 3)))
        return (CGFloat(level), db > low + 8)
    }
}

/// What the listening bubble shows (ListeningLayout): its state with the level bars, the words so far, how to end it.
final class ListeningView: NSView {
    enum Phase: Equatable { case opening, listening, heard, ended(String) }
    var phase = Phase.opening { didSet { if phase != oldValue { measured = nil } } }
    var words = "" { didSet { if words != oldValue { measured = nil } } }
    /// The voice has gone on a while and the recognizer has given no words yet (`Heard.late`): the bubble no longer says the
    /// words will appear here, it says they come when the owner is done, which is what this recognizer then does.
    var late = false { didSet { if late != oldValue { needsDisplay = true } } }
    private var measured: (size: CGSize, shown: String, lines: Int)?
    var level: CGFloat = 0    // smoothed, 0...1
    var clock: CGFloat = 0    // the bars' own slow ripple, so a silent room still shows it is listening
    private static let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
    private static let soft = NSColor(calibratedWhite: 0.5, alpha: 1)

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The bubble's size for these words in this phase.
    var wanted: (size: CGSize, shown: String, lines: Int) {
        if let measured { return measured }
        if case .ended = phase { measured = (ListeningLayout.size(lines: 1), "", 1); return measured! }
        let fit = ListeningLayout.fit(words)
        measured = (ListeningLayout.size(lines: fit.lines), fit.shown, fit.lines)
        return measured!
    }

    var statusText: String {
        switch phase {
        case .opening: return "马上好，先别说…"
        case .listening: return "在听"
        case .heard: return "听到了，交给 Tako…"
        case .ended(let why): return why
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (_, shown, lines) = wanted
        let rects = ListeningLayout.rects(in: bounds.size, lines: lines)
        if case .ended(let why) = phase {
            // Closing: one line saying why, nothing left that looks like it still listens.
            let line = CGRect(x: rects.words.minX, y: (bounds.height - ListeningLayout.lineHeight()) / 2, width: rects.words.width, height: ListeningLayout.lineHeight())
            (why as NSString).draw(in: line, withAttributes: [.font: ListeningLayout.words, .foregroundColor: Self.soft])
            return
        }
        drawBars(in: rects.status)
        (statusText as NSString).draw(at: NSPoint(x: rects.status.minX + 32, y: rects.status.minY + 1),
                                      withAttributes: [.font: ListeningLayout.status, .foregroundColor: phase == .listening ? Self.ink : Self.soft])
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        if shown.isEmpty {
            let waiting = ListeningView.waiting(phase, late: late)
            (waiting as NSString).draw(in: rects.words, withAttributes: [.font: ListeningLayout.words, .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1), .paragraphStyle: paragraph])
        } else {
            (shown as NSString).draw(with: rects.words, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                     attributes: [.font: ListeningLayout.words, .foregroundColor: Self.ink, .paragraphStyle: paragraph])
        }
        let hint = phase == .heard ? "" : "再按一下右 ⌥ 结束 · esc 取消"
        (hint as NSString).draw(in: rects.hint, withAttributes: [.font: ListeningLayout.hint, .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)])
    }

    /// The grey line in place of the words before there are any: it says only what will really happen.
    static func waiting(_ phase: Phase, late: Bool) -> String {
        switch phase {
        case .opening: return "麦克风一开就可以说"
        case .heard: return "在等最后几个字…"
        default: return late ? "在听，说完了字一起出来" : "说吧，字会出现在这里"
        }
    }

    private func drawBars(in row: CGRect) {
        let shape: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.55]
        let lowest: CGFloat = 3, tallest = row.height - 2
        for i in 0..<5 {
            var amount: CGFloat
            var color = Self.ink
            switch phase {
            case .listening:
                let ripple = 0.1 + 0.08 * (1 + sin(clock * 3.2 - CGFloat(i) * 0.9)) / 2
                let jitter = 1 + 0.18 * sin(clock * 13 + CGFloat(i) * 2.1)
                amount = max(ripple, level * shape[i] * jitter)
            case .opening:
                amount = Int(clock * 6) % 5 == i ? 0.35 : 0.08   // a light running along them: getting ready, not yet listening
                color = Self.soft
            default:
                amount = 0.08; color = Self.soft
            }
            let height = lowest + (tallest - lowest) * min(1, amount)
            let bar = NSBezierPath(roundedRect: NSRect(x: row.minX + CGFloat(i) * 5.5, y: row.midY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5)
            color.setFill(); bar.fill()
        }
    }
}
