import Foundation
import SwiftUI

// MARK: - Sessions
// Coucou used to fold every Claude Code session into one "VS Code" pill. This
// tracks each session on its own (name, project, state, current step) plus the
// helper agents running inside it: every hook event carries session_id, and
// events from a subagent also carry agent_id / agent_type.

struct AgentRun: Identifiable, Equatable {
    enum State { case running, done }
    let id: String
    let type: String
    var task: String            // what it was asked to do (Agent tool description)
    var state: State = .running
    var step: String = ""
    var steps: Int = 0
    let started: Date
    var ended: Date? = nil
    var summary: String = ""    // its final message
}

struct SessionInfo: Identifiable, Equatable {
    enum State: Int { case waiting = 0, working, thinking, done, idle }   // sort order
    let id: String
    var title: String
    var project: String
    var cwd: String
    var color: String
    var state: State = .idle
    var step: String = ""
    var waitingFor: String = ""
    let started: Date
    var lastEvent: Date
    var agents: [AgentRun] = []
    var edits: Int = 0
    var progress: Int? = nil     // overall % when this session wrote the status file

    var runningAgents: Int { agents.filter { $0.state == .running }.count }
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [SessionInfo] = []
    /// Session Live and Progress follow. nil = Auto (whichever is acting).
    @Published var pinned: String? = nil
    @Published private(set) var autoFollow: String? = nil

    private static let palette = ["#7FD3AD", "#F5A524", "#A78BFA", "#5B8CFF", "#F472B6", "#22D3EE", "#F29B38"]
    private var colorIndex = 0
    private var pendingAgentTasks: [String: [String]] = [:]   // session → Agent descriptions awaiting a SubagentStart
    private var thinkTimers: [String: Task<Void, Never>] = [:]

