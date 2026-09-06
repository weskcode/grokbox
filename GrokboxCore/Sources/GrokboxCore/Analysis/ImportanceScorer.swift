import Foundation

/// Decides which messages are worth a model's attention.
///
/// The model is the expensive tier, so it never sees the whole corpus. This
/// picks the candidates — recent, unread, not obviously bulk — and gives each
/// a heuristic baseline the model's answer replaces.
public enum ImportanceScorer {
    public static let defaultWindowDays = 30

    public struct Candidate: Sendable {
        public var uid: UInt32
        public var baseline: Importance
        public var skipModel: Bool
    }

    /// `assessments` come from the sender-level pass; `verdictFor` answers what
    /// tier a sender landed in.
    @MainActor
    public static func candidates(
        in messages: [MessageHeader],
        verdictFor: (String) -> Verdict?,
        contacted: Set<String>,
        windowDays: Int = defaultWindowDays,
        limit: Int = 150
    ) -> [Candidate] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now) ?? .distantPast

        let recent = messages
            .filter { $0.receivedAt >= cutoff && !$0.isSweptLocally && $0.readAt == nil }
            .sorted { $0.receivedAt > $1.receivedAt }

        var out: [Candidate] = []
        for message in recent {
            let verdict = verdictFor(message.senderAddress)
            let known = contacted.contains(message.senderAddress)

            // Bulk senders are noise by construction; do not spend a model call.
            if verdict == .bulk && !message.isFlagged {
                out.append(Candidate(uid: message.uid, baseline: .noise, skipModel: true))
                continue
            }

            let baseline: Importance = if message.isFlagged || (known && message.isUnread) {
                .needsYou
            } else if known || verdict == .keep {
                .worthKnowing
            } else {
                .noise
            }
            out.append(Candidate(uid: message.uid, baseline: baseline, skipModel: false))
        }

        // Model calls are the budget; skips are free and keep their baseline.
        let modelBound = out.filter { !$0.skipModel }.prefix(limit)
        let skipped = out.filter(\.skipModel)
        return Array(modelBound) + skipped
    }
}
