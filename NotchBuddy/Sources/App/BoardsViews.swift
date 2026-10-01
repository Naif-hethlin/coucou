import SwiftUI

// MARK: - Qimah boards card (Home, when the Qimah pill is focused)

struct QimahBoardsCardView: View {
    @ObservedObject private var boards = BoardsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                QimahMark().frame(width: 12, height: 12)
                Text("Qimah boards")
                    .font(.qimah(size: 12, weight: .semibold))
                    .foregroundColor(Q.text)
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitle)
                    .font(.qimah(size: 11))
                    .foregroundColor(Q.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: { boards.resync() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(boards.resyncing ? Q.mint : Q.dim)
                        .rotationEffect(.degrees(boards.resyncing ? 360 : 0))
                        .animation(boards.resyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: boards.resyncing)
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Resync the boards now")
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 32)

            if let news = boards.news {
                Text(news)
                    .font(.qimah(size: 10.5, weight: .medium))
                    .foregroundColor(Q.mint)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .padding(.leading, 108)
                    .padding(.trailing, 12)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(boards.orderedPrograms) { p in
                        Button(action: { boards.open(p) }) {
                            ProgramRow(program: p, current: boards.focus?.program.slug == p.slug)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, 3)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    private var subtitle: String {
        if let e = boards.error, !boards.loaded { return e }
        if !boards.loaded { return "loading…" }
        return "\(boards.owed.count) owed"
    }
}

private struct ProgramRow: View {
    let program: BoardProgram
    let current: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(program.name)
                .font(.qimah(size: 10, weight: current ? .semibold : .regular))
                .foregroundColor(current ? Q.text : Q.soft)
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Q.deep)
                    Capsule().fill(Q.gradient)
                        .frame(width: max(program.shipped > 0 ? 5 : 0, g.size.width * program.fraction))
                }
            }
            .frame(height: 5)
            Text("\(program.shipped)/\(program.total)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(Q.muted)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, current ? 5 : 0)
        .padding(.vertical, current ? 2 : 0)
        .background(current ? Q.raised : Color.clear)
        .clipShape(Capsule())
        .contentShape(Rectangle())
    }
}

// MARK: - "Where you are" (Live tab)
// One segment per card in the program: shipped = gradient, the card being
// worked on now = pulsing mint, the rest = empty. Tap to open the board.

struct BoardWhereStrip: View {
    let focus: BoardFocus

    var body: some View {
        let p = focus.program
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                QimahMark().frame(width: 11, height: 11)
                Text(p.name)
                    .font(.qimah(size: 11, weight: .semibold))
                    .foregroundColor(Q.text)
                    .lineLimit(1)
                Text(focus.card.id)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Q.gradient)
                    .clipShape(Capsule())
                Text(focus.card.title)
                    .font(.qimah(size: 11))
                    .foregroundColor(Q.soft)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(caption)
                    .font(.qimah(size: 10))
                    .foregroundColor(Q.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            SegmentBar(cards: p.cards, currentIndex: focus.index)
                .frame(height: 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Q.raised.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Q.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { BoardsStore.shared.open(p) }
        .help("Open the \(p.name) board")
    }

    private var caption: String {
        let p = focus.program
        var s = "\(p.shipped)/\(p.total) shipped"
        if let next = p.next, next != focus.card.id { s += " · next \(next)" }
        return s
    }
}

private struct SegmentBar: View {
    let cards: [BoardCard]
    let currentIndex: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let pulse = 0.55 + 0.45 * sin(tl.date.timeIntervalSinceReferenceDate * 4)
            GeometryReader { g in
                let n = max(cards.count, 1)
                let gap: CGFloat = n > 30 ? 1 : 2
                let w = (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                HStack(spacing: gap) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { i, c in
                        Group {
                            if i == currentIndex {
                                Capsule().fill(Q.mint).opacity(pulse)
                            } else if c.shipped {
                                Capsule().fill(Q.gradient)
                            } else {
                                Capsule().fill(Q.deep)
                            }
                        }
                        .frame(width: max(1, w))
                    }
                }
            }
        }
    }
}

/// Qimah's mark: white peak on a green rounded square (as on boards.qimah.net).
struct QimahMark: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22).fill(Color(hex: "#1E6649"))
                Path { p in
                    p.move(to: CGPoint(x: s * 0.16, y: s * 0.75))
                    p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.22))
                    p.addLine(to: CGPoint(x: s * 0.84, y: s * 0.75))
                    p.closeSubpath()
                }
                .fill(Color.white)
            }
        }
    }
}

/// Small amber count of things owed on the boards.
struct OwedBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundColor(Color(hex: "#1A1205"))
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 13)
            .background(Color(hex: "#F5A524"))
            .clipShape(Capsule())
            .help("\(count) owed on boards.qimah.net")
    }
}
