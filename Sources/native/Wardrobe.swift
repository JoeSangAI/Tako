// The wardrobe and the choice of what to wear today, kept apart from the drawing so a test can compile it on its own
// (`tests/test_outfit.py`). How an outfit is worn on the goo is in Outfit.swift.
import AppKit

struct Outfit {
    let id: String, name: String
    let debut: DateComponents          // first day it can be worn; before that nobody knows it exists
    let wornOn: (DateComponents) -> Bool
    let primary: NSColor, inner: NSColor, light: NSColor
    /// The model service it goes with: following the occasions, Tako wears it whenever the owner's key is for that service.
    /// A look and nothing more; the model, prompts and rules are the same whoever serves them.
    var service: String? = nil

    static let all: [Outfit] = [
        Outfit(id: "corgi", name: "柯基帽", debut: day(2026, 11, 4), wornOn: { within($0, from: day(2026, 11, 4), days: 14) },
               primary: NSColor(srgbRed: 0.91, green: 0.6, blue: 0.29, alpha: 1), inner: NSColor(srgbRed: 0.99, green: 0.76, blue: 0.72, alpha: 1),
               light: NSColor(srgbRed: 1, green: 0.97, blue: 0.91, alpha: 1)),
        Outfit(id: "santa", name: "圣诞帽", debut: day(2026, 12, 20), wornOn: { $0.month == 12 && (20...26).contains($0.day ?? 0) },
               primary: NSColor(srgbRed: 0.84, green: 0.12, blue: 0.14, alpha: 1), inner: .clear,
               light: NSColor(srgbRed: 1, green: 0.99, blue: 0.97, alpha: 1)),
        // The DeepSeek whale girl (Tako swallowed her and wears her skin): a black whale's tail, a white lace apron with a
        // little blue whale on it, and a blue spout when it is pleased (Whale.swift).
        // In the wardrobe from the start, for anyone; worn by itself only for a DeepSeek key.
        Outfit(id: "whale", name: "鲸鱼娘", debut: day(2026, 11, 1), wornOn: { _ in false },
               primary: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1), inner: .clear,
               light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), service: "deepseek"),
    ]

    static func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: m, day: d) }
    static func key(_ c: DateComponents) -> Int { (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0) }
    static func within(_ today: DateComponents, from start: DateComponents, days: Int) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        guard let a = calendar.date(from: start), let b = calendar.date(from: today) else { return false }
        let gone = calendar.dateComponents([.day], from: a, to: b).day ?? -1
        return gone >= 0 && gone < days
    }

    static func wardrobe(on today: DateComponents) -> [Outfit] { all.filter { key($0.debut) <= key(today) } }

    /// What Tako puts on when the choice is left to it: the outfit of the owner's model service, otherwise the day's.
    static func occasion(on today: DateComponents, service: String) -> Outfit? {
        let owned = wardrobe(on: today)
        return owned.first { !service.isEmpty && $0.service == service } ?? owned.first { $0.wornOn(today) }
    }

    /// The owner's choice comes first: "none" is none, an outfit's id is that outfit; "occasions" (or one not out yet) leaves it to Tako.
    static func pick(choice: String, service: String, on today: DateComponents) -> Outfit? {
        switch choice {
        case "none": return nil
        case "occasions": return occasion(on: today, service: service)
        case let id: return wardrobe(on: today).first { $0.id == id } ?? occasion(on: today, service: service)
        }
    }

    // The owner's choice: "occasions" (also when nothing was ever chosen), "none", or an outfit's id.
    static let choiceKey = "outfit"
    static var choice: String {
        get { UserDefaults.standard.string(forKey: choiceKey) ?? "occasions" }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

    /// The service the owner's key is for (`provider.py`'s preset, "custom" for a relay), "" with a ChatGPT login. The panel
    /// says it from `/setup`; it is kept so Tako starts up already dressed and does not change clothes a moment later.
    static let serviceKey = "outfitService"
    static var service: String {
        get { UserDefaults.standard.string(forKey: serviceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serviceKey) }
    }

    static func wearing(on today: DateComponents) -> Outfit? { pick(choice: choice, service: service, on: today) }
}
