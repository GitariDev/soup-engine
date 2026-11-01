import SwiftUI

/// Sits in the title bar, beside the traffic lights.
struct HeaderView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Theme.accent, lineWidth: 3).frame(width: 12, height: 12)
            Text("SOUP").font(Theme.tight(13, .bold)).tracking(2.21).foregroundColor(Theme.soft)
            Rectangle().fill(Theme.line).frame(width: 1, height: 12)
            Text("DARKROOM").font(Theme.tight(12, .semibold)).tracking(2.04).foregroundColor(Theme.dim)
            Spacer()
            if bench.cardPresent {
                Chip(text: "● " + bench.chipText, color: Theme.green)
            } else {
                Chip(text: bench.chipText, color: Theme.dim)
            }
        }
        .padding(.leading, 84).padding(.trailing, 14)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.faint).frame(height: 1) }
    }
}
