// A right Option tap is decided on release so modified shortcuts pass untouched.
struct SpeakingKey {
    private(set) var down = false
    private var chord = false

    mutating func modifier(code: Int64, rightIsDown: Bool, otherModifiers: Bool, enabled: Bool) -> Bool {
        if code != 61 {
            if down { chord = true }
            return false
        }
        if rightIsDown && !down {
            down = true
            chord = !enabled || otherModifiers
        } else if !rightIsDown && down {
            down = false
            return enabled && !chord
        }
        return false
    }

    mutating func keyDown() -> Bool {
        if down { chord = true; return true }
        return false
    }

    mutating func reset() { down = false; chord = false }
}
