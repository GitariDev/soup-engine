import DarkroomCore
import SwiftUI

/// A film can, drawn as `canSVG` in doc/menu-sample/index.html draws it for the
/// camera, on the same 120x190 grid.
struct CanView: View {
    let film: Film
    var width: CGFloat = 54
    var selected = false

    private static let aspect: CGFloat = 190.0 / 120.0

    /// How each label is laid out. The .fs format has no such field.
    private enum Style { case solid, band, split }
    private static let styles: [String: Style] = [
        "PORTRA": .band, "REALA ACE": .band, "PROVIA": .band,
        "NOSTALGIC NEG": .split, "ASTIA": .split, "CLASSIC CHROME": .split, "BLEACH BYPASS": .split,
    ]

    private static let metal = Gradient(stops: [
        .init(color: Color(hex: "#4c4e5a"), location: 0), .init(color: Color(hex: "#b9bbc6"), location: 0.16),
        .init(color: .white, location: 0.3), .init(color: Color(hex: "#b6b8c4"), location: 0.46),
        .init(color: Color(hex: "#70727f"), location: 0.8), .init(color: Color(hex: "#3c3d48"), location: 1),
    ])
    private static let shade = Gradient(stops: [
        .init(color: .black.opacity(0.62), location: 0), .init(color: .black.opacity(0.2), location: 0.1),
        .init(color: .white.opacity(0.42), location: 0.24), .init(color: .white.opacity(0.06), location: 0.34),
        .init(color: .black.opacity(0.04), location: 0.62), .init(color: .black.opacity(0.34), location: 0.86),
        .init(color: .black.opacity(0.68), location: 1),
    ])
    private static let leader = Gradient(colors: [Color(hex: "#3e2c30"), Color(hex: "#7c5c55"), Color(hex: "#5d4644")])

