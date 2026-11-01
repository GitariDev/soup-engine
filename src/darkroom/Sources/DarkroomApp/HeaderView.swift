import SwiftUI

/// Sits in the title bar, beside the traffic lights.
struct HeaderView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Theme.accent, lineWidth: 3).frame(width: 12, height: 12)
            Text("SOUP").foregroundColor(Theme.soft)
            Text("|").foregroundColor(Color.white.opacity(0.2))
            Text("DARKROOM").foregroundColor(Theme.soft)
            Spacer()
            if bench.cardPresent {
                Chip(text: "● " + bench.chipText, color: Theme.green)
            } else {
                Chip(text: bench.chipText, color: Theme.dim)
            }
        }
        .font(Theme.font(11, .bold)).tracking(1.5)
        .padding(.leading, 84).padding(.trailing, 14)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.faint).frame(height: 1) }
    }
}
