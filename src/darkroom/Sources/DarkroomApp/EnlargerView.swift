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
            ZStack { caption }.frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
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
            Text(bench.emptyTitle).font(Theme.serif(22)).foregroundColor(Theme.text)
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
        } else if bench.current != nil, bench.comparison?.wipes == true {
            let side = bench.comparison?.film == nil ? "the straight raw" : "the film it was shot on"
            (Text("Hold ") + Text("Space").bold() + Text(" to see \(side). Drag the line to wipe between them."))
                .font(Theme.font(11)).foregroundColor(Theme.dim).lineLimit(1)
        }
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

    var body: some View {
        ZStack {
            Color.clear
            stage
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
        if bench.holdShotOn {
            marked(other ?? picture)
                .overlay(alignment: .topLeading) {
                    Chip(text: bench.comparison?.label ?? "STRAIGHT RAW", color: Theme.accent, backed: true)
                        .padding(8)
                }
        } else if let other, picture.isDeveloped {
            wipe(other)
        } else {
            marked(picture)
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
            let x = geo.size.width * bench.wipe
            ZStack(alignment: .topLeading) {
                image(picture)
                image(other).mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(Theme.accent).frame(width: 2).offset(x: x - 1)
                Chip(text: bench.comparison?.label ?? "", color: Theme.accent, backed: true)
                    .padding(8)
                Chip(text: bench.comparison?.developingLabel ?? "", color: Theme.blue, backed: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                Panels.dropFocus()
                bench.wipe = min(max(Double(value.location.x / max(geo.size.width, 1)), 0), 1)
            })
            .onHover { inside in
                (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
        }
    }
}
