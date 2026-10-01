import Foundation
import AppKit

// MARK: - Progress tab
// Progress inside the current PR or task, in the update-and-status shape:
// one row per sub-task with a bar, an overall %, and Done / Now / Next / Blocked.
//
// Sources, merged:
//  1. The latest status chart Claude wrote in the session (rows like
//     "CI  ██████░░░░  60%  note"), read from the transcript.
//  2. The PR Claude is working on (last github.com/…/pull/N seen), polled with
//     `gh pr view` every minute: CI checks, review, mergeable.
//  3. Claude's to-do list, when it keeps one (TodoWrite).

struct ProgressRow: Identifiable, Equatable, Sendable {
    enum State: Sendable { case done, now, todo, blocked }
    var id: String { name.lowercased() }
    let name: String
    let pct: Int?             // nil = not applicable
    let note: String
    let state: State
}

struct PRInfo: Equatable, Sendable {
    let repo: String          // owner/name
    let number: Int
    var title: String = ""
    var url: String { "https://github.com/\(repo)/pull/\(number)" }
}

@MainActor
final class ProgressStore: ObservableObject {
    static let shared = ProgressStore()

    @Published private(set) var headline: String = ""
    @Published private(set) var chartRows: [ProgressRow] = []
    @Published private(set) var prRows: [ProgressRow] = []
    @Published private(set) var todoRows: [ProgressRow] = []
    @Published private(set) var done: [String] = []
    @Published private(set) var now: [String] = []
    @Published private(set) var next: [String] = []
    @Published private(set) var blocked: [String] = []
    @Published private(set) var pr: PRInfo? = nil
    @Published private(set) var updatedAt: Date? = nil

    private var transcriptPath: String? = nil
    private var lastSize: UInt64 = 0
    private var prTimer: Timer? = nil
    private var lastPRPoll: Date = .distantPast

    /// Claude writes its status chart here (update-and-status skill); checked every 2s.
    static let statusFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/coucou/progress.md").path
    private var statusFileDate: Date? = nil
    private var fileTimer: Timer? = nil

    private init() {}

