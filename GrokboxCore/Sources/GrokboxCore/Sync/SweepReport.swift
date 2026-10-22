import Foundation

/// What a sweep did to each message it was asked about, for the run that just
/// finished. Held in memory only; nothing here is stored.
public struct SweepReport: Equatable, Sendable {
    public enum Class: Equatable, Sendable {
        /// The server confirmed every write the sweep needed for it.
        case confirmed
        /// A known refusal: the server or Grokbox declined, and it did not change.
        case failed
        /// The sweep guard kept it in the inbox.
        case held
        /// Stopped, cut off, or otherwise impossible to prove either way.
        case unknown
    }

    public enum Ending: Equatable, Sendable {
        case running
        case completed
        case stopped
        /// Grokbox or the server declined before the rest was sent.
        case refused
        /// The run broke off for a reason it cannot vouch for, such as a lost connection.
        case interrupted
    }

    /// One server write: what it asked for and what came back.
    public struct Write: Equatable, Sendable {
        public var requested: [UInt32]
        public var confirmed: [UInt32]
        /// The write was cut off rather than refused, so anything requested and
        /// not confirmed may or may not have changed. When false, the server
        /// refused the rest and it did not change.
        public var cutOff: Bool

        public init(requested: [UInt32], confirmed: [UInt32], cutOff: Bool = false) {
            self.requested = requested
            self.confirmed = confirmed
            self.cutOff = cutOff
        }
    }

    public enum Unsubscribe: Equatable, Sendable {
        case notRequested
        /// Asked for, but the sweep did not send it: a write for this sender
        /// failed, all of its mail was held, the run ended first, or it already
        /// went to this address earlier in the run.
        case notSent
        /// The sender's server acknowledged it.
        case accepted
        /// Nothing usable went out or the server said no; left for the user.
        case declined
        /// Grokbox cannot tell whether it went out or whether the sender got it.
        case unknown
    }

    public struct Sender: Equatable, Sendable {
        public var address: String
        public var mailbox: String
        public var planned: [UInt32]
        public var held: [UInt32]
        /// How many writes each message needs; nil until the sweep reaches this sender.
        public var steps: Int?
        public var writes: [Write]
        public var unsubscribe: Unsubscribe

        public init(address: String, mailbox: String, planned: [UInt32], held: [UInt32] = [], steps: Int? = nil,
                    writes: [Write] = [], unsubscribe: Unsubscribe = .notRequested) {
            self.address = address
            self.mailbox = mailbox
            self.planned = planned
            self.held = held
            self.steps = steps
            self.writes = writes
            self.unsubscribe = unsubscribe
        }
    }

    public struct Tally: Equatable, Sendable {
        public var confirmed: Int
        public var failed: Int
        public var held: Int
        public var unknown: Int

        public init(confirmed: Int = 0, failed: Int = 0, held: Int = 0, unknown: Int = 0) {
            self.confirmed = confirmed
            self.failed = failed
            self.held = held
            self.unknown = unknown
        }

        public var total: Int { confirmed + failed + held + unknown }
    }

    public var senders: [Sender]
    public var ending: Ending

    public init(senders: [Sender] = [], ending: Ending = .running) {
        self.senders = senders
        self.ending = ending
    }

    /// Precedence per message: held, then a write that was cut off before
    /// confirming it (unknown), then a write that refused it (failed), then
    /// confirmed by every step it needed. A message with a step still missing
    /// is decided by how the run ended.
    public func classes(of sender: Sender) -> [UInt32: Class] {
        let held = Set(sender.held)
        let writes = sender.writes.map { (requested: Set($0.requested), confirmed: Set($0.confirmed), cutOff: $0.cutOff) }
        var out: [UInt32: Class] = [:]
        for uid in sender.planned where out[uid] == nil {
            let unconfirmed = writes.filter { $0.requested.contains(uid) && !$0.confirmed.contains(uid) }
            out[uid] = if held.contains(uid) {
                .held
            } else if unconfirmed.contains(where: \.cutOff) {
                .unknown
            } else if !unconfirmed.isEmpty {
                .failed
            } else if let steps = sender.steps, steps > 0, writes.count(where: { $0.confirmed.contains(uid) }) >= steps {
                .confirmed
            } else {
                ending == .refused ? .failed : .unknown
            }
        }
        return out
    }

    public func tally(of sender: Sender) -> Tally {
        var tally = Tally()
        for kind in classes(of: sender).values {
            switch kind {
            case .confirmed: tally.confirmed += 1
            case .failed: tally.failed += 1
            case .held: tally.held += 1
            case .unknown: tally.unknown += 1
            }
        }
        return tally
    }

    public var tally: Tally {
        senders.map(tally(of:)).reduce(Tally()) {
            Tally(confirmed: $0.confirmed + $1.confirmed, failed: $0.failed + $1.failed,
                  held: $0.held + $1.held, unknown: $0.unknown + $1.unknown)
        }
    }

    public func count(_ unsubscribe: Unsubscribe) -> Int {
        senders.filter { $0.unsubscribe == unsubscribe }.count
    }
}