    var body: some View {
        Canvas(opaque: false) { ctx, size in
            ctx.scaleBy(x: size.width / 158, y: size.width / 158)
            ctx.drawLayer { shadowed in
                shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 7, x: 0, y: 6))
                drawCan(&shadowed)
            }
        }
        .frame(width: width * 158 / 120, height: width * Self.aspect)
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .center) {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(EdgeInsets(top: -7, leading: -7, bottom: -7, trailing: -7))
            }
        }
    }

    private func across(_ gradient: Gradient, _ x: CGFloat, _ w: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(gradient, startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + w, y: 0))
    }

    private func drawCan(_ ctx: inout GraphicsContext) {
        let can = film.can
        let body = Color(hex: can.c1), band = Color(hex: can.c2), ink = Color(hex: can.c3)
        let style = Self.styles[Film.key(film.name)] ?? .solid

        var lead = Path()
        lead.addLines([CGPoint(x: 100, y: 58), CGPoint(x: 136, y: 58), CGPoint(x: 146, y: 66), CGPoint(x: 158, y: 66),
                       CGPoint(x: 158, y: 126), CGPoint(x: 100, y: 126)])
        lead.closeSubpath()
        ctx.fill(lead, with: across(Self.leader, 100, 58))
        for i in 0..<5 {
            let x = 112 + CGFloat(i) * 9
            ctx.fill(Path(CGRect(x: x, y: 62, width: 5, height: 6)), with: .color(Color(hex: "#17151d")))
            ctx.fill(Path(CGRect(x: x, y: 117, width: 5, height: 6)), with: .color(Color(hex: "#17151d")))
        }

        ctx.fill(Path(roundedRect: CGRect(x: 47, y: 0, width: 26, height: 15), cornerRadius: 2),
                 with: .color(Color(hex: "#1b1c22")))
        ctx.fill(Path(ellipseIn: CGRect(x: 47, y: 0, width: 26, height: 5)), with: .color(Color(hex: "#44464f")))
        ctx.fill(Path(CGRect(x: 9, y: 14, width: 102, height: 12)), with: across(Self.metal, 9, 102))
        ctx.fill(Path(ellipseIn: CGRect(x: 9, y: 6.5, width: 102, height: 15)), with: across(Self.metal, 9, 102))
        ctx.fill(Path(ellipseIn: CGRect(x: 20, y: 9.2, width: 80, height: 9.6)),
                 with: .color(Color(hex: "#2a2b33").opacity(0.55)))
        ctx.fill(Path(CGRect(x: 7, y: 162, width: 106, height: 15)), with: across(Self.metal, 7, 106))
        ctx.fill(Path(ellipseIn: CGRect(x: 7, y: 168, width: 106, height: 18)), with: across(Self.metal, 7, 106))

        var clip = Path()
        clip.move(to: CGPoint(x: 10, y: 24))
        clip.addQuadCurve(to: CGPoint(x: 110, y: 24), control: CGPoint(x: 60, y: 38))
        clip.addLine(to: CGPoint(x: 110, y: 166))
        clip.addQuadCurve(to: CGPoint(x: 10, y: 166), control: CGPoint(x: 60, y: 180))
        clip.closeSubpath()

        var label = ctx
        label.clip(to: clip)
        drawLabel(&label, style: style, body: body, band: band, ink: ink, can: can)
        label.fill(Path(CGRect(x: 0, y: 16, width: 120, height: 166)), with: across(Self.shade, 0, 120))
    }

    private func curve(_ a: CGFloat, _ ac: CGFloat, _ b: CGFloat, _ bc: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -30, y: a))
        p.addQuadCurve(to: CGPoint(x: 150, y: a), control: CGPoint(x: 60, y: ac))
        p.addLine(to: CGPoint(x: 150, y: b))
        p.addQuadCurve(to: CGPoint(x: -30, y: b), control: CGPoint(x: 60, y: bc))
        p.closeSubpath()
        return p
    }

    private func drawLabel(_ ctx: inout GraphicsContext, style: Style, body: Color, band: Color, ink: Color,
                           can: FilmCan) {
        switch style {
        case .band:
            ctx.fill(Path(CGRect(x: -30, y: 20, width: 180, height: 154)), with: .color(body))
            ctx.fill(curve(26, 50, 58, 64), with: .color(band))
            ctx.fill(curve(141, 147, 176, 176), with: .color(band))
            ctx.fill(curve(58, 64, 60, 66), with: .color(ink.opacity(0.55)))
        case .split:
            ctx.fill(Path(CGRect(x: -30, y: 20, width: 180, height: 82)), with: .color(body))
            ctx.fill(Path(CGRect(x: -30, y: 100, width: 180, height: 76)), with: .color(band))
        case .solid:
            ctx.fill(Path(CGRect(x: -30, y: 20, width: 180, height: 154)), with: .color(body))
            ctx.fill(curve(30, 52, 41, 62), with: .color(band))
            ctx.fill(curve(148, 156, 160, 170), with: .color(band))
        }

        let words = film.name.uppercased().split(separator: " ").map(String.init)
        let two = words.count > 1
        let longest = max(words.map(\.count).max() ?? 1, 1)
        let nameSize = min(19, 92 / CGFloat(longest) / 0.62)
        let nameY: CGFloat = two ? 74 : 80
        let small = style == .band ? Color(hex: "#3b2a12") : ink

        func put(_ s: String, _ y: CGFloat, _ size: CGFloat, _ color: Color) {
            let text = Text(s).font(Theme.font(size, .bold)).foregroundColor(color)
            ctx.draw(text, at: CGPoint(x: 60, y: y), anchor: UnitPoint(x: 0.5, y: 0.8))
        }
        put("\(can.brand) FILM", style == .band ? 47 : 48, 7, small.opacity(0.9))
        put(words.first ?? "", nameY, nameSize, ink)
        if two { put(words.dropFirst().joined(separator: " "), nameY + nameSize + 0.5, nameSize, ink) }
        put(can.iso, two ? 130 : 129, two ? 35 : 41, ink)
        put("135-36", style == .band ? 157 : 143, 7.5, small.opacity(0.9))
    }
}
