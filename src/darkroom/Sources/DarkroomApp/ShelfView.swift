import DarkroomCore
import SwiftUI

struct ShelfView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Kicker("\(bench.films.count) \(bench.films.count == 1 ? "FILM" : "FILMS")")
                    .lineLimit(1).fixedSize()
                Spacer()
                Button {
                    if let url = Panels.pickFilm() { bench.addFilm(from: url) }
                } label: {
                    Text("+ ADD").font(Theme.tight(11, .bold)).tracking(2.2).foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)

            if bench.films.isEmpty {
                Text("No films here. Add a .fs file.")
                    .font(Theme.font(12)).foregroundColor(Theme.dim)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(bench.films) { film in can(film).id(film.id) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .onChange(of: bench.developingFilmID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .frame(width: 136)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.faint).frame(width: 1) }
    }

    private func can(_ film: Film) -> some View {
        let selected = bench.developingFilmID == film.id
        let shotOn = bench.shotOnFilmID == film.id
        return Button {
            Panels.dropFocus()
            // A frame with no record can only go back to no film by picking the can again.
            let clears = selected && bench.current?.shotOnFilm == nil
            bench.choose(film: clears ? nil : film)
        } label: {
            CanView(film: film, selected: selected)
                .overlay(alignment: .top) {
                    if shotOn {
                        Text("SHOT ON").font(Theme.tight(9.5, .bold)).tracking(0.95)
                            .foregroundColor(Theme.ink).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                            .offset(y: -10)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(film.displayName)
    }
}
