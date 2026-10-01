import SwiftUI

// MARK: - Live tab
// Shows the edit Claude is making right now: file + line, removed lines struck
// out, new code typed in letter by letter, and what Claude said it's doing.

struct LiveView: View {
    @ObservedObject var feed = LiveFeed.shared
    @ObservedObject private var boards = BoardsStore.shared

    var body: some View {
        CardBackground(wash: nil) {
            VStack(alignment: .leading, spacing: 9) {
                // What Claude is doing (Mochi sits to the left, drawn by BotPlacement)
                VStack(alignment: .leading, spacing: 2) {
                    if let thought = feed.thought {
                        HStack(spacing: 6) {
                            Text("THINKING")
                                .font(.qimah(size: 9.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundColor(Q.mint)
                            ThinkingDots()
                        }
                        Text(thought.isEmpty ? "Working out the next step…" : String(thought.prefix(feed.thoughtTyped)))
                            .font(.qimah(size: 12.5))
                            .italic()
                            .foregroundColor(thought.isEmpty ? Q.dim : Q.soft)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("WHAT CLAUDE IS DOING")
                            .font(.qimah(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(Q.mint)
                        Text(feed.why.isEmpty ? "Waiting for Claude to do something…" : feed.why)
                            .font(.qimah(size: 12.5))
                            .foregroundColor(feed.why.isEmpty ? Q.dim : Q.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(.easeInOut(duration: 0.2), value: feed.why)
                    }
                }
                .frame(minHeight: 40, alignment: .leading)
                .padding(.leading, 58)

                // Where this work sits on boards.qimah.net
                if let focus = boards.focus {
                    BoardWhereStrip(focus: focus)
                }

                if let item = feed.current {
                    LiveHeader(item: item)
                    LiveCode(item: item, phase: feed.phase, typed: feed.typed)
                } else {
                    Spacer(minLength: 0)
                }

                LiveChips(chips: feed.chips)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct LiveHeader: View {
    let item: LiveItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.qimah(size: 11))
                .foregroundColor(item.kind == .command ? Q.mint : Q.add)
            if item.kind == .command {
                Text("Running a command")
                    .font(.qimah(size: 11.5, weight: .medium))
                    .foregroundColor(Q.text)
            } else {
                Text(item.title)
                    .font(.qimah(size: 11.5, weight: .semibold))
                    .foregroundColor(Q.text)
                    .lineLimit(1)
                    .help(item.path)
                if let line = item.line {
                    Text("line \(line)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Q.text)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Q.accent.opacity(0.28))
                        .clipShape(Capsule())
                }
                if item.added + item.removed > 0 {
                    Text("+\(item.added)").foregroundColor(Q.add)
                        .font(.system(size: 10, design: .monospaced))
                    + Text(" -\(item.removed)").foregroundColor(Q.del)
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            Spacer(minLength: 4)
            if !item.path.isEmpty {
                Button(action: { openInEditor(item.path, line: item.line) }) {
                    Text("Open")
                        .font(.qimah(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Q.gradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .command: return "terminal"
        }
    }
}

private struct LiveCode: View {
    let item: LiveItem
    let phase: LiveFeed.Phase
    let typed: Int

    var body: some View {
        let rows = visibleRows
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.line.id) { row in
                        LiveRow(row: row).id(row.line.id)
                    }
                    if item.extraLines > 0 && phase == .hold {
                        Text("  … \(item.extraLines) more lines")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Q.dim)
                            .padding(.leading, 34)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: rows.last?.line.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Q.deep)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Q.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    struct Row {
        let line: LiveLine
        let shown: String
        let struck: Bool
        let caret: Bool
    }

    /// Lines to draw right now, given how far the typewriter has got.
    private var visibleRows: [Row] {
        var out: [Row] = []
        var budget = typed
        var caretPlaced = false
        let typing = phase == .typing || phase == .hold
        for l in item.lines {
            switch l.kind {
            case .context:
                // Context after the edit appears once typing is done.
                if l.id > (item.lines.last(where: { $0.kind == .added })?.id ?? -1), phase != .hold { continue }
                out.append(Row(line: l, shown: l.text, struck: false, caret: false))
            case .removed:
                out.append(Row(line: l, shown: l.text, struck: phase != .show, caret: false))
            case .added:
                guard typing else { continue }
                if budget <= 0 && caretPlaced { continue }
                let n = min(l.text.count, budget)
                budget -= n
                let done = n == l.text.count
                let caret = !caretPlaced && (!done || budget == 0) && phase == .typing
                if caret { caretPlaced = true }
                out.append(Row(line: l, shown: String(l.text.prefix(n)), struck: false, caret: caret))
                if !done { caretPlaced = true }
            case .output:
                if phase == .hold { out.append(Row(line: l, shown: l.text, struck: false, caret: false)) }
            }
        }
        return out
    }
}

private struct LiveRow: View {
    let row: LiveCode.Row

    var body: some View {
        HStack(spacing: 0) {
            Text(row.line.number.map(String.init) ?? "")
                .foregroundColor(Q.dim.opacity(0.8))
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 10)
            HStack(spacing: 0) {
                Text(row.shown.isEmpty ? " " : row.shown)
                    .strikethrough(row.struck, color: Q.del.opacity(0.7))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.caret { Caret() }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private var textColor: Color {
        switch row.line.kind {
        case .context: return Q.muted.opacity(0.85)
        case .removed: return row.struck ? Q.del.opacity(0.9) : Q.muted.opacity(0.85)
        case .added:   return Q.text
        case .output:  return Q.soft.opacity(0.8)
        }
    }

    private var background: Color {
        switch row.line.kind {
        case .removed where row.struck: return Q.del.opacity(0.13)
        case .added: return Q.add.opacity(0.14)
        default: return .clear
        }
    }
}

private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(Q.add)
                .frame(width: 6, height: 13)
                .opacity(on ? 1 : 0)
                .padding(.leading, 1)
        }
    }
}

private struct LiveChips: View {
    let chips: [LiveChip]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Button(action: { if chip.kind == .edit || chip.kind == .write { LiveFeed.shared.replay(chip) } }) {
                        HStack(spacing: 5) {
                            Image(systemName: icon(chip.kind)).font(.qimah(size: 9.5))
                            Text(chip.label).font(.qimah(size: 10.5)).lineLimit(1)
                            if chip.added + chip.removed > 0 {
                                Text("+\(chip.added)").foregroundColor(Q.add)
                                + Text(" -\(chip.removed)").foregroundColor(Q.del)
                            }
                        }
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(isEdit(chip) ? Q.text : Q.muted)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Q.raised)
                        .overlay(Capsule().stroke(isEdit(chip) ? Q.add.opacity(0.4) : Q.border, lineWidth: 1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 24)
    }

    private func isEdit(_ c: LiveChip) -> Bool { c.kind == .edit || c.kind == .write }

    private func icon(_ k: LiveChip.Kind) -> String {
        switch k {
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .command: return "terminal"
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .agent: return "person.2"
        case .fail: return "exclamationmark.triangle"
        }
    }
}

/// Opens a file at a line in VS Code, falling back to the default app.
@MainActor
func openInEditor(_ path: String, line: Int?) {
    let target = path + (line.map { ":\($0)" } ?? "")
    if let url = URL(string: "vscode://file" + (target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)),
       NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Three dots that pulse in turn while Claude is thinking.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Q.mint)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
    }
}
