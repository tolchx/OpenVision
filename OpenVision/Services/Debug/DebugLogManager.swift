// OpenVision - DebugLogManager.swift
// Thread-safe in-app debug log manager with copy support

import Foundation

/// Centralized debug log manager for in-app log viewing
/// Captures structured log entries from GeminiLive and other services
@MainActor
final class DebugLogManager: ObservableObject {
    static let shared = DebugLogManager()

    @Published var entries: [LogEntry] = []

    /// Maximum entries to keep (ring buffer)
    private let maxEntries = 500

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let source: String
        let message: String
        let level: Level

        enum Level: String {
            case info = "ℹ️"
            case success = "✅"
            case warning = "⚠️"
            case error = "❌"
            case debug = "🔍"
            case audio = "🎙️"
            case network = "🌐"
        }

        var formatted: String {
            let time = Self.timeFormatter.string(from: timestamp)
            return "\(time) \(level.rawValue) [\(source)] \(message)"
        }

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    private init() {}

    /// Add a log entry (Thread-safe, can be called from any queue/actor)
    nonisolated func log(_ message: String, source: String = "App", level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), source: source, message: message, level: level)
        
        // Print synchronously so console gets it immediately in correct order
        print(entry.formatted)
        
        // Dispatch UI updates to main actor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            
            // Keep ring buffer size
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    /// Clear all logs
    func clear() {
        entries.removeAll()
    }

    /// Export all logs as a single string (for copy)
    func exportText() -> String {
        var text = "=== OpenVision Debug Log ===\n"
        text += "Exported: \(Date())\n"
        text += "Entries: \(entries.count)\n"
        text += "===========================\n\n"

        for entry in entries {
            text += entry.formatted + "\n"
        }

        return text
    }
}
