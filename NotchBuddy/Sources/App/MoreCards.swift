import Foundation
import SwiftUI
import AppKit

// MARK: - Shared: run the GitHub CLI (GUI apps don't get the shell PATH)

func runGH(_ args: [String]) -> Data? {
    let bins = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    guard let bin = bins.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

private func relative(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    let f = DateFormatter(); f.dateFormat = "EEEE H:mm"
    return f.string(from: d)
}

// MARK: - GitHub: My PRs

struct MyPR: Identifiable, Equatable, Sendable {
    var id: String { url }
    let number: Int
    let title: String
    let url: String
    let repo: String
    let ci: String          // SUCCESS / FAILURE / ERROR / PENDING / EXPECTED / none
    let review: String
    let draft: Bool
}

@MainActor
final class GitHubPRStore: ObservableObject {
    static let shared = GitHubPRStore()
    @Published private(set) var prs: [MyPR] = []
    @Published private(set) var loaded = false
    private var timer: Timer?
    private init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in GitHubPRStore.shared.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let q = """
            query { search(query:"is:pr is:open author:@me archived:false sort:updated-desc", type:ISSUE, first:12){ nodes{ ... on PullRequest { number title url isDraft reviewDecision repository{name} commits(last:1){nodes{commit{statusCheckRollup{state}}}} } } } }
            """
            guard let data = runGH(["api", "graphql", "-f", "query=\(q)"]),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = ((j["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [[String: Any]]
            else { return }
            let prs: [MyPR] = nodes.compactMap { n in
                guard let num = n["number"] as? Int else { return nil }
                let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
                let ci = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String ?? "none"
                return MyPR(number: num, title: n["title"] as? String ?? "", url: n["url"] as? String ?? "",
                            repo: (n["repository"] as? [String: Any])?["name"] as? String ?? "",
                            ci: ci, review: n["reviewDecision"] as? String ?? "", draft: n["isDraft"] as? Bool ?? false)
            }
            await MainActor.run { GitHubPRStore.shared.prs = prs; GitHubPRStore.shared.loaded = true }
        }
    }
}

struct GitHubPRCardView: View {
    @ObservedObject private var store = GitHubPRStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#F4505E")).frame(width: 7, height: 7)
                Text("GitHub").font(.qimah(size: 12, weight: .semibold)).foregroundColor(Q.text)
                Text(store.loaded ? "\(store.prs.count) open PRs" : "loading…")
                    .font(.qimah(size: 11)).foregroundColor(Q.muted)
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.prs) { pr in
                        Button(action: { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }) {
                            HStack(spacing: 7) {
                                Circle().fill(ciColor(pr.ci)).frame(width: 6, height: 6)
                                Text("#\(pr.number) \(pr.title)")
                                    .font(.qimah(size: 10.5))
                                    .foregroundColor(pr.draft ? Q.dim : Q.soft)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(pr.repo).font(.qimah(size: 9.5)).foregroundColor(Q.dim).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(ciHelp(pr))
                    }
                }
            }
            .padding(.top, 5).padding(.leading, 108).padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    private func ciColor(_ s: String) -> Color {
        switch s {
        case "SUCCESS": return Q.add
        case "FAILURE", "ERROR": return Q.del
        case "PENDING", "EXPECTED": return Color(hex: "#F5A524")
        default: return Q.dim
        }
    }

    private func ciHelp(_ pr: MyPR) -> String {
        let ci = pr.ci == "none" ? "no checks" : pr.ci.lowercased()
        return "\(pr.repo) #\(pr.number) · CI \(ci)\(pr.review.isEmpty ? "" : " · " + pr.review.lowercased().replacingOccurrences(of: "_", with: " "))"
    }
}

// MARK: - Claude usage (from the status line script)

struct UsageWindow: Equatable { let pct: Double; let resets: Date? }

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/coucou/usage.json").path

    @Published private(set) var fiveHour: UsageWindow? = nil
    @Published private(set) var week: UsageWindow? = nil
    @Published private(set) var model: String = ""
    @Published private(set) var savedAt: Date? = nil
    private var lastMod: Date? = nil
    private var timer: Timer?
    private init() {}

    func start() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.read() }
        }
    }

    private func read() {
        guard let mod = (try? FileManager.default.attributesOfItem(atPath: Self.file))?[.modificationDate] as? Date,
              mod != lastMod,
              let data = FileManager.default.contents(atPath: Self.file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lastMod = mod
        let rl = j["rate_limits"] as? [String: Any] ?? [:]
        func window(_ k: String) -> UsageWindow? {
            guard let w = rl[k] as? [String: Any], let p = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(pct: p, resets: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        fiveHour = window("five_hour")
        week = window("seven_day")
        model = j["model"] as? String ?? ""
        savedAt = mod
    }

    /// Highest of the two windows, for the notch warning.
    var peak: Double { max(fiveHour?.pct ?? 0, week?.pct ?? 0) }
}

struct ClaudeUsageCardView: View {
    @ObservedObject private var store = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#D97757")).frame(width: 7, height: 7)
                Text("Claude usage").font(.qimah(size: 12, weight: .semibold)).foregroundColor(Q.text)
                if !store.model.isEmpty {
                    Text(store.model).font(.qimah(size: 11)).foregroundColor(Q.muted)
                }
            }
            if store.fiveHour == nil && store.week == nil {
                Text("Waiting for Claude Code's status line. It updates after Claude's next reply.")
                    .font(.qimah(size: 10.5)).foregroundColor(Q.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                bar("5 hours", store.fiveHour)
                bar("This week", store.week)
                Text(resets).font(.qimah(size: 10)).foregroundColor(Q.dim).lineLimit(1)
            }
        }
        .padding(.top, 8).padding(.leading, 108).padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bar(_ label: String, _ w: UsageWindow?) -> some View {
        let pct = w?.pct ?? 0
        let color: AnyShapeStyle = pct >= 90 ? AnyShapeStyle(Q.del) : pct >= 70 ? AnyShapeStyle(Color(hex: "#F5A524")) : AnyShapeStyle(Q.gradient)
        return HStack(spacing: 8) {
            Text(label).font(.qimah(size: 10.5)).foregroundColor(Q.soft).frame(width: 62, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Q.deep)
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(min(pct, 100)) / 100)
                }
            }
            .frame(height: 6)
            Text(w == nil ? "n/a" : "\(Int(pct.rounded()))%")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(Q.muted)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var resets: String {
        var parts: [String] = []
        if let r = store.fiveHour?.resets { parts.append("5h resets in \(relative(r))") }
        if let r = store.week?.resets { parts.append("week resets \(relative(r))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - ClickUp: Due list

struct CUTask: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let statusColor: String
    let due: Date?
    let url: String
}

@MainActor
final class ClickUpStore: ObservableObject {
    static let shared = ClickUpStore()
    @Published private(set) var tasks: [CUTask] = []
    @Published private(set) var openCount = 0
    @Published private(set) var error: String? = nil
    @Published private(set) var loaded = false
    private var timer: Timer?
    private init() {}

    var hasToken: Bool { KeychainStore.shared.get("clickup-token")?.isEmpty == false }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            Task { @MainActor in ClickUpStore.shared.refresh() }
        }
    }

    func refresh() {
        guard let token = KeychainStore.shared.get("clickup-token"), !token.isEmpty else { return }
        Task {
            do {
                let user = try await get("https://api.clickup.com/api/v2/user", token)
                let uid = ((user["user"] as? [String: Any])?["id"] as? NSNumber)?.stringValue ?? ""
                let teams = (try await get("https://api.clickup.com/api/v2/team", token))["teams"] as? [[String: Any]] ?? []
                var all: [CUTask] = []
                for t in teams {
                    guard let tid = t["id"] as? String else { continue }
                    let url = "https://api.clickup.com/api/v2/team/\(tid)/task?assignees[]=\(uid)&include_closed=false&subtasks=true&order_by=due_date&reverse=true"
                    let tasks = (try await get(url, token))["tasks"] as? [[String: Any]] ?? []
                    all += tasks.map { x in
                        let st = x["status"] as? [String: Any] ?? [:]
                        let due = (x["due_date"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                        return CUTask(id: x["id"] as? String ?? UUID().uuidString, name: x["name"] as? String ?? "",
                                      status: (st["status"] as? String ?? "").uppercased(),
                                      statusColor: st["color"] as? String ?? "#7B68EE",
                                      due: due, url: x["url"] as? String ?? "")
                    }
                }
                // Due soonest first; tasks without a due date last.
                all.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                openCount = all.count
                tasks = Array(all.prefix(12))
                error = nil
                loaded = true
            } catch {
                self.error = "ClickUp didn't answer. Check the token in Settings."
            }
        }
    }

    private func get(_ s: String, _ token: String) async throws -> [String: Any] {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

struct ClickUpCardView: View {
    @ObservedObject private var store = ClickUpStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#7B68EE")).frame(width: 7, height: 7)
                Text("ClickUp").font(.qimah(size: 12, weight: .semibold)).foregroundColor(Q.text)
                Text(subtitle).font(.qimah(size: 11)).foregroundColor(Q.muted).lineLimit(1)
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            if !store.hasToken {
                Text("Add your ClickUp token in Settings › Integrations to see your tasks here.")
                    .font(.qimah(size: 10.5)).foregroundColor(Q.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).padding(.leading, 108).padding(.trailing, 14)
            } else if let e = store.error {
                Text(e).font(.qimah(size: 10.5)).foregroundColor(Q.del)
                    .padding(.top, 8).padding(.leading, 108).padding(.trailing, 14)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.tasks) { t in
                            Button(action: { if let u = URL(string: t.url) { NSWorkspace.shared.open(u) } }) {
                                HStack(spacing: 6) {
                                    Text(t.status)
                                        .font(.qimah(size: 8, weight: .bold))
                                        .foregroundColor(Color(hex: t.statusColor).lighter(by: 0.35))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color(hex: t.statusColor).opacity(0.2))
                                        .clipShape(Capsule())
                                        .lineLimit(1)
                                        .fixedSize()
                                    Text(t.name).font(.qimah(size: 10.5)).foregroundColor(Q.soft).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(dueLabel(t.due)).font(.qimah(size: 9.5)).foregroundColor(dueColor(t.due)).fixedSize()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 5).padding(.leading, 108).padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    private var subtitle: String {
        guard store.hasToken else { return "not connected" }
        guard store.loaded else { return "loading…" }
        let soon = store.tasks.filter { ($0.due ?? .distantFuture) < Date().addingTimeInterval(3 * 86400) }.count
        return "\(store.openCount) open · \(soon) due soon"
    }

    private func dueLabel(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if d < Date(), !cal.isDateInToday(d) {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
            return "\(max(days, 1))d late"
        }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE d"
        return f.string(from: d)
    }

    private func dueColor(_ d: Date?) -> Color {
        guard let d else { return Q.dim }
        if d < Date(), !Calendar.current.isDateInToday(d) { return Q.del }
        if Calendar.current.isDateInToday(d) { return Color(hex: "#F5A524") }
        return Q.muted
    }
}
