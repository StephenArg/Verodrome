import SwiftUI
import UIKit
import VerodromeKit

struct EventLogView: View {
    @State private var entries: [EventLogger.LogEntrySnapshot] = []
    @State private var filter: EventLogger.LogLevel? = nil
    @State private var shareText: String = ""
    @State private var showShare = false

    private var filtered: [EventLogger.LogEntrySnapshot] {
        guard let filter else { return entries.reversed() }
        return entries.filter { $0.level == filter }.reversed()
    }

    var body: some View {
        List {
            Section {
                Picker("Severity", selection: $filter) {
                    Text("All").tag(Optional<EventLogger.LogLevel>.none)
                    Text("Debug").tag(Optional.some(EventLogger.LogLevel.debug))
                    Text("Info").tag(Optional.some(EventLogger.LogLevel.info))
                    Text("Warning").tag(Optional.some(EventLogger.LogLevel.warning))
                    Text("Error").tag(Optional.some(EventLogger.LogLevel.error))
                }
                .pickerStyle(.segmented)
            }

            Section("Entries") {
                if filtered.isEmpty {
                    Text("No log entries").foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Event Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh") { Task { await reload() } }
                    Button("Export…") { Task { await export() } }
                    Button("Clear", role: .destructive) {
                        Task {
                            await EventLogger.shared.clear()
                            await reload()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: [shareText])
        }
    }

    private func reload() async {
        entries = await EventLogger.shared.recentEntries(limit: 500)
    }

    private func export() async {
        let lines = filtered.map {
            "[\($0.timestamp.ISO8601Format())][\($0.level.rawValue)][\($0.category)] \($0.message)"
        }
        shareText = lines.joined(separator: "\n")
        showShare = true
    }

    private func color(for level: EventLogger.LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
