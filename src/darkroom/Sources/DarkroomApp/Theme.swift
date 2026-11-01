import CoreText
import DarkroomCore
import SwiftUI

extension Color {
    /// `#rrggbb`. Anything else is the blank can's grey.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(digits, radix: 16) ?? 0x8d8ea0
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255)
    }
}

enum Theme {
    static let accent = Color(hex: "#f4b45c")
    static let text = Color(hex: "#f2f2f7")
    static let dim = Color(hex: "#9d9ec0")
    static let soft = Color(hex: "#c9cae0")
    static let green = Color(hex: "#7fd6a4")
    static let blue = Color(hex: "#8fb6ff")
    static let warn = Color(hex: "#ff9d85")
    static let ink = Color(hex: "#241a0a")
    static let quiet = Color(hex: "#2a2b4a")
    static let black = Color(hex: "#08080c")
    static let line = Color.white.opacity(0.14)
    static let faint = Color.white.opacity(0.067)

    static let background = EllipticalGradient(
        stops: [.init(color: Color(hex: "#2d2e5a"), location: 0),
                .init(color: Color(hex: "#1c1d3b"), location: 0.6),
                .init(color: Color(hex: "#121328"), location: 1)],
        center: UnitPoint(x: 0.5, y: 0.3), startRadiusFraction: 0, endRadiusFraction: 1.55)

    /// The default continuous capsule leaves a tick where its ends meet the sides.
    static let pill = Capsule(style: .circular)

    /// Set once Barlow is registered. All font lookups pass through here.
    private static var barlow = false

    /// By PostScript name: the subset has no Regular, and its family name
    /// resolves to Bold whatever weight is asked for.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        guard barlow else { return .system(size: size, weight: weight) }
        switch weight {
        case .bold, .heavy, .black: return .custom("Barlow-Bold", size: size)
        case .semibold: return .custom("Barlow-SemiBold", size: size)
        default: return .custom("Barlow-Medium", size: size)
        }
    }

    /// The camera's tracked capitals: chips, tabs and kickers.
    static func tight(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        guard barlow else { return .system(size: size, weight: weight) }
        return .custom(weight == .semibold ? "BarlowSemiCondensed-SemiBold" : "BarlowSemiCondensed-Bold", size: size)
    }

    /// The film's name in the tray and the empty bench's headline: the camera's `.name`.
    static func display(_ size: CGFloat) -> Font { tight(size, .bold) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .monospaced) }

    /// Silent when the fonts are not there: the system font stands in.
    static func registerFonts() {
        let env = ProcessInfo.processInfo.environment["SOUP_FONTS"].map { URL(fileURLWithPath: $0) }
        let folders = [env, Bundle.main.resourceURL?.appendingPathComponent("Fonts")].compactMap { $0 }
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let files = names.filter { $0.hasPrefix("Barlow") && ($0.hasSuffix(".ttf") || $0.hasSuffix(".otf")) }
            var any = false
            for name in files {
                let url = folder.appendingPathComponent(name) as CFURL
                if CTFontManagerRegisterFontsForURL(url, .process, nil) { any = true }
            }
            if any {
                barlow = true
                return
            }
        }
    }
}

/// The small tracked capitals over each part of the tray.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.tight(11, .bold)).tracking(2.2).foregroundColor(Theme.dim)
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.soft
    var dashed = false
    var backed = false

    var body: some View {
        Text(text)
            .font(Theme.tight(12, .semibold)).tracking(0.72)
            .lineLimit(1)
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(backed ? Theme.pill.fill(Color.black.opacity(0.67)) : nil)
            .overlay(Theme.pill.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(compact ? 12 : 13, .bold))
            .foregroundColor(enabled ? Theme.ink : Theme.text.opacity(0.45))
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.vertical, compact ? 5 : 10).padding(.horizontal, compact ? 12 : 16)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(enabled ? Theme.accent : Theme.quiet.opacity(0.6)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, .bold))
            .foregroundColor(Theme.text)
            .padding(.vertical, 10).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.quiet))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The boxed field in the tray.
struct Boxed: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.faint))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.13)))
    }
}

extension Frame {
    /// The word on the strip.
    var stateWord: String {
        if !isReadable { return "UNREADABLE" }
        switch state {
        case .shotOn: return otherwiseFilm == nil ? "NO CAN" : "SHOT ON"
        case .yourChoice: return "YOUR CHOICE"
        case .printed: return "PRINTED"
        case .noRecord: return "NO RECORD"
        }
    }

    var stateColor: Color {
        if !isReadable { return Theme.warn }
        switch state {
        case .shotOn: return otherwiseFilm == nil ? Theme.dim : Theme.accent
        case .yourChoice: return Theme.blue
        case .printed: return Theme.green
        case .noRecord: return Theme.dim
        }
    }
}

extension Filter {
    var title: String {
        switch self {
        case .all: return "ALL"
        case .shotOn: return "SHOT ON"
        case .printed: return "PRINTED"
        case .yourChoice: return "YOUR CHOICE"
        case .noRecord: return "NO RECORD"
        case .notDeveloped: return "NOT DEVELOPED"
        }
    }

    var color: Color {
        switch self {
        case .all, .notDeveloped: return Theme.text
        case .shotOn: return Theme.accent
        case .printed: return Theme.green
        case .yourChoice: return Theme.blue
        case .noRecord: return Theme.dim
        }
    }

    /// What the strip says when this tab is empty.
    var emptyLine: String {
        switch self {
        case .all: return "No frames here."
        case .shotOn: return "No frame is waiting on the film it was shot on."
        case .printed: return "Nothing printed yet."
        case .yourChoice: return "No choice is waiting. Pick a can for any frame."
        case .noRecord: return "No frame waits for a film."
        case .notDeveloped: return "Every frame here is developed."
        }
    }
}
