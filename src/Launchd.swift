import SwiftUI
import AppKit

/// One launchd job as reported by `launchctl list` (current user/GUI domain).
struct LaunchdJob: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let pid: Int?        // nil when loaded but not running
    let lastExit: Int    // last exit status (0 = clean)
    var isRunning: Bool { pid != nil }
    var isApple: Bool { label.hasPrefix("com.apple.") }
}

enum Launchd {
    /// Read-only snapshot of launchd jobs. We never load/unload/kill anything.
    static func list() -> [LaunchdJob] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["list"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var jobs: [LaunchdJob] = []
        for line in text.split(separator: "\n").dropFirst() {   // drop "PID Status Label" header
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            jobs.append(LaunchdJob(
                label: String(cols[2]),
                pid: Int(cols[0]),                 // nil if "-"
                lastExit: Int(cols[1]) ?? 0))
        }
        return jobs.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }
}

enum LFilter: String, CaseIterable, Identifiable {
    case running = "Running", all = "All", thirdParty = "Third-party"
    var id: String { rawValue }
}

struct LaunchdView: View {
    @State private var jobs: [LaunchdJob] = []
    @State private var search = ""
    @State private var filter: LFilter = .running
    @State private var toast: String?

    private var filtered: [LaunchdJob] {
        jobs.filter { j in
            switch filter {
            case .running where !j.isRunning: return false
            case .thirdParty where j.isApple: return false
            default: break
            }
            return search.isEmpty || j.label.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(jobs.isEmpty ? "Loading…" : "Nothing matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { row($0) }
                    .listStyle(.inset)
            }
            Divider()
            Text("Read-only. Shows your user (GUI) launchd domain via `launchctl list`. System daemons need root and aren’t listed.")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(.tint)
            Text("launchd").font(.headline)
            Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search label", text: $search)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 150, maxWidth: 240)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Picker("", selection: $filter) {
                ForEach(LFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()

            Button(action: load) { Image(systemName: "arrow.clockwise") }.help("Reload")
        }
        .padding(12)
    }

    @ViewBuilder
    private func row(_ job: LaunchdJob) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(job.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.label)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(job.isRunning ? "PID \(job.pid!)" : "not running")
                        .foregroundStyle(.secondary)
                    if job.lastExit != 0 {
                        Text("last exit \(job.lastExit)").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            if !job.isApple {
                Text("THIRD-PARTY")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Button("Copy") { copy(job.label) }.frame(width: 56)
        }
        .padding(.vertical, 3)
    }

    private var toastView: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(radius: 8, y: 3).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Launchd.list()
            DispatchQueue.main.async { jobs = result }
        }
    }

    private func copy(_ label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
        toast = "Copied label"
        let stamp = "Copied label"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == stamp { toast = nil }
        }
    }
}
