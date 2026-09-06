import Foundation
import Network

// Verbatim copy of GrokboxCore IMAPConnection.withTimeout (limit shortened for the test).
enum E: Error { case timedOut(String) }
func withTimeout<T: Sendable>(_ limit: Duration, what: String,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: limit); throw E.timedOut(what) }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@main struct Main {
    static func main() async {
        // A server that completes the TCP handshake and then says nothing, forever.
        let listener = try! NWListener(using: .tcp)
        listener.newConnectionHandler = { c in c.start(queue: .global()) }   // accept, never send
        listener.start(queue: .global())
        while listener.port == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let port = listener.port!
        print("silent server on 127.0.0.1:\(port)")

        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        conn.start(queue: .global())
        try? await Task.sleep(for: .milliseconds(400))

        // Exactly the shape of IMAPConnection.fill(): a NON-cancellation-aware continuation.
        let start = Date()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(12))
            print("WATCHDOG: 3s timeout still had not fired after \(Int(Date().timeIntervalSince(start)))s")
            exit(2)
        }
        do {
            _ = try await withTimeout(.seconds(3), what: "waiting for the server") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, err in
                        if let err { c.resume(throwing: err) }
                        else if let d, !d.isEmpty { c.resume(returning: d) }
                        else if done { c.resume(throwing: E.timedOut("closed")) }
                        else { c.resume(returning: Data()) }
                    }
                }
            }
            print("RESULT: returned data (unexpected)")
        } catch {
            print("RESULT: threw \(error) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s — timeout WORKS")
        }
        watchdog.cancel()
        exit(0)
    }
}
