import SwiftUI
import CoreText

// MARK: - Theme
// Every colour the island uses comes from here, so it can be changed live from
// Settings › Appearance. Default is Qimah "Forest": teal-green cards, the
// #1E6649 → #2A8A62 gradient for anything active, IBM Plex Sans Arabic.
// The island itself stays black so it keeps blending into the notch.

struct ThemeColors: Codable, Equatable, Sendable {
    var card: String
    var raised: String
    var deep: String
    var text: String
    var soft: String
    var muted: String
    var dim: String
    var accentA: String     // gradient start / primary
    var accentB: String     // gradient end
    var label: String       // small coloured labels ("WHAT CLAUDE IS DOING")
    var add: String
    var del: String
    var mochiTop: String
    var mochiBottom: String
    var useQimahFont: Bool = true
}

struct ThemePreset: Identifiable, Sendable {
    let id: String
    let name: String
    let colors: ThemeColors
}

enum ThemePresets {
    static let forest = ThemeColors(
        card: "#15352B", raised: "#1C4437", deep: "#0D2219",
        text: "#EAF3F0", soft: "#C3DAD3", muted: "#9CB6AF", dim: "#6F8B83",
        accentA: "#1E6649", accentB: "#2A8A62", label: "#7FD3AD",
        add: "#3FC08A", del: "#EF6B73",
        mochiTop: "#FBF8F2", mochiBottom: "#7FD3AD")

    static let night = ThemeColors(
        card: "#0E1714", raised: "#13261F", deep: "#070D0B",
        text: "#EAF3F0", soft: "#C3DAD3", muted: "#9CB6AF", dim: "#5F7A72",
        accentA: "#1E6649", accentB: "#3FC08A", label: "#3FC08A",
        add: "#3FC08A", del: "#EF6B73",
        mochiTop: "#F4F7F5", mochiBottom: "#3FC08A")

    static let gradient = ThemeColors(
        card: "#173A2E", raised: "#1E4A3B", deep: "#0B1E17",
        text: "#FFFFFF", soft: "#D6EEE4", muted: "#B5D6CA", dim: "#7FA396",
        accentA: "#1E6649", accentB: "#2A8A62", label: "#C3ECD8",
        add: "#3FC08A", del: "#EF6B73",
        mochiTop: "#FFFFFF", mochiBottom: "#2A8A62")

    static let original = ThemeColors(
        card: "#141518", raised: "#1D1F23", deep: "#0B0C0E",
        text: "#F5F6F8", soft: "#C5C8CD", muted: "#8E939C", dim: "#6B7079",
        accentA: "#2F6BFF", accentB: "#3B9EFF", label: "#8E939C",
        add: "#34D399", del: "#F4505E",
        mochiTop: "#EDEDEF", mochiBottom: "#C4C5CA", useQimahFont: false)

    static let all: [ThemePreset] = [
        .init(id: "forest",   name: "Forest",   colors: forest),
        .init(id: "night",    name: "Night",    colors: night),
        .init(id: "gradient", name: "Gradient", colors: gradient),
        .init(id: "original", name: "Original", colors: original),
    ]
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "themeColors"

    /// Read from any thread (Canvas/TimelineView drawing). Written only on main.
    nonisolated(unsafe) static var current: ThemeColors = ThemePresets.forest

    @Published var colors: ThemeColors {
        didSet {
            Self.current = colors
            version += 1
            if let d = try? JSONEncoder().encode(colors) { UserDefaults.standard.set(d, forKey: Self.key) }
        }
    }
    /// Bumped on every change; views use it as an id to redraw with the new colours.
    @Published private(set) var version = 0

    private init() {
        var c = ThemePresets.forest
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ThemeColors.self, from: d) { c = saved }
        colors = c
        Self.current = c
    }

    func apply(_ preset: ThemePreset) { colors = preset.colors }

    /// Two-way binding from a hex field to a ColorPicker.
    func binding(_ path: WritableKeyPath<ThemeColors, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: self.colors[keyPath: path]) },
            set: { self.colors[keyPath: path] = $0.hexString }
        )
    }
}

enum Q {
    private static var c: ThemeColors { ThemeStore.current }
    static var card:    Color { Color(hex: c.card) }
    static var raised:  Color { Color(hex: c.raised) }
    static var deep:    Color { Color(hex: c.deep) }
    static var text:    Color { Color(hex: c.text) }
    static var soft:    Color { Color(hex: c.soft) }
    static var muted:   Color { Color(hex: c.muted) }
    static var dim:     Color { Color(hex: c.dim) }
    static var primary: Color { Color(hex: c.accentA) }
    static var accent:  Color { Color(hex: c.accentB) }
    static var mint:    Color { Color(hex: c.label) }
    static var add:     Color { Color(hex: c.add) }
    static var del:     Color { Color(hex: c.del) }
    static let border = Color.white.opacity(0.08)

    static var gradient: LinearGradient {
        LinearGradient(colors: [primary, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var mochiTop: CGColor    { cg(c.mochiTop) }
    static var mochiBottom: CGColor { cg(c.mochiBottom) }

    /// Hex to CGColor without going through NSColor (safe off the main thread).
    static func cg(_ hex: String) -> CGColor {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Registers the bundled IBM Plex Sans Arabic files. Call once at launch.
    static func registerFonts() {
        for w in ["Regular", "Medium", "SemiBold", "Bold"] {
            guard let url = Bundle.main.url(forResource: "IBMPlexSansArabic-\(w)", withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// IBM Plex Sans Arabic at the closest bundled weight (system font when turned off).
    static func qimah(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard ThemeStore.current.useQimahFont else { return .system(size: size, weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "IBMPlexSansArabic-Bold"
        case .semibold:             name = "IBMPlexSansArabic-SemiBold"
        case .medium:               name = "IBMPlexSansArabic-Medium"
        default:                    name = "IBMPlexSansArabic-Regular"
        }
        return .custom(name, fixedSize: size)
    }
}

extension Color {
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