    func start() {
        readStatusFile()
        fileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in ProgressStore.shared.readStatusFile() }
        }
    }

    private func readStatusFile() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.statusFile),
              let mod = attrs[.modificationDate] as? Date, mod != statusFileDate,
              let text = try? String(contentsOfFile: Self.statusFile, encoding: .utf8) else { return }
        statusFileDate = mod
        var p = Self.parse(text)
        p.prURLs = Self.prURLs(in: text)
        apply(p)
        updatedAt = mod
    }

    // MARK: - Rows shown

    /// Chart rows first; PR rows only when the chart doesn't already cover them; then todos.
    var rows: [ProgressRow] {
        var out = chartRows
        let names = chartRows.map { $0.name.lowercased() }
        for r in prRows where !names.contains(where: { $0.contains(r.name.lowercased()) }) { out.append(r) }
        out.append(contentsOf: todoRows)
        return out
    }

    /// From Claude's own chart when there is one (PR rows are context, not the plan).
    var overall: Int? {
        let vals = (chartRows.isEmpty ? rows : chartRows).compactMap(\.pct)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / vals.count
    }

    var isEmpty: Bool { rows.isEmpty && headline.isEmpty }

    // MARK: - Hook input

    func note(transcriptPath: String?) {
        if let transcriptPath { self.transcriptPath = transcriptPath }
        rescan()
    }

    func preToolUse(tool: String, input: [String: Any]) {
        if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            todoRows = todos.map {
                let status = $0["status"] as? String ?? "pending"
                let text = ($0[status == "in_progress" ? "activeForm" : "content"] as? String)
                    ?? $0["content"] as? String ?? ""
                switch status {
                case "completed":   return ProgressRow(name: text, pct: 100, note: "", state: .done)
                case "in_progress": return ProgressRow(name: text, pct: 50, note: "", state: .now)
                default:            return ProgressRow(name: text, pct: 0, note: "", state: .todo)
                }
            }
            updatedAt = .now
        }
        if let cmd = input["command"] as? String { notePR(in: cmd) }
    }

    func postToolUse(response: Any?) {
        if let r = response as? [String: Any], let out = r["stdout"] as? String { notePR(in: out) }
        else if let s = response as? String { notePR(in: s) }
    }

    // MARK: - Status chart from the transcript

    private func rescan() {
        guard let path = transcriptPath else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard size != lastSize else { return }
        lastSize = size
        Task.detached(priority: .utility) {
            let found = Self.latestStatus(path)
            await MainActor.run { if let found { self.apply(found) } }
        }
    }

    struct Parsed: Sendable {
        var headline = ""
        var rows: [ProgressRow] = []
        var done: [String] = [], now: [String] = [], next: [String] = [], blocked: [String] = []
        var prURLs: [String] = []
    }

    private func apply(_ p: Parsed) {
        if !p.rows.isEmpty {
            chartRows = p.rows
            headline = p.headline
                .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            done = p.done; now = p.now; next = p.next; blocked = p.blocked
            updatedAt = .now
        }
        if let last = p.prURLs.last { notePR(in: last) }
    }

    /// Newest assistant message that contains a progress chart (█/░ bars).
    nonisolated private static func latestStatus(_ path: String) -> Parsed? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var window: UInt64 = 1024 * 1024
        var prURLs: [String] = []
        while true {
            try? fh.seek(toOffset: size > window ? size - window : 0)
            guard let data = try? fh.readToEnd() else { return nil }
            let chunk = String(decoding: data, as: UTF8.self)
            var texts: [String] = []
            for line in chunk.split(separator: "\n") where line.contains("\"assistant\"") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]] else { continue }
                let t = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                if !t.isEmpty { texts.append(t) }
            }
            for t in texts { prURLs.append(contentsOf: Self.prURLs(in: t)) }
            if let chart = texts.last(where: { $0.contains("█") || $0.contains("░") }) {
                var p = parse(chart)
                p.prURLs = prURLs
                return p
            }
            if window >= size || window >= 16 * 1024 * 1024 {
                var p = Parsed(); p.prURLs = prURLs
                return prURLs.isEmpty ? nil : p
            }
            window *= 4
        }
    }

    nonisolated static func prURLs(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"github\.com/[\w.-]+/[\w.-]+/pull/\d+"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Parses the update-and-status shape: headline, chart rows, Done/Now/Next/Blocked.
    nonisolated static func parse(_ text: String) -> Parsed {
        var p = Parsed()
        let rowRE = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+([█░▓▒]{4,})\s+(\d{1,3})%\s*(.*)$"#)
        var section: String? = nil
        var sawChart = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            if let m = rowRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                sawChart = true
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let pct = Int(ns.substring(with: m.range(at: 3))) ?? 0
                let note = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let lower = (name + " " + note).lowercased()
                let state: ProgressRow.State =
                    lower.contains("blocked") || lower.contains("stopped") ? .blocked :
                    pct >= 100 ? .done : (pct > 0 ? .now : .todo)
                p.rows.append(ProgressRow(name: name, pct: pct, note: note, state: state))
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("|") { continue }
            if p.headline.isEmpty, !sawChart, !line.isEmpty {
                p.headline = Self.clean(line)
                continue
            }
            // Section headers: "**Done since last update**", "Now:", "### Next", "Blocked or waiting on you - x"
            let bare = Self.clean(line)
            let key = bare.lowercased()
            let heads = ["done", "now", "next", "blocked"]
            if let h = heads.first(where: { key.hasPrefix($0) && (key.count == $0.count || !key[key.index(key.startIndex, offsetBy: $0.count)].isLetter) }) {
                section = h
                // Inline content after ":" or " - " on the header line
                if let r = bare.range(of: ":") ?? bare.range(of: " - ") {
                    let rest = bare[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { add(rest, to: h, &p) }
                }
                continue
            }
            if line.isEmpty { continue }
            if let s = section, line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") || line.first?.isNumber == true {
                let item = Self.clean(String(line.drop { "-•* 0123456789.)".contains($0) }))
                if !item.isEmpty { add(item, to: s, &p) }
            }
        }
        return p
    }

    nonisolated private static func add(_ s: String, to section: String, _ p: inout Parsed) {
        switch section {
        case "done": p.done.append(s)
        case "now": p.now.append(s)
        case "next": p.next.append(s)
        default: p.blocked.append(s)
        }
    }

    nonisolated private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
         .replacingOccurrences(of: "`", with: "")
         .trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    // MARK: - Live PR state (gh)

    private func notePR(in text: String) {
        guard let url = Self.prURLs(in: text).last else { return }
        let parts = url.split(separator: "/")
        guard parts.count >= 5, let n = Int(parts[4]) else { return }
        let info = PRInfo(repo: "\(parts[1])/\(parts[2])", number: n)
        guard info.repo != pr?.repo || info.number != pr?.number else { return }
        pr = info
        prRows = []
        pollPR()
        prTimer?.invalidate()
        prTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ProgressStore.shared.pollPR() }
        }
    }

    func pollPR() {
        guard let pr else { return }
        let target = pr
        Task.detached(priority: .utility) {
            guard let json = Self.gh(["pr", "view", "\(target.number)", "--repo", target.repo, "--json",
                                      "title,state,mergeable,reviewDecision,statusCheckRollup,headRefOid"]) else { return }
            let rows = Self.prRows(from: json)
            let title = json["title"] as? String ?? ""
            await MainActor.run {
                guard self.pr?.number == target.number, self.pr?.repo == target.repo else { return }
                self.pr?.title = title
                self.prRows = rows
                self.updatedAt = .now
            }
        }
    }

    nonisolated private static func prRows(from j: [String: Any]) -> [ProgressRow] {
        var rows: [ProgressRow] = []
        let head = String((j["headRefOid"] as? String ?? "").prefix(7))

        // CI
        let checks = j["statusCheckRollup"] as? [[String: Any]] ?? []
        if checks.isEmpty {
            rows.append(ProgressRow(name: "CI", pct: nil, note: "no checks on this repo", state: .todo))
        } else {
            let concl = checks.map { (($0["conclusion"] as? String) ?? ($0["state"] as? String) ?? "").uppercased() }
            let ok = concl.filter { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0) }.count
            let bad = concl.filter { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].contains($0) }.count
            let pct = checks.isEmpty ? 0 : ok * 100 / checks.count
            let note = bad > 0 ? "\(bad) failing on \(head)" : (ok == checks.count ? "green on \(head)" : "\(checks.count - ok) running")
            rows.append(ProgressRow(name: "CI", pct: pct, note: note, state: bad > 0 ? .blocked : (pct == 100 ? .done : .now)))
        }

        // Review
        switch j["reviewDecision"] as? String ?? "" {
        case "APPROVED":          rows.append(ProgressRow(name: "Review", pct: 100, note: "approved", state: .done))
        case "CHANGES_REQUESTED": rows.append(ProgressRow(name: "Review", pct: 50, note: "changes requested", state: .blocked))
        case "REVIEW_REQUIRED":   rows.append(ProgressRow(name: "Review", pct: 0, note: "waiting for review", state: .todo))
        default:                  rows.append(ProgressRow(name: "Review", pct: 0, note: "not reviewed", state: .todo))
        }

        // Merge
        let state = j["state"] as? String ?? ""
        let mergeable = j["mergeable"] as? String ?? ""
        if state == "MERGED" {
            rows.append(ProgressRow(name: "Merge", pct: 100, note: "merged", state: .done))
        } else if mergeable == "CONFLICTING" {
            rows.append(ProgressRow(name: "Merge", pct: 0, note: "has conflicts", state: .blocked))
        } else {
            rows.append(ProgressRow(name: "Merge", pct: 0, note: mergeable == "MERGEABLE" ? "ready to merge" : "not yet", state: .todo))
        }
        return rows
    }

    /// Runs the GitHub CLI (GUI apps don't get the shell PATH, so look in the usual places).
    nonisolated private static func gh(_ args: [String]) -> [String: Any]? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func openPR() {
        if let pr, let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
    }
}
