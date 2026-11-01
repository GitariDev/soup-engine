import CoreGraphics
import DarkroomCore
import SwiftUI

/// The bar above this redraws on every wipe step, and a strip of thousands of
/// frames must not: `Rows` only redraws when the list or the selection changes.
struct StripView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        Rows(frames: bench.visible, version: bench.stripVersion, selected: bench.selectedID,
             empty: bench.stripEmptyLine, broken: bench.broken, thumbs: bench.thumbs,
             select: { id in
                 Panels.dropFocus()
                 bench.select(id)
             })
            .equatable()
            .frame(height: 106)
            .background(Theme.black)
    }

    private struct Rows: View, Equatable {
        let frames: [Frame]
        let version: Int
        let selected: String?
        let empty: String
        let broken: Set<String>
        let thumbs: Thumbnails
        let select: (String) -> Void

        static func == (a: Rows, b: Rows) -> Bool {
            a.version == b.version && a.selected == b.selected && a.empty == b.empty && a.broken == b.broken
        }

        var body: some View {
            if frames.isEmpty {
                Text(empty).font(Theme.font(12)).foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 2) {
                            ForEach(frames) { frame in
                                Cell(frame: frame, selected: frame.id == selected, broken: broken.contains(frame.id),
                                     thumbs: thumbs)
                                    .id(frame.id)
                                    .onTapGesture { select(frame.id) }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: selected) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private struct Cell: View {
        let frame: Frame
        let selected: Bool
        let broken: Bool
        let thumbs: Thumbnails
        @State private var image: CGImage?

        var body: some View {
            VStack(spacing: 3) {
                ZStack {
                    Color.white.opacity(0.04)
                    if let shown = image ?? thumbs.cached(frame) {
                        Image(decorative: shown, scale: 1).resizable().interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                    } else if !frame.isReadable || broken {
                        Text("?").font(Theme.font(20, .bold)).foregroundColor(Theme.warn)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !frame.isDeveloped {
                        Circle().strokeBorder(Theme.soft, lineWidth: 1).background(Circle().fill(Color.black.opacity(0.5)))
                            .frame(width: 7, height: 7).padding(3)
                            .help("Not developed")
                    }
                }
                .frame(width: 106, height: 72)
                .clipped()
                HStack(spacing: 2) {
                    Text(frame.file.digits ?? frame.file.stem).foregroundColor(Color(hex: "#d8a64a"))
                    Spacer(minLength: 2)
                    Text(broken ? "UNREADABLE" : frame.stateWord).foregroundColor(broken ? Theme.warn : frame.stateColor)
                }
                .font(Theme.mono(9)).lineLimit(1)
                .frame(width: 106)
            }
            .padding(.horizontal, 4).padding(.vertical, 7)
            .overlay(Rectangle().strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            // `.task` is cancelled when a lazy cell scrolls away.
            .task(id: frame.id) {
                guard thumbs.cached(frame) == nil, frame.isReadable else { return }
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
                image = await thumbs.load(frame)
            }
        }
    }
}
