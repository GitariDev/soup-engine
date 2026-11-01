import DarkroomCore
import SwiftUI

struct EnlargerView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        VStack(spacing: 8) {
            if bench.current == nil {
                emptyBench
            } else if let picture = bench.main {
                PictureStage(bench: bench, picture: picture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                problem(bench.pictureProblem ?? "Developing")
            }
            // Two lines' height, so nothing said here can move the picture.
            HStack(spacing: 14) {
                if !bench.stack.isEmpty { StackBar(bench: bench) }
                ZStack { caption }.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func problem(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(14)).foregroundColor(Theme.dim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBench: some View {
        VStack(spacing: 10) {
            Text(bench.emptyTitle).font(Theme.display(26)).foregroundColor(Theme.text)
                .multilineTextAlignment(.center)
            if let sub = bench.emptySubtitle {
                Text(sub).font(Theme.font(13)).foregroundColor(Theme.dim)
            }
            Button("Open another folder...") {
                if let url = Panels.pickFolderOrFile() { bench.open(url) }
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 540, maxHeight: 360)
        .background(RadialGradient(colors: [Color.white.opacity(0.13), .clear], center: .center,
                                   startRadius: 0, endRadius: 270))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var caption: some View {
        if let notice = bench.notice ?? bench.cardNote {
            Text(notice).font(Theme.font(11)).foregroundColor(Theme.warn).lineLimit(2)
                .multilineTextAlignment(.center)
        } else if bench.shownPrint != nil, bench.comparison?.wipes == true {
            (keys + Text(" Hold ") + Text("Space").bold() + Text(" for the original. Drag across the print to wipe."))
                .font(Theme.font(11)).foregroundColor(Theme.dim).lineLimit(2)
                .multilineTextAlignment(.center)
        } else if bench.current != nil, bench.comparison?.wipes == true {
            let side = bench.comparison?.film == nil ? "the straight raw" : "the film it was shot on"
            (Text("Hold ") + Text("Space").bold() + Text(" to see \(side). Drag the line to wipe between them."))
                .font(Theme.font(11)).foregroundColor(Theme.dim).lineLimit(bench.stack.isEmpty ? 1 : 2)
                .multilineTextAlignment(.center)
        } else if !bench.stack.isEmpty {
            keys.font(Theme.font(11)).foregroundColor(Theme.dim).lineLimit(1)
        }
    }

    private var keys: Text { Text("[").bold() + Text(" and ") + Text("]").bold() + Text(" go through the stack.") }
}

/// The original, the pile with its count, and a film in hand not printed yet.
/// `[` and `]` walk it left to right, and round again.
private struct StackBar: View {
    @ObservedObject var bench: Bench

    var body: some View {
        HStack(spacing: 8) {
            stop("ORIGINAL", on: bench.onOriginal, color: Theme.accent, anchor: "original") { bench.go(to: .original) }
            HStack(spacing: 2) {
                arrow("‹", by: -1, anchor: "back")
                Pile(count: bench.stack.count, lit: bench.shownPrint != nil)
                Text(bench.stackLabel)
                    .font(Theme.tight(12, .semibold)).tracking(0.72).monospacedDigit()
                    .foregroundColor(bench.shownPrint != nil ? Theme.green : Theme.soft)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 5)
                arrow("›", by: 1, anchor: "next")
            }
            if let film = bench.pendingFilm {
                stop(Film.key(film.name), on: bench.place == .film, color: Theme.blue, anchor: "film") { bench.go(to: .film) }
            }
        }
        .fixedSize()
    }

    private func stop(_ title: String, on: Bool, color: Color, anchor: String, go: @escaping () -> Void) -> some View {
        Button {
            Panels.dropFocus()
            go()
        } label: {
            Chip(text: title, color: on ? color : Theme.dim).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DriverAnchors.Mark(name: anchor))
    }

    private func arrow(_ glyph: String, by delta: Int, anchor: String) -> some View {
        Button {
            Panels.dropFocus()
            bench.stepStack(by: delta)
        } label: {
            Text(glyph).font(Theme.font(16, .bold)).foregroundColor(Theme.text)
                .frame(width: 20, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("[ and ] do the same")
        .background(DriverAnchors.Mark(name: anchor))
    }
}

/// Prints lying one on another, as many as can be told apart.
private struct Pile: View {
    let count: Int
    let lit: Bool

    var body: some View {
        ZStack {
            ForEach(0..<min(count, 3), id: \.self) { layer in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.black)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(lit ? Theme.green : Theme.soft, lineWidth: 1))
                    .frame(width: 17, height: 12)
                    .offset(x: CGFloat(layer) * 2.5 - 2.5, y: CGFloat(layer) * -2.5 + 2.5)
            }
        }
        .frame(width: 24, height: 20)
    }
}

/// The picture, fit to the space, never cropped.
private struct PictureStage: View {
    @ObservedObject var bench: Bench
    let picture: Picture

    private var aspect: CGFloat { CGFloat(picture.image.width) / CGFloat(max(picture.image.height, 1)) }

    private func image(_ picture: Picture) -> some View {
        Image(decorative: picture.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    /// The compare side when it is ready and it is a different picture.
    private var other: Picture? { bench.comparison?.wipes == true ? bench.compare : nil }

    private var wipeLine: Double { bench.shownPrint == nil ? bench.wipe : bench.printWipe }

    private var originalLabel: String {
        let label = bench.comparison?.label ?? "STRAIGHT RAW"
        // The bar says so too, and a portrait picture has no width to spare.
        return bench.stack.isEmpty || aspect < 1 ? label : "ORIGINAL · \(label)"
    }

    var body: some View {
        ZStack {
            Color.clear
            stage
                .overlay(alignment: .top) {
                    if bench.filmLate { Chip(text: "DEVELOPING", color: Theme.accent, backed: true).padding(8) }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { DriverAnchors.imageRect = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, rect in DriverAnchors.imageRect = rect }
                })
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black)
                    .shadow(color: Color.white.opacity(0.13), radius: 35))
        }
    }

    @ViewBuilder private var stage: some View {
        if bench.holdShotOn, let original = bench.spacePicture {
            marked(original)
                .overlay(alignment: .topLeading) {
                    Chip(text: originalLabel, color: Theme.accent, backed: true)
                        .padding(8)
                }
        } else if bench.holdShotOn, bench.comparison?.wipes == true {
            // The original is not here yet, and this picture is not it.
            marked(picture)
                .overlay(alignment: .top) { Chip(text: "DEVELOPING", color: Theme.accent, backed: true).padding(8) }
        } else if let other, picture.isDeveloped {
            wipe(other)
        } else {
            marked(picture)
                .overlay(alignment: .topLeading) {
                    if bench.onOriginal, !bench.showsOldFilm {
                        Chip(text: originalLabel, color: Theme.accent, backed: true).padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if bench.shownPrint != nil, !bench.showsOldFilm {
                        Chip(text: bench.comparison?.developingLabel ?? "", color: Theme.green, backed: true).padding(8)
                    }
                }
        }
    }

    /// G1: anything short of a render is drained and says so.
    @ViewBuilder private func marked(_ picture: Picture) -> some View {
        if picture.isDeveloped {
            image(picture)
        } else {
            image(picture)
                .saturation(0.3)
                .opacity(0.72)
                .overlay(alignment: .top) {
                    Chip(text: "DEVELOPING", color: Theme.accent, backed: true).padding(8)
                }
        }
    }

    private func wipe(_ other: Picture) -> some View {
        GeometryReader { geo in
            let x = geo.size.width * wipeLine
            // Two names side by side need more width than a portrait frame has.
            let drop: CGFloat = wipeLine > 0 && geo.size.width < 440 ? 30 : 0
            ZStack(alignment: .topLeading) {
                image(picture)
                image(other).mask(alignment: .leading) { Rectangle().frame(width: x) }
                // A print starts whole: no line yet, and nothing of the original to name.
                if wipeLine > 0 {
                    Rectangle().fill(Theme.accent).frame(width: 2).offset(x: x - 1)
                    Chip(text: bench.comparison?.label ?? "", color: Theme.accent, backed: true)
                        .padding(8)
                }
                if !bench.showsOldFilm {
                    Chip(text: bench.comparison?.developingLabel ?? "",
                         color: bench.shownPrint == nil ? Theme.blue : Theme.green, backed: true)
                        .padding(8)
                        .padding(.top, drop)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                Panels.dropFocus()
                let line = min(max(Double(value.location.x / max(geo.size.width, 1)), 0), 1)
                if bench.shownPrint == nil { bench.wipe = line } else { bench.printWipe = line }
            })
            .onHover { inside in
                (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
        }
    }
}
