import Foundation
import os

/// Milestone logging for the app: the unified log via `os.Logger`, and a
/// plain file in the app's own container so a scripted run — or a bug report —
/// can read it without depending on `log show`.
///
/// Never contains message contents: only counts, phases, and account labels.
enum Log {
    static let run = Logger(subsystem: "com.wesleykeetch.grokbox", category: "run")

    /// `~/Library/Containers/com.wesleykeetch.grokbox/Data/Library/Logs/grokbox.log`
    static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appending(path: "grokbox.log")
    }()

    private static let queue = DispatchQueue(label: "grokbox.log.file")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func note(_ text: String) {
        run.notice("\(text, privacy: .public)")
        let line = "\(stamp.string(from: Date())) grokbox: \(text)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
