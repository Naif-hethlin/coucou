import Foundation
import SwiftUI

// MARK: - Live feed
// Replays what Claude Code is doing, letter by letter, in the Live tab.
// Claude Code sends whole edits (not keystrokes) a moment before applying them,
// so each edit is queued and typed out as it lands, about a second behind.

struct LiveLine: Identifiable, Equatable {
    enum Kind { case context, removed, added, output }
    let id: Int
    let kind: Kind
    let number: Int?
    let text: String
}

struct LiveItem: Identifiable, Equatable {
    enum Kind { case edit, write, command }
    let id = UUID()
    let kind: Kind
    let title: String          // file name or "$ command"
    let path: String           // full path (empty for commands)
    let line: Int?             // first changed line
    let lines: [LiveLine]      // context + removed + added
    let extraLines: Int        // added lines cut off for length
    var why: String
    let added: Int
    let removed: Int

    /// Characters the typewriter has to type for this item.
    var typedChars: Int { lines.filter { $0.kind == .added }.reduce(0) { $0 + $1.text.count } }
}

struct LiveChip: Identifiable, Equatable {
    enum Kind { case read, search, command, edit, write, agent, fail }
    let id = UUID()
    let kind: Kind
    let label: String
    var added: Int = 0
    var removed: Int = 0
    var path: String = ""
    var line: Int? = nil
}

@MainActor
final class LiveFeed: ObservableObject {
    static let shared = LiveFeed()

    enum Phase { case idle, show, strike, typing, hold }

    @Published private(set) var current: LiveItem? = nil
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var typed: Int = 0            // characters typed so far
    @Published private(set) var why: String = ""
    @Published private(set) var chips: [LiveChip] = []
    @Published private(set) var lastEvent: Date = .distantPast

    private var queue: [LiveItem] = []
    private var player: Task<Void, Never>? = nil
    private var commandItemId: UUID? = nil

    private static let maxAddedLines = 40
    private static let contextBefore = 2
    private static let contextAfter = 1

    private init() {}

    /// True while Claude has done something recently: keeps the Live tab open.
    var isActive: Bool {
        phase != .idle || !queue.isEmpty || thought != nil || Date().timeIntervalSince(lastEvent) < 20
    }

    // MARK: - Thinking
    // Claude Code has no "thinking" hook, but the session transcript records each
    // thought. While a turn is running we watch the transcript and type new
    // thoughts out under a THINKING label until Claude acts.

    /// The thought being shown; "" means thinking started but nothing written yet.
    @Published private(set) var thought: String? = nil
    @Published private(set) var thoughtTyped: Int = 0

    private var transcriptPath: String? = nil
    private var watcher: Task<Void, Never>? = nil
    private var lastThoughtId: String? = nil
    private var lastTranscriptSize: UInt64 = 0
    private var thoughtTyper: Task<Void, Never>? = nil

    /// A new prompt: Claude is about to think.
    func userPrompt(transcriptPath: String?) {
        lastEvent = .now
        if let transcriptPath { self.transcriptPath = transcriptPath }
        showThought("")
        startWatching()
    }

    /// Turn finished: stop watching, drop the thought.
    func stopped() {
        thinkGap?.cancel(); thinkGap = nil
        watcher?.cancel(); watcher = nil
        thoughtTyper?.cancel(); thoughtTyper = nil
        thought = nil
    }

