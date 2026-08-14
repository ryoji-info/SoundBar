import Foundation
import os

/// SoundBar logs to both the unified log (visible in Console.app, subsystem `com.ryoji.SoundBar`)
/// and a plain text file, because the unified log is awkward to read for a background agent that
/// the user needs to debug themselves.
enum Log {
    static let subsystem = "com.ryoji.SoundBar"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let atb = Logger(subsystem: subsystem, category: "atb")
    static let btt = Logger(subsystem: subsystem, category: "btt")
    static let touch = Logger(subsystem: subsystem, category: "touch")
    static let app = Logger(subsystem: subsystem, category: "app")

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SoundBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SoundBar.log")
    }()

    /// Serialises file writes and keeps the log from growing without bound.
    private static let queue = DispatchQueue(label: "\(subsystem).log")
    private static let maxBytes = 2 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    enum Level: String {
        case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
    }

    /// Set from Settings at startup; debug lines are dropped unless verbose logging is on.
    static var verbose = false

    static func write(_ level: Level, _ category: String, _ message: String) {
        if level == .debug && !verbose { return }
        let line = "\(stamp.string(from: Date())) [\(level.rawValue)] \(category): \(message)\n"
        queue.async {
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes else { return }
        let old = fileURL.deletingLastPathComponent().appendingPathComponent("SoundBar.log.1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
    }

    // Convenience wrappers that hit both sinks.
    static func debug(_ c: String, _ m: String) { write(.debug, c, m); Logger(subsystem: subsystem, category: c).debug("\(m, privacy: .public)") }
    static func info(_ c: String, _ m: String)  { write(.info,  c, m); Logger(subsystem: subsystem, category: c).info("\(m, privacy: .public)") }
    static func warn(_ c: String, _ m: String)  { write(.warn,  c, m); Logger(subsystem: subsystem, category: c).warning("\(m, privacy: .public)") }
    static func error(_ c: String, _ m: String) { write(.error, c, m); Logger(subsystem: subsystem, category: c).error("\(m, privacy: .public)") }
}
