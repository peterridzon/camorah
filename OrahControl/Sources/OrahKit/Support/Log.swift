import Foundation

/// Small logging facility with an in-memory ring buffer, so the UI can show a
/// live activity log during a shoot without anyone tailing a terminal.
public enum Log {

    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public struct Entry: Sendable, Identifiable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String

        public var line: String {
            let t = Log.formatter.string(from: date)
            return "\(t)  \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  [\(category)] \(message)"
        }
    }

    nonisolated(unsafe) private static var buffer: [Entry] = []
    private static let lock = NSLock()
    private static let maxEntries = 2000

    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Called for every entry, on an arbitrary thread. The app installs a hook
    /// here to mirror entries into the UI.
    nonisolated(unsafe) public static var observer: (@Sendable (Entry) -> Void)?

    public static func log(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(date: Date(), level: level, category: category, message: message)
        lock.withLock {
            buffer.append(entry)
            if buffer.count > maxEntries { buffer.removeFirst(buffer.count - maxEntries) }
        }
        FileHandle.standardError.write(Data((entry.line + "\n").utf8))
        appendToFile(entry)
        observer?(entry)
    }

    // MARK: - The log file

    /// Launched from Finder there is no terminal to write to, and standard error
    /// goes nowhere — which is exactly the situation in which something fails and
    /// nobody can say why. So every line is also written here.
    public static let fileURL: URL = {
        let directory = AppPaths.logs
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("orah.log")
    }()

    nonisolated(unsafe) private static var handle: FileHandle?
    private static let fileLock = NSLock()

    private static func appendToFile(_ entry: Entry) {
        fileLock.withLock {
            if handle == nil {
                let path = fileURL.path
                // A fresh file each launch: a log that has to be scrolled past
                // three previous shows is not read.
                FileManager.default.createFile(atPath: path, contents: nil)
                handle = FileHandle(forWritingAtPath: path)
            }
            let stamp = dayFormatter.string(from: entry.date)
            try? handle?.write(contentsOf: Data((stamp + " " + entry.line + "\n").utf8))
        }
    }

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public static func info(_ category: String, _ message: String) { log(.info, category, message) }
    public static func warn(_ category: String, _ message: String) { log(.warn, category, message) }
    public static func error(_ category: String, _ message: String) { log(.error, category, message) }

    public static var entries: [Entry] { lock.withLock { buffer } }
}