    private func startWatching() {
        guard watcher == nil, let path = transcriptPath else { return }
        appendAppLog("nb.log", "Live: watching transcript")
        // Baseline: thoughts already in the transcript aren't news.
        Task.detached(priority: .utility) {
            let latest = Self.lastThought(path)
            await MainActor.run { if self.lastThoughtId == nil { self.lastThoughtId = latest?.id ?? "" } }
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                // Give up after 2 quiet minutes (turn ended without a Stop event).
                if Date().timeIntervalSince(self.lastEvent) > 120 { self.watcher = nil; return }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                guard size != self.lastTranscriptSize else { continue }
                self.lastTranscriptSize = size
                let found = await Task.detached(priority: .utility) { Self.lastThought(path) }.value
                if let found, found.id != self.lastThoughtId, self.lastThoughtId != nil {
                    self.lastThoughtId = found.id
                    self.lastEvent = .now
                    self.showThought(found.text)
                }
            }
        }
    }

    private var thoughtShownAt: Date = .distantPast

    /// After a step finishes, a quiet gap before the next one means Claude is thinking.
    private var thinkGap: Task<Void, Never>? = nil

    private func expectThinking() {
        thinkGap?.cancel()
        thinkGap = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.thought == nil else { return }
            self.showThought("")
        }
    }

    private func endThought() {
        guard thought != nil else { return }
        let shown = thoughtShownAt
        let remaining = 3.0 - Date().timeIntervalSince(shown)
        if remaining <= 0 || thought == "" { thoughtTyper?.cancel(); thoughtTyper = nil; thought = nil; return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, self.thoughtShownAt == shown else { return }   // a newer thought took over
            self.thoughtTyper?.cancel(); self.thoughtTyper = nil; self.thought = nil
        }
    }

    private func showThought(_ text: String) {
        thoughtTyper?.cancel()
        thoughtShownAt = .now
        thought = text
        thoughtTyped = 0
        guard !text.isEmpty else { return }
        thoughtTyper = Task { [weak self] in
            let perTick = max(1, text.count / 90)   // ~1.5s for any length
            while let self, !Task.isCancelled, self.thoughtTyped < text.count {
                try? await Task.sleep(for: .milliseconds(16))
                self.thoughtTyped = min(text.count, self.thoughtTyped + perTick)
            }
        }
    }

    /// Newest thinking block in the transcript (id = entry uuid).
    nonisolated private static func lastThought(_ path: String) -> (id: String, text: String)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 1024 * 1024
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        let chunk = String(decoding: data, as: UTF8.self)
        for line in chunk.split(separator: "\n").reversed() {
            guard line.contains("\"thinking\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "thinking" ? $0["thinking"] as? String : nil }
                .joined(separator: " ")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            let id = obj["uuid"] as? String ?? String(text.prefix(40))
            return (id, text.count > 260 ? String(text.prefix(257)) + "..." : text)
        }
        return nil
    }

    // MARK: - Hook input

    func preToolUse(tool: String, input: [String: Any], transcriptPath: String?) {
        lastEvent = .now
        if let transcriptPath {
            self.transcriptPath = transcriptPath
            refreshWhy(from: transcriptPath)
        }
        thinkGap?.cancel(); thinkGap = nil
        // Acting now: the thought is over, but leave it up long enough to read.
        endThought()
        startWatching()

        switch tool {
        case "Edit":
            guard let path = input["file_path"] as? String else { return }
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            enqueue(Self.editItem(path: path, old: old, new: new, why: why))
        case "MultiEdit":
            guard let path = input["file_path"] as? String,
                  let edits = input["edits"] as? [[String: Any]] else { return }
            for e in edits {
                enqueue(Self.editItem(path: path,
                                      old: e["old_string"] as? String ?? "",
                                      new: e["new_string"] as? String ?? "",
                                      why: why))
            }
        case "Write":
            guard let path = input["file_path"] as? String else { return }
            enqueue(Self.writeItem(path: path, content: input["content"] as? String ?? "", why: why))
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let desc = input["description"] as? String
            let item = Self.commandItem(command: cmd, why: desc ?? why)
            commandItemId = item.id
            enqueue(item)
        case "Read":
            addChip(LiveChip(kind: .read, label: Self.fileName(input["file_path"] as? String)))
        case "Grep", "Glob":
            let q = input["pattern"] as? String ?? ""
            addChip(LiveChip(kind: .search, label: "\"\(String(q.prefix(28)))\""))
        case "Agent", "Task":
            addChip(LiveChip(kind: .agent, label: (input["description"] as? String) ?? "Agent"))
        default:
            break
        }
    }

    func postToolUse(tool: String, response: Any?) {
        lastEvent = .now
        expectThinking()
        guard tool == "Bash", let id = commandItemId else { return }
        commandItemId = nil
        var out = ""
        if let r = response as? [String: Any] {
            out = (r["stdout"] as? String ?? "") + (r["stderr"] as? String ?? "")
        } else if let s = response as? String {
            out = s
        }
        let outLines = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
        guard !outLines.isEmpty else { return }
        let shown = Array(outLines.prefix(8))
        func withOutput(_ item: LiveItem) -> LiveItem {
            var lines = item.lines
            var n = lines.count
            for t in shown { lines.append(LiveLine(id: n, kind: .output, number: nil, text: t)); n += 1 }
            return LiveItem(kind: item.kind, title: item.title, path: item.path, line: item.line,
                            lines: lines, extraLines: outLines.count - shown.count,
                            why: item.why, added: item.added, removed: item.removed)
        }
        if let cur = current, cur.id == id {
            let replaced = withOutput(cur)
            // Keep identity stable for the view by swapping in place.
            current = replaced
        } else if let i = queue.firstIndex(where: { $0.id == id }) {
            queue[i] = withOutput(queue[i])
        }
    }

    func toolFailed() {
        lastEvent = .now
        addChip(LiveChip(kind: .fail, label: "failed"))
    }

    // MARK: - Playback

    private func enqueue(_ item: LiveItem) {
        queue.append(item)
        if queue.count > 6 { queue.removeFirst(queue.count - 6) }
        if player == nil { player = Task { await self.play() } }
    }

    private func play() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            current = item
            typed = 0
            // Commands carry their own description; edits keep the live transcript text.
            if item.kind == .command, !item.why.isEmpty { why = item.why }

            let hurry: Double = (queue.isEmpty ? 1 : 3) * AppState.shared.liveSpeed
            let hasRemoved = item.lines.contains { $0.kind == .removed }

            phase = .show
            try? await Task.sleep(for: .milliseconds(Int(450 / hurry)))
            if hasRemoved {
                phase = .strike
                try? await Task.sleep(for: .milliseconds(Int(500 / hurry)))
            }

            phase = .typing
            let total = item.typedChars
            // At least 45 chars/s so it reads as typing; at most ~2.5s per edit.
            let perSecond = max(45, Double(total) / 2.5) * hurry
            let tick = 1.0 / 60
            var acc = 0.0
            while typed < total {
                try? await Task.sleep(for: .milliseconds(16))
                acc += perSecond * tick
                let step = Int(acc)
                if step > 0 { typed = min(total, typed + step); acc -= Double(step) }
            }

            phase = .hold
            try? await Task.sleep(for: .milliseconds(queue.isEmpty ? 1400 : 300))

            let cur = current ?? item
            addChip(LiveChip(kind: cur.kind == .command ? .command : (cur.kind == .write ? .write : .edit),
                             label: cur.title, added: cur.added, removed: cur.removed,
                             path: cur.path, line: cur.line))
        }
        phase = .idle
        player = nil
    }

    private func addChip(_ chip: LiveChip) {
        chips.insert(chip, at: 0)
        if chips.count > 12 { chips.removeLast(chips.count - 12) }
    }

    /// Bring a finished edit back into the big card.
    func replay(_ chip: LiveChip) {
        guard !chip.path.isEmpty, let data = FileManager.default.contents(atPath: chip.path),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = text
        // Re-show it as a static view of where the edit landed.
        let lines = text.components(separatedBy: "\n")
        let start = max(0, (chip.line ?? 1) - 1 - Self.contextBefore)
        let end = min(lines.count, start + Self.contextBefore + max(1, chip.added) + Self.contextAfter)
        var out: [LiveLine] = []
        for i in start..<end {
            let inEdit = i >= (chip.line ?? 1) - 1 && i < (chip.line ?? 1) - 1 + chip.added
            out.append(LiveLine(id: i, kind: inEdit ? .added : .context, number: i + 1, text: lines[i]))
        }
        let item = LiveItem(kind: .edit, title: chip.label, path: chip.path, line: chip.line,
                            lines: out, extraLines: 0, why: "", added: chip.added, removed: chip.removed)
        player?.cancel(); player = nil; queue.removeAll()
        current = item
        typed = item.typedChars
        phase = .hold
        Task { try? await Task.sleep(for: .seconds(4)); if self.player == nil { self.phase = .idle } }
    }

    // MARK: - Building items

    private static func fileName(_ path: String?) -> String {
        guard let path else { return "file" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func splitLines(_ s: String) -> [String] {
        var parts = s.components(separatedBy: "\n")
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Reads the file BEFORE the edit is applied (PreToolUse) to find where it lands.
    private static func editItem(path: String, old: String, new: String, why: String) -> LiveItem {
        let fileText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var startLine = 1
        var before: [String] = []
        var after: [String] = []
        if !old.isEmpty, let r = fileText.range(of: old) {
            let prefix = fileText[fileText.startIndex..<r.lowerBound]
            startLine = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let all = fileText.components(separatedBy: "\n")
            let first = startLine - 1
            let oldCount = splitLines(old).count
            before = Array(all[max(0, first - contextBefore)..<min(first, all.count)])
            let afterStart = min(all.count, first + oldCount)
            after = Array(all[afterStart..<min(all.count, afterStart + contextAfter)])
        }

        var lines: [LiveLine] = []
        var id = 0
        var n = startLine - before.count
        for t in before { lines.append(LiveLine(id: id, kind: .context, number: n, text: t)); id += 1; n += 1 }
        let oldLines = old.isEmpty ? [] : splitLines(old)
        var newLines = new.isEmpty ? [] : splitLines(new)
        let extra = max(0, newLines.count - maxAddedLines)
        if extra > 0 { newLines = Array(newLines.prefix(maxAddedLines)) }
        for t in oldLines { lines.append(LiveLine(id: id, kind: .removed, number: n, text: t)); id += 1; n += 1 }
        var m = startLine
        for t in newLines { lines.append(LiveLine(id: id, kind: .added, number: m, text: t)); id += 1; m += 1 }
        var k = m + extra
        for t in after { lines.append(LiveLine(id: id, kind: .context, number: k, text: t)); id += 1; k += 1 }

        return LiveItem(kind: .edit, title: fileName(path), path: path, line: startLine,
                        lines: lines, extraLines: extra, why: why,
                        added: splitLines(new).count, removed: oldLines.count)
    }

    private static func writeItem(path: String, content: String, why: String) -> LiveItem {
        var all = splitLines(content)
        let extra = max(0, all.count - maxAddedLines)
        if extra > 0 { all = Array(all.prefix(maxAddedLines)) }
        let lines = all.enumerated().map { LiveLine(id: $0.offset, kind: .added, number: $0.offset + 1, text: $0.element) }
        return LiveItem(kind: .write, title: fileName(path), path: path, line: 1,
                        lines: lines, extraLines: extra, why: why,
                        added: all.count + extra, removed: 0)
    }

    private static func commandItem(command: String, why: String) -> LiveItem {
        let cmdLines = splitLines(command).prefix(6)
        let lines = cmdLines.enumerated().map { LiveLine(id: $0.offset, kind: .added, number: nil, text: $0.element) }
        let short = String(command.split(separator: "\n").first ?? "").prefix(48)
        return LiveItem(kind: .command, title: "$ " + short, path: "", line: nil,
                        lines: lines, extraLines: 0, why: why, added: 0, removed: 0)
    }

    // MARK: - "What Claude is doing" from the session transcript

    private func refreshWhy(from transcriptPath: String) {
        Task.detached(priority: .utility) {
            guard let text = Self.lastAssistantText(transcriptPath) else { return }
            await MainActor.run {
                if self.why != text { self.why = text }
            }
        }
    }

    /// Last text Claude wrote in the session, trimmed to a readable line.
    nonisolated private static func lastAssistantText(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // Screenshots and big tool results bloat the transcript, so widen the
        // window until a text message turns up (cap 16 MB).
        var window: UInt64 = 256 * 1024
        while true {
            try? fh.seek(toOffset: size > window ? size - window : 0)
            guard let data = try? fh.readToEnd() else { return nil }
            // Lossy decode: the window can start mid-character.
            if let found = lastText(in: String(decoding: data, as: UTF8.self)) { return found }
            if window >= size || window >= 16 * 1024 * 1024 { return nil }
            window *= 4
        }
    }

    nonisolated private static func lastText(in chunk: String) -> String? {
        for line in chunk.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
            let clean = text
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: " ")
            guard !clean.isEmpty else { continue }
            return clean.count > 180 ? String(clean.prefix(177)) + "..." : clean
        }
        return nil
    }
}
