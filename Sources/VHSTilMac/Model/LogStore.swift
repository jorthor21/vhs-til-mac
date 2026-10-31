import Foundation

/// Teknisk logg som vises i appen og kan eksporteres i diagnosepakken.
/// Hjemmekatalogen byttes ut med "~" slik at brukernavn ikke havner i loggen.
final class LogStore: ObservableObject {
    enum Level: Int, Comparable {
        case debug = 0, info, warning, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warning: return "ADVARSEL"
            case .error: return "FEIL"
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var flushScheduled = false
    private let maxEntries = 4000
    private let home = NSHomeDirectory()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ level: Level, _ message: String) {
        let clean = message.replacingOccurrences(of: home, with: "~")
        let e = Entry(date: Date(), level: level, message: clean)
        lock.lock()
        pending.append(e)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
        }
        #if DEBUG
        print("[\(level.label)] \(clean)")
        #endif
    }

    func info(_ m: String) { log(.info, m) }
    func warn(_ m: String) { log(.warning, m) }
    func error(_ m: String) { log(.error, m) }
    func debug(_ m: String) { log(.debug, m) }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        entries.append(contentsOf: batch)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }

    func exportText() -> String {
        flush()
        return entries.map { e in
            "\(Self.timeFormatter.string(from: e.date)) [\(e.level.label)] \(e.message)"
        }.joined(separator: "\n")
    }

    static func format(_ e: Entry) -> String {
        "\(timeFormatter.string(from: e.date))  \(e.message)"
    }
}
