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

/// The second of three: a group chat that concerns a thing without being the person's own chat. Small enough (the head
/// count WeChat puts after the title), and titled with the person or with the thing's project. Their own chat is the
/// first (a bubble); a big group is the third (nothing). No count to read: only a project's name in the title counts.
let smallGroup = 20
func groupConcerns(_ place: [String: String], chat: String) -> Bool {
    guard !chat.isEmpty else { return false }
    func lines(_ text: String?) -> [String] { (text ?? "").split(separator: "\n").map { String($0).lowercased() }.filter { $0.count >= 2 } }
    let people = lines([place["chat"] ?? "", place["names"] ?? ""].joined(separator: "\n"))
    if people.contains(where: { sameChatName($0, chat) }) { return false }
    let plain = chat.precomposedStringWithCompatibilityMapping.lowercased()
    let tail = plain.range(of: #"[(（]\s*\d+\s*[)）]\s*$"#, options: .regularExpression)
    let count = tail.flatMap { Int(plain[$0].filter(\.isNumber)) }
    let title = tail.map { String(plain[..<$0.lowerBound]) } ?? plain
    if let count, count > smallGroup { return false }
    if lines(place["project"]).contains(where: { title.contains($0) }) { return true }
    return count != nil && people.contains { title.contains($0) }
}

