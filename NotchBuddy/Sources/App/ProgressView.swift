import SwiftUI

// MARK: - Progress tab
// The update-and-status chart in the notch: overall bar, a row per sub-task,
// then Done / Now / Next / Blocked.

struct ProgressTabView: View {
    @ObservedObject private var store = ProgressStore.shared

    var body: some View {
        CardBackground(wash: nil) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if store.isEmpty {
                    Spacer(minLength: 0)
                    Text("No progress yet. It fills in when Claude posts a status update, keeps a to-do list, or opens a PR.")
                        .font(.qimah(size: 12))
                        .foregroundColor(Q.dim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                } else {
                    if let overall = store.overall { OverallBar(pct: overall) }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(store.rows) { RowView(row: $0) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    StatusCells(done: store.done, now: store.now, next: store.next, blocked: store.blocked)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.qimah(size: 13, weight: .semibold))
                        .foregroundColor(Q.text)
                        .lineLimit(1)
                    if let pr = store.pr {
                        Text("#\(pr.number)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Q.gradient)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.qimah(size: 11))
                    .foregroundColor(Q.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.pr != nil {
                Button(action: { store.pollPR(); store.openPR() }) {
                    Text("Open PR")
                        .font(.qimah(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Q.gradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 58)       // Mochi sits to the left
        .frame(minHeight: 40)
    }

    private var title: String {
        if let t = store.pr?.title, !t.isEmpty { return t }
        if !store.headline.isEmpty { return store.headline }
        return "Progress"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let pr = store.pr { parts.append(pr.repo) }
        if let t = store.updatedAt {
            let s = Int(Date().timeIntervalSince(t))
            parts.append(s < 60 ? "updated just now" : "updated \(s / 60)m ago")
        }
        if store.pr?.title.isEmpty == false, !store.headline.isEmpty { parts.append(store.headline) }
        return parts.joined(separator: " · ")
    }
}

private struct OverallBar: View {
    let pct: Int

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Q.deep)
                    Capsule().fill(Q.gradient).frame(width: g.size.width * CGFloat(pct) / 100)
                }
            }
            .frame(height: 8)
            Text("\(pct)%")
                .font(.qimah(size: 18, weight: .bold))
                .foregroundColor(Q.text)
                .frame(width: 52, alignment: .trailing)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: pct)
    }
}

private struct RowView: View {
    let row: ProgressRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StateIcon(state: row.state)
                Text(row.name)
                    .font(.qimah(size: 11.5, weight: row.state == .now ? .semibold : .regular))
                    .foregroundColor(row.state == .now ? Q.text : Q.soft)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Q.deep)
                        Capsule()
                            .fill(row.state == .blocked ? AnyShapeStyle(Q.del.opacity(0.8)) : AnyShapeStyle(Q.gradient))
                            .frame(width: g.size.width * CGFloat(row.pct ?? 0) / 100)
                    }
                }
                .frame(height: 5)
                Text(row.pct.map { "\($0)%" } ?? "n/a")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Q.muted)
                    .frame(width: 38, alignment: .trailing)
            }
            if !row.note.isEmpty {
                Text(row.note)
                    .font(.qimah(size: 10.5))
                    .foregroundColor(row.state == .blocked ? Q.del : Q.dim)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct StateIcon: View {
    let state: ProgressRow.State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Q.add)
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundColor(Q.deep)
            case .now:
                TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                    Circle().stroke(Q.mint, lineWidth: 2)
                        .opacity(0.45 + 0.55 * abs(sin(tl.date.timeIntervalSinceReferenceDate * 2.5)))
                }
            case .todo:
                Circle().stroke(Q.dim, lineWidth: 1.5)
            case .blocked:
                Circle().fill(Q.del)
                Image(systemName: "exclamationmark").font(.system(size: 7, weight: .heavy)).foregroundColor(.white)
            }
        }
        .frame(width: 13, height: 13)
    }
}

private struct StatusCells: View {
    let done: [String], now: [String], next: [String], blocked: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            cell("DONE", done, Q.add)
            cell("NOW", now, Q.mint)
            cell("NEXT", next, Q.muted)
            let none = blocked.allSatisfy { ["nothing", "none", "no", "-"].contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            cell("BLOCKED", none ? ["nothing"] : blocked, none ? Q.dim : Q.del)
        }
        .frame(height: 62)
    }

    private func cell(_ label: String, _ items: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.qimah(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundColor(color)
            Text(items.isEmpty ? "none" : items.joined(separator: "\n"))
                .font(.qimah(size: 10))
                .foregroundColor(Q.soft)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Q.deep)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
