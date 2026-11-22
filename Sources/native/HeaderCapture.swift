import Foundation
import QuartzCore

// Shares a single in-memory top-strip capture between local observers.
actor HeaderCapture {
    typealias Result = (band: Int, lines: [String], others: [String], listEnd: CGFloat)
    typealias Reader = (Int, CGFloat, Int, CGFloat, pid_t) async -> Result?
    typealias FrontCheck = (pid_t) async -> Bool
    private let reader: Reader, front: FrontCheck, maxAge: CFTimeInterval
    private var window = 0, pid: pid_t = 0, cached: Result?, at: CFTimeInterval = 0
    private var inFlight: Task<Result?, Never>?, inFlightAt: CFTimeInterval = 0

    init(reader: @escaping Reader, front: @escaping FrontCheck, maxAge: CFTimeInterval = 0.6) {
        self.reader = reader; self.front = front; self.maxAge = maxAge
    }

    /// `notBefore`: a click at that moment may have changed the strip, so a read begun before it is no answer.
    func read(windowID: Int, width: CGFloat, listEnd: CGFloat, frontPID: pid_t, notBefore: CFTimeInterval = 0) async -> Result? {
        guard await front(frontPID) else { return nil }
        if window == windowID, pid == frontPID, let cached, at >= notBefore, CACurrentMediaTime() - at < maxAge { return cached }
        if window == windowID, pid == frontPID, let inFlight, inFlightAt >= notBefore { return await inFlight.value }
        let prior = window == windowID && pid == frontPID ? cached : nil
        let reader = reader
        let task = Task {
            let found = await reader(windowID, width, prior?.band ?? 0, prior?.listEnd ?? listEnd, frontPID)
            guard let found else { return nil as Result? }
            if let prior, found.band == prior.band { return (found.band, prior.lines, prior.others, found.listEnd) }
            return found
        }
        let started = CACurrentMediaTime()
        window = windowID; pid = frontPID; inFlight = task; inFlightAt = started
        let result = await task.value
        // Kept as of when it began: what the window showed then, not when the reading finished.
        if window == windowID, pid == frontPID, inFlightAt == started { cached = result; at = started; inFlight = nil }
        return result
    }
}

/// A chat's name the way the brain compares them (`guards.same_chat`, without its near-letter allowance): the same letters and digits, or a short name the
/// title goes on from after a break (小林 is 小林-市场 助理), never a name merely inside another (小林妈妈), nor one of the names a group nobody named is titled with.
func sameChatName(_ word: String, _ chat: String) -> Bool {
    func letters(_ text: String) -> String {
        let plain = text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: #"\s*[(（]\s*\d+\s*[)）].*$"#, with: "", options: .regularExpression)
        return String(plain.filter { $0.isLetter || $0.isNumber }).lowercased()
    }
    let key = letters(word)
    guard !key.isEmpty, !chat.isEmpty else { return false }
    if letters(chat) == key { return true }
    let start = word.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces).lowercased()
    let whole = chat.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces).lowercased()
    guard !start.isEmpty, whole.hasPrefix(start), whole.count > start.count, !whole.contains("、") else { return false }
    let next = whole[whole.index(whole.startIndex, offsetBy: start.count)]
    return !(next.isLetter || next.isNumber)
}
