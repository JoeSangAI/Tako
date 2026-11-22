// What one speaking gave, and which recognizer language hears it: pure, so tests/test_guards.py can hold them without a
// microphone or a permission prompt.
import Foundation

/// The recognizer's language for the owner: the first of their preferred languages (System Settings › Language & Region)
/// that Speech knows, in the identifier Speech itself lists (`zh-CN`, not the region format's `zh_CN`). Speaking.swift tries
/// these in order and takes the first that can listen on this Mac.
enum SpeechLocale {
    private static func parts(_ id: String) -> (language: String, script: String?, region: String?) {
        let pieces = id.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        var script: String?, region: String?
        for piece in pieces.dropFirst() {
            if piece.count == 4 { script = piece.capitalized }
            else if piece.count == 2 || (piece.count == 3 && Int(piece) != nil) { region = piece.uppercased() }
        }
        return ((pieces.first ?? "").lowercased(), script, region)
    }

    /// Chinese is told apart by script as much as by region: Speech's zh-CN is Mandarin in simplified characters, zh-TW in
    /// traditional ones, zh-HK Cantonese.
    private static func chinese(script: String?, region: String?) -> String {
        if script == "Hant" { return region == "HK" || region == "MO" ? "zh-HK" : "zh-TW" }
        if script == "Hans" { return "zh-CN" }
        switch region { case "TW": return "zh-TW"; case "HK", "MO": return "zh-HK"; default: return "zh-CN" }
    }

    static func candidates(preferred: [String], supported: [String]) -> [String] {
        let known = supported.map { $0.replacingOccurrences(of: "_", with: "-") }
        var picked: [String] = []
        func add(_ id: String?) { if let id, known.contains(id), !picked.contains(id) { picked.append(id) } }
        for wanted in preferred {
            let p = parts(wanted)
            if p.language == "zh" { add(chinese(script: p.script, region: p.region)); continue }
            if let region = p.region { add("\(p.language)-\(region)") }
            let same = known.filter { parts($0).language == p.language }.sorted()
            let usual = ["en": "US", "ja": "JP", "ko": "KR", "pt": "BR"][p.language] ?? p.language.uppercased()
            add(same.first { parts($0).region == usual } ?? same.first)
        }
        return picked
    }
}

/// One speaking, as the recognizer gave it. On this Mac's own recognizer a pause can start the words over: the next result
/// holds only what came after it (developer forums 731761, iOS 17/18 era Speech). What came before is kept, so the bubble
/// and the panel get everything said. `line` is the one line panel.log keeps: numbers and fixed words, never the words.
struct Heard {
    private(set) var kept = "", latest = ""
    private(set) var partials = 0, resets = 0, loud = 0
    private(set) var final = false
    private(set) var started: Double?, firstWords: Double?, firstPartial: Double?, firstVoice: Double?
    var buffers = 0
    var error: String?          // the recognizer's error as domain:code

    var text: String {
        guard !kept.isEmpty else { return latest }
        guard let a = kept.last, let b = latest.first else { return kept }
        return kept + (a.isASCII && a.isLetter && b.isASCII && b.isLetter ? " " : "") + latest
    }

    mutating func start(at t: Double) { started = t }

    /// The level meter's look at the voice (every 50 ms or so).
    mutating func voice(loud isLoud: Bool, at t: Double) {
        guard isLoud else { return }
        loud += 1
        if firstVoice == nil { firstVoice = t }
    }

    /// A result: partial or final, as the recognizer gave it.
    mutating func take(_ words: String, final isFinal: Bool, at t: Double) {
        if isFinal { final = true } else { partials += 1 }
        if !words.isEmpty, firstWords == nil { firstWords = t }
        if !words.isEmpty, !isFinal, firstPartial == nil { firstPartial = t }
        if !kept.isEmpty, Heard.wholeAgain(words, kept: kept, latest: latest) { kept = "" }   // a result that holds it all again
        else if Heard.startedOver(from: latest, to: words) { kept = text; resets += 1 }
        latest = words
    }

    /// The final result often gives back everything said, before the pause too.
    static func wholeAgain(_ words: String, kept: String, latest: String) -> Bool {
        guard words.count >= kept.count else { return false }
        return words.contains(kept) || words.hasPrefix(String(kept.prefix(2))) || words.count >= kept.count + latest.count
    }

    /// A revision keeps the start and the length; a start over is suddenly much shorter and begins differently.
    static func startedOver(from old: String, to new: String) -> Bool {
        guard old.count >= 4, let first = new.first, new.count * 2 <= old.count else { return false }
        return first != old.first
    }

    /// The voice has gone on for a while and no words have come: this recognizer is keeping them for the end.
    func late(at t: Double) -> Bool {
        guard firstWords == nil, let voice = firstVoice else { return false }
        return t - voice >= 2.5
    }

    func line(locale: String, end: String, at t: Double) -> String {
        func ms(_ from: Double?, _ to: Double?) -> String {
            guard let from, let to else { return "-" }
            return String(Int(((to - from) * 1000).rounded()))
        }
        return "speech locale=\(locale) ondevice=1 ms=\(ms(started, t)) buffers=\(buffers) loud=\(loud) "
            + "first-voice-ms=\(ms(started, firstVoice)) first-partial-ms=\(ms(started, firstPartial)) partials=\(partials) "
            + "resets=\(resets) final=\(final ? 1 : 0) chars=\(text.count) error=\(error ?? "none") end=\(end)"
    }
}
