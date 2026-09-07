import Foundation

/// A reader that needs no model at all: plain rules over the subject and
/// body. Exists so the demo, screenshots and UI tests behave identically on
/// every machine — including simulators where the on-device model cannot
/// run. It is never chosen for a real account unless asked for by launch flag.
public actor DemoReaderModel: TextModel {
    public nonisolated let name = "Demo reader (rules, no model)"
    public init() {}

    public func availability() async -> ModelAvailability { .available }

    public func read(_ r: ReadRequest) async throws -> ReadResult {
        let text = (r.subject + " " + r.bodyExcerpt).lowercased()
        let asks = ["?", "can you", "could you", "please", "let me know", "need your", "by friday", "by eod", "deadline", "due", "invoice", "reschedule"]
            .contains { text.contains($0) }
        let needs = r.senderIsKnownContact && asks
        let due: String? = text.contains("today") ? "today" : text.contains("tomorrow") ? "tomorrow"
            : text.contains("friday") ? "Friday" : text.contains("eod") ? "today" : nil
        let firstSentence = r.bodyExcerpt.split(whereSeparator: { ".!?\n".contains($0) }).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? r.subject
        let summary = "\(r.senderName.isEmpty ? r.senderAddress : r.senderName) — \(firstSentence.prefix(120))"
        return ReadResult(summary: summary,
                          importance: needs ? .needsYou : (r.senderIsKnownContact ? .worthKnowing : .noise),
                          reason: needs ? "someone you talk to is asking for something" : "rules",
                          actionType: needs ? (text.contains("review") ? .review : .reply) : .none,
                          dueHint: needs ? due : nil,
                          isQuick: needs && r.bodyExcerpt.count < 300)
    }

    public func categorize(_ r: CategorizeRequest) async throws -> CategorizeResult {
        if r.hasUnsubscribeLink { return CategorizeResult(category: r.unreadRatio > 0.8 ? .promotion : .newsletter, reason: "rules") }
        if r.address.hasPrefix("no-reply") || r.address.hasPrefix("noreply") || r.address.hasPrefix("notifications") {
            return CategorizeResult(category: .notification, reason: "rules")
        }
        return CategorizeResult(category: .person, reason: "rules")
    }
}
