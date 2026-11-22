// Pure decisions shared by the notification and device observers.
enum AttentionPolicy {
    static func shouldSchedule(due: Double, now: Double) -> Bool { due > now }
    static func sharesScreen(assertion: String) -> Bool {
        let name = assertion.lowercased()
        return ["screensharing", "screen sharing", "screen capture", "screencapture",
                "screen recording", "display capture", "remote desktop"].contains { name.contains($0) }
    }
    static func heldPreview(hovered: Bool, quiet: Bool) -> Bool { hovered && !quiet }
    static func quiet(microphone: Bool, ownSpeech: Bool, camera: Bool, power: Bool) -> Bool {
        (microphone && !ownSpeech) || camera || power
    }
}