    private init() {
        // Drop sessions quiet for 3 hours.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                let cutoff = Date().addingTimeInterval(-3 * 3600)
                SessionStore.shared.sessions.removeAll { $0.lastEvent < cutoff }
            }
        }
    }

    var followed: String? { pinned ?? autoFollow }

    var needsYou: Int { sessions.filter { $0.state == .waiting }.count }

    var ordered: [SessionInfo] {
        sessions.sorted { a, b in
            if a.state != b.state { return a.state.rawValue < b.state.rawValue }
            return a.lastEvent > b.lastEvent
        }
    }

    func session(_ id: String?) -> SessionInfo? { sessions.first { $0.id == id } }

    // MARK: - Routing

    /// Whether this session's events should drive Live/Progress right now.
    /// Auto sticks to one session while it's busy, and moves on after 8 quiet seconds.
    func shouldFollow(_ sessionId: String) -> Bool {
        if let pinned { return pinned == sessionId }
        if let cur = autoFollow, cur != sessionId,
           let s = session(cur), Date().timeIntervalSince(s.lastEvent) < 8 {
            return false
        }
        autoFollow = sessionId
        return true
    }

    func follow(_ id: String?) { pinned = id }

    // MARK: - Events

    func handle(event: String, payload: [String: Any]) {
        let sid = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let agentId = payload["agent_id"] as? String
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        var s = upsert(sid, cwd: cwd, transcript: payload["transcript_path"] as? String)
        s.lastEvent = .now

        switch event {
        case "UserPromptSubmit":
            s.state = .thinking
            s.waitingFor = ""
            if s.title.isEmpty, let p = payload["prompt"] as? String { s.title = Self.short(p, 44) }
            s.step = "Reading your message"

        case "PreToolUse":
            thinkTimers[sid]?.cancel()
            let label = Self.stepLabel(tool: tool, input: input)
            if let agentId, let i = s.agents.firstIndex(where: { $0.id == agentId }) {
                s.agents[i].step = label
                s.agents[i].steps += 1
            } else {
                s.step = label
                s.state = .working
                s.waitingFor = ""
            }
            if tool == "Agent" || tool == "Task" {
                pendingAgentTasks[sid, default: []].append(input["description"] as? String ?? "Agent")
            }
            if tool == "AskUserQuestion", agentId == nil {
                s.state = .waiting
                s.waitingFor = "Answer: " + (((input["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? "a question")
            }
            if ["Edit", "MultiEdit", "Write"].contains(tool) { s.edits += 1 }
            if let cmd = input["command"] as? String, cmd.contains("coucou/progress.md") {
                markProgressOwner(sid)
            }

        case "PostToolUse", "PostToolUseFailure":
            if agentId == nil {
                if s.state == .waiting { s.state = .working; s.waitingFor = "" }
                // A quiet gap after a step means the main session is thinking.
                thinkTimers[sid]?.cancel()
                thinkTimers[sid] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard let self, !Task.isCancelled else { return }
                    self.update(sid) { if $0.state == .working { $0.state = .thinking; $0.step = "Thinking" } }
                }
            }

        case "SubagentStart":
            if let agentId {
                let task = pendingAgentTasks[sid]?.isEmpty == false ? pendingAgentTasks[sid]!.removeFirst() : ""
                s.agents.append(AgentRun(id: agentId, type: payload["agent_type"] as? String ?? "agent",
                                         task: task, started: .now))
            }

        case "SubagentStop":
            if let agentId, let i = s.agents.firstIndex(where: { $0.id == agentId }) {
                s.agents[i].state = .done
                s.agents[i].ended = .now
                s.agents[i].step = "Finished"
                s.agents[i].summary = Self.short(payload["last_assistant_message"] as? String ?? "", 120)
            }

        case "Notification":
            let msg = payload["message"] as? String ?? ""
            let lower = msg.lowercased()
            if lower.contains("permission") || lower.contains("waiting for your input") || msg.hasSuffix("?") {
                s.state = .waiting
                s.waitingFor = Self.short(msg, 80)
            }

        case "Stop":
            thinkTimers[sid]?.cancel()
            if s.state != .waiting { s.state = .done }
            s.step = "Finished, your turn"
            // Agents still marked running when the turn ends are done.
            for i in s.agents.indices where s.agents[i].state == .running {
                s.agents[i].state = .done; s.agents[i].ended = .now
            }

        case "SessionEnd":
            sessions.removeAll { $0.id == sid }
            if pinned == sid { pinned = nil }
            if autoFollow == sid { autoFollow = nil }
            return

        default:
            break
        }
        store(s)
    }

    /// The session that last wrote ~/.claude/coucou/progress.md owns the Progress tab's numbers.
    @Published private(set) var progressOwner: String? = nil
    private func markProgressOwner(_ sid: String) { progressOwner = sid }

    func setProgress(_ pct: Int?) {
        guard let owner = progressOwner else { return }
        update(owner) { $0.progress = pct }
    }

    // MARK: - Helpers

    private func upsert(_ sid: String, cwd: String, transcript: String?) -> SessionInfo {
        if let s = session(sid) { return s }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let color = Self.palette[colorIndex % Self.palette.count]
        colorIndex += 1
        var s = SessionInfo(id: sid, title: "", project: project.isEmpty ? "Session" : project, cwd: cwd,
                            color: color, started: .now, lastEvent: .now)
        sessions.append(s)
        if let transcript {
            Task.detached(priority: .utility) {
                let t = Self.title(fromTranscript: transcript)
                await MainActor.run { if let t { SessionStore.shared.update(sid) { $0.title = t } } }
            }
        }
        return s
    }

    private func store(_ s: SessionInfo) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
    }

    private func update(_ sid: String, _ f: (inout SessionInfo) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        f(&sessions[i])
    }

    /// Claude Code's own title for the session (renamed title wins), from the transcript.
    nonisolated private static func title(fromTranscript path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var ai: String? = nil, custom: String? = nil
        for line in text.split(separator: "\n") where line.contains("-title\"") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let t = o["customTitle"] as? String { custom = t }
            if let t = o["aiTitle"] as? String { ai = t }
        }
        return custom ?? ai
    }

    nonisolated static func short(_ s: String, _ n: Int) -> String {
        let one = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    static func stepLabel(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit": return "Editing \(file ?? "a file")"
        case "Write":             return "Writing \(file ?? "a file")"
        case "Read":              return "Reading \(file ?? "a file")"
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            return "Running " + short(input["command"] as? String ?? "a command", 40)
        case "Grep", "Glob":      return "Searching " + short(input["pattern"] as? String ?? "", 30)
        case "Agent", "Task":     return "Starting agent: " + short(input["description"] as? String ?? "", 40)
        case "WebFetch", "WebSearch": return "Looking on the web"
        case "AskUserQuestion":   return "Asking you a question"
        case "SubagentHandback":  return "Reporting back"
        case "TodoWrite":         return "Updating its to-do list"
        default:                  return tool
        }
    }
}
