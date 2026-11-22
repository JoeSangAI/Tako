import Foundation

let messagingNames = ["微信", "wechat", "飞书", "lark", "feishu", "qq", "telegram", "slack", "discord", "信息", "messages", "钉钉", "dingtalk", "whatsapp", "企业微信", "wecom"]
let sendWords = ["发送", "发出", "寄出", "send", "reply all"]

// A label is a button only if it is short; English words must match whole words.
func hits(_ text: String, _ words: [String]) -> String? {
    let lowered = text.lowercased()
    let pieces = [lowered] + lowered.components(separatedBy: .whitespacesAndNewlines)
    for piece in pieces where !piece.isEmpty && piece.count <= 14 {
        for word in words {
            if word.allSatisfy({ $0.isASCII }) {
                if piece.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil { return word }
            } else if piece.contains(word) { return word }
        }
    }
    return nil
}

enum SendGuard {
    static func button(_ label: String) -> String? { hits(label, sendWords) }
    static func messagingEnter(_ app: String, _ bundle: String) -> Bool {
        let lowered = (app + " " + bundle).lowercased()
        return messagingNames.contains { lowered.contains($0) }
    }
    static func weChatSendCorner(_ isWeChat: Bool, x: Double, y: Double, width: Double, height: Double) -> Bool {
        isWeChat && y > height - 48 && x > width - 110
    }
}
