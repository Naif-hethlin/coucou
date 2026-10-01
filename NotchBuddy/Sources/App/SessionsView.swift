import SwiftUI

// MARK: - Sessions tab
// One card per Claude Code session, the one waiting on you first. Each card
// lists the helper agents running inside it. Tap a card to make Live and
// Progress follow that session; "Auto" follows whichever is acting.

struct SessionsTabView: View {
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        CardBackground(wash: nil) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if store.sessions.isEmpty {
                    Spacer(minLength: 0)
                    Text("No Claude Code sessions yet. They show up here as soon as one does something.")
                        .font(.qimah(size: 12))
                        .foregroundColor(Q.dim)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(store.ordered) { s in
                                SessionCard(session: s, followed: store.followed == s.id, pinned: store.pinned == s.id)
                                    .onTapGesture {
                                        store.follow(store.pinned == s.id ? nil : s.id)
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .live }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sessions")
                    .font(.qimah(size: 13, weight: .semibold))
                    .foregroundColor(Q.text)
                Text(summary)
                    .font(.qimah(size: 11))
                    .foregroundColor(store.needsYou > 0 ? Color(hex: "#FFD28A") : Q.muted)
            }
            Spacer()
            Button(action: { store.follow(nil) }) {
                Text(store.pinned == nil ? "Following: Auto" : "Back to Auto")
                    .font(.qimah(size: 10.5, weight: .semibold))
                    .foregroundColor(store.pinned == nil ? Q.mint : .white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background { if store.pinned == nil { Q.raised } else { Q.gradient } }
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Auto: Live and Progress follow whichever session is acting")
        }
        .padding(.leading, 58)
        .frame(minHeight: 40)
    }

    private var summary: String {
        let n = store.sessions.count
        var s = "\(n) session\(n == 1 ? "" : "s")"
        let agents = store.sessions.reduce(0) { $0 + $1.runningAgents }
        if agents > 0 { s += " · \(agents) agent\(agents == 1 ? "" : "s") running" }
        if store.needsYou > 0 { s += " · \(store.needsYou) need\(store.needsYou == 1 ? "s" : "") you" }
        return s
    }
}

private struct SessionCard: View {
    let session: SessionInfo
    let followed: Bool
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                MiniBotCanvasView(task: mochiTask)
                    .frame(width: 26 / 0.6, height: 26 / 0.6)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? session.project : session.title)
                        .font(.qimah(size: 12, weight: .semibold))
                        .foregroundColor(Q.text)
                        .lineLimit(1)
                    Text("\(session.project) · \(age(session.started))\(session.edits > 0 ? " · \(session.edits) edits" : "")")
                        .font(.qimah(size: 10))
                        .foregroundColor(Q.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(Q.mint)
                }
            }
            HStack(spacing: 6) {
                StateChip(state: session.state)
                Text(session.state == .waiting && !session.waitingFor.isEmpty ? session.waitingFor : session.step)
                    .font(.qimah(size: 10.5))
                    .foregroundColor(Q.soft)
                    .lineLimit(1)
            }
            if let p = session.progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.25))
                        Capsule().fill(Q.gradient).frame(width: g.size.width * CGFloat(p) / 100)
                    }
                }
                .frame(height: 4)
            }
            if !session.agents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.agents.suffix(4)) { a in AgentRow(agent: a, color: session.color) }
                    if session.agents.count > 4 {
                        Text("+\(session.agents.count - 4) earlier agents")
                            .font(.qimah(size: 9.5)).foregroundColor(Q.dim)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Q.deep)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: session.state == .waiting || followed ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var borderColor: Color {
        if session.state == .waiting { return Color(hex: "#F5A524").opacity(0.7) }
        if followed { return Q.mint.opacity(0.55) }
        return Q.border
    }

    private var mochiTask: AgentTask {
        let bot: BotState
        switch session.state {
        case .working: bot = .working
        case .thinking: bot = .thinking
        case .waiting: bot = .approval
        case .done: bot = .finished
        case .idle: bot = .idle
        }
        return AgentTask(id: session.id, name: session.project, color: session.color, state: bot,
                         steps: [], source: .claudeCode)
    }
}

private struct AgentRow: View {
    let agent: AgentRun
    let color: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: color).opacity(agent.state == .running ? 1 : 0.35))
                .frame(width: 6, height: 6)
            Text(agent.task.isEmpty ? agent.type : agent.task)
                .font(.qimah(size: 10, weight: .medium))
                .foregroundColor(agent.state == .running ? Q.text : Q.dim)
                .lineLimit(1)
            Text(agent.state == .running ? (agent.step.isEmpty ? "starting" : agent.step) : "done")
                .font(.qimah(size: 9.5))
                .foregroundColor(agent.state == .running ? Q.muted : Q.dim)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(duration)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Q.dim)
        }
        .help(agent.summary.isEmpty ? agent.type : agent.summary)
    }

    private var duration: String {
        let s = Int((agent.ended ?? Date()).timeIntervalSince(agent.started))
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}

private struct StateChip: View {
    let state: SessionInfo.State

    var body: some View {
        Text(label)
            .font(.qimah(size: 8.5, weight: .bold))
            .tracking(0.4)
            .foregroundColor(fg)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
            .fixedSize()
    }

    private var label: String {
        switch state {
        case .waiting: return "NEEDS YOU"
        case .working: return "WORKING"
        case .thinking: return "THINKING"
        case .done: return "DONE"
        case .idle: return "IDLE"
        }
    }
    private var fg: Color {
        switch state {
        case .waiting: return Color(hex: "#FFD28A")
        case .working: return Color(hex: "#9CCAFF")
        case .thinking: return Color(hex: "#D3C4FF")
        case .done: return Color(hex: "#BDEED6")
        case .idle: return Q.dim
        }
    }
    private var bg: Color {
        switch state {
        case .waiting: return Color(hex: "#F5A524").opacity(0.18)
        case .working: return Color(hex: "#3B9EFF").opacity(0.16)
        case .thinking: return Color(hex: "#A78BFA").opacity(0.18)
        case .done: return Color(hex: "#3FC08A").opacity(0.18)
        case .idle: return Color.white.opacity(0.07)
        }
    }
}

private func age(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}
