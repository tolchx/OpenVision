// OpenVision - DebugLogView.swift
// In-app debug log viewer with copy and clear buttons

import SwiftUI

/// Full-screen debug log viewer
struct DebugLogView: View {
    @StateObject private var logManager = DebugLogManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false
    @State private var autoScroll = true

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Stats bar
                HStack {
                    Text("\(logManager.entries.count) entries")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .font(.caption)
                        .toggleStyle(.switch)
                        .labelsHidden()

                    Text("Auto-scroll")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))

                // Log entries
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logManager.entries) { entry in
                                logEntryRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: logManager.entries.count) { _ in
                        if autoScroll, let last = logManager.entries.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .background(Color.black)
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Copy button
                    Button {
                        UIPasteboard.general.string = logManager.exportText()
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopied = false
                        }
                    } label: {
                        Label(showCopied ? "Copied!" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                    }

                    // Clear button
                    Button(role: .destructive) {
                        logManager.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func logEntryRow(_ entry: DebugLogManager.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            // Timestamp
            Text(timeString(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)

            // Level icon
            Text(entry.level.rawValue)
                .font(.system(size: 10))

            // Source
            Text("[\(entry.source)]")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(sourceColor(entry.source))

            // Message
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(messageColor(entry.level))
                .lineLimit(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "GeminiLive": return .cyan
        case "Audio": return .yellow
        case "Camera": return .green
        case "VoiceCmd": return .orange
        case "WebSocket": return .purple
        default: return .white
        }
    }

    private func messageColor(_ level: DebugLogManager.LogEntry.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .debug: return .gray
        default: return .white
        }
    }
}
