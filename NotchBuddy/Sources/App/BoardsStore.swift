import Foundation
import AppKit

// MARK: - Qimah boards
// Reads the public status feed behind boards.qimah.net (the same file the page
// polls) every 2 minutes. Drives the Qimah pill/card on Home, the owed count on
// the notch, "pop on news", and the "where you are" bar in the Live tab.

struct BoardCard: Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let shipped: Bool
    let wave: Int
    let taskId: String?
}

struct BoardProgram: Identifiable, Equatable, Sendable {
    var id: String { slug }
    let name: String
    let slug: String
    let url: String          // full board URL
    let shipped: Int
    let total: Int
    let next: String?
    let cards: [BoardCard]

    var fraction: Double { total > 0 ? Double(shipped) / Double(total) : 0 }
}

struct BoardOwed: Identifiable, Equatable, Sendable {
    let id: String           // feed key
    let title: String
    let severity: String
}

/// The card the current work belongs to, found from branch / PR / command text.
struct BoardFocus: Equatable, Sendable {
    let program: BoardProgram
    let card: BoardCard
    let index: Int           // position of the card in the program's card order
}

@MainActor
final class BoardsStore: ObservableObject {
    static let shared = BoardsStore()

    static let base = "https://boards.qimah.net/"
    private static let feed = URL(string: base + "status/index.json")!

    @Published private(set) var programs: [BoardProgram] = []
    @Published private(set) var owed: [BoardOwed] = []
    @Published private(set) var syncedAt: Date? = nil
    @Published private(set) var loaded = false
    @Published private(set) var error: String? = nil
    @Published private(set) var focus: BoardFocus? = nil
    @Published private(set) var resyncing = false

    /// Latest news worth popping the notch for (title shown on the card).
    @Published private(set) var news: String? = nil

    private var timer: Timer?
    private var knownOwed: Set<String>? = nil
    private var knownShipped: Set<String>? = nil
    private var focusId: String? = nil

    private init() {}

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await BoardsStore.shared.refresh() }
        }
    }

    // MARK: - Fetch

    func refresh() async {
        var req = URLRequest(url: Self.feed.appending(queryItems: [.init(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]))
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error = "Can't reach boards.qimah.net"
            return
        }
        error = nil
        apply(root)
    }

    private func apply(_ root: [String: Any]) {
        let iso = ISO8601DateFormatter()
        syncedAt = (root["synced_at"] as? String).flatMap { iso.date(from: $0) }

        let progs: [BoardProgram] = (root["programs"] as? [[String: Any]] ?? []).map { p in
            let cards = (p["cards"] as? [[String: Any]] ?? []).map { c in
                BoardCard(id: c["id"] as? String ?? "",
                          title: c["title"] as? String ?? "",
                          status: c["status"] as? String ?? "",
                          shipped: !(c["shippedAt"] is NSNull) && c["shippedAt"] != nil,
                          wave: c["wave"] as? Int ?? 0,
                          taskId: c["taskId"] as? String)
            }
            let rel = p["url"] as? String ?? ""
            return BoardProgram(name: p["name"] as? String ?? "?",
                                slug: p["slug"] as? String ?? "",
                                url: rel.hasPrefix("http") ? rel : Self.base + rel,
                                shipped: p["shipped"] as? Int ?? 0,
                                total: p["total"] as? Int ?? 0,
                                next: p["next"] as? String,
                                cards: cards)
        }
        let owedNow: [BoardOwed] = (root["owed"] as? [[String: Any]] ?? []).map {
            BoardOwed(id: $0["key"] as? String ?? UUID().uuidString,
                      title: $0["title"] as? String ?? "",
                      severity: $0["severity"] as? String ?? "info")
        }

        // News: anything new since the last poll (never on the first load).
        let owedKeys = Set(owedNow.map(\.id))
        let shippedKeys = Set(progs.flatMap { p in p.cards.filter(\.shipped).map { "\(p.slug)/\($0.id)" } })
        var headline: String? = nil
        if let known = knownShipped, let first = shippedKeys.subtracting(known).first {
            let parts = first.split(separator: "/")
            let prog = progs.first { $0.slug == parts.first.map(String.init) }
            headline = "\(parts.last ?? "") shipped in \(prog?.name ?? "a program")"
        } else if let known = knownOwed, let first = owedNow.first(where: { !known.contains($0.id) }) {
            headline = first.title
        }
        knownOwed = owedKeys
        knownShipped = shippedKeys

        programs = progs
        owed = owedNow
        loaded = true
        if let focusId { resolveFocus(focusId) }

        if let headline {
            news = headline
            NotificationCenter.default.post(name: .boardsNews, object: headline)
        }
    }

    // MARK: - Resync (same doorbell as the page's "Refresh now")

    func resync() {
        guard !resyncing else { return }
        resyncing = true
        var req = URLRequest(url: URL(string: Self.base + "resync")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 8
        Task {
            _ = try? await URLSession.shared.data(for: req)
            // The board rebuilds in about half a minute.
            try? await Task.sleep(for: .seconds(30))
            await refresh()
            try? await Task.sleep(for: .seconds(30))
            await refresh()
            resyncing = false
        }
    }

    // MARK: - Where you are

    /// Looks for a card id (e.g. "C-PR7c") in text Claude is working with:
    /// the git branch, PR titles, commit messages, commands, prompts.
    func noteContext(_ text: String) {
        guard loaded, !text.isEmpty else { return }
        let ids = Dictionary(programs.flatMap { $0.cards.map { ($0.id.lowercased(), $0.id) } },
                             uniquingKeysWith: { a, _ in a })
        // Tokens shaped like card ids: letters, dash, letters/digits.
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z]{1,3}-[A-Za-z]{0,3}[0-9]+[a-z]?")
        let ns = text as NSString
        var hit: String? = nil
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let id = ids[ns.substring(with: m.range).lowercased()] { hit = id }   // last one wins
        }
        guard let hit, hit != focusId else { return }
        focusId = hit
        resolveFocus(hit)
    }

    /// The branch of the project Claude is in, read straight from .git/HEAD.
    func noteBranch(cwd: String) {
        guard !cwd.isEmpty else { return }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<6 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                noteContext(s.replacingOccurrences(of: "ref: refs/heads/", with: ""))
                return
            }
            dir.deleteLastPathComponent()
        }
    }

    private func resolveFocus(_ id: String) {
        for p in programs {
            if let i = p.cards.firstIndex(where: { $0.id == id }) {
                let f = BoardFocus(program: p, card: p.cards[i], index: i)
                if f != focus { focus = f }
                return
            }
        }
    }

    // MARK: - Ordering for the card

    /// Current program first, then programs in motion by progress, then the rest.
    var orderedPrograms: [BoardProgram] {
        let current = focus?.program.slug
        return programs.sorted { a, b in
            if a.slug == current { return true }
            if b.slug == current { return false }
            let am = a.shipped > 0 && a.shipped < a.total, bm = b.shipped > 0 && b.shipped < b.total
            if am != bm { return am }
            return a.fraction > b.fraction
        }
    }

    func open(_ program: BoardProgram) {
        if let u = URL(string: program.url) { NSWorkspace.shared.open(u) }
    }

    func openBoards() {
        NSWorkspace.shared.open(URL(string: Self.base)!)
    }
}

extension Notification.Name {
    static let boardsNews = Notification.Name("coucou.boardsNews")
}
