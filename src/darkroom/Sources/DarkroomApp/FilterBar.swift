import DarkroomCore
import SwiftUI

struct FilterBar: View {
    @ObservedObject var bench: Bench

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases.filter { $0 != .notDeveloped }, id: \.self) { tab($0) }
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 6)
            tab(.notDeveloped)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.black)
    }

    private func tab(_ filter: Filter) -> some View {
        let on = bench.filter == filter
        return Button {
            Panels.dropFocus()
            bench.setFilter(filter)
        } label: {
            Text("\(filter.title) \(bench.counts[filter])")
                .font(Theme.tight(12, .bold)).tracking(2.4).lineLimit(1).fixedSize()
                .foregroundColor(on ? filter.color : Theme.dim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(on ? Theme.pill.fill(Color.white.opacity(0.13)) : nil)
                .overlay(Theme.pill.strokeBorder(on ? filter.color : Color.clear))
                .contentShape(Theme.pill)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailing: some View {
        if let plan = bench.plan, !plan.items.isEmpty {
            if bench.askedBatch != nil { asking(plan) } else { offer(plan) }
        } else if let roll = bench.rollNumber {
            Text("Roll \(roll)").font(Theme.font(11)).foregroundColor(Theme.dim)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(10)).foregroundColor(Theme.dim)
            .multilineTextAlignment(.trailing).lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: 240, alignment: .trailing)
            .layoutPriority(1)
    }

    private func offer(_ plan: PrintPlan) -> some View {
        HStack(spacing: 10) {
            line(bench.planLine(plan))
            Button(bench.batchTitle(plan)) { bench.printBatch() }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .fixedSize()
                .disabled(bench.batchRunning || bench.saveProblem != nil)
        }
    }

    /// In place of the button, so the yes is under the pointer that asked.
    private func asking(_ plan: PrintPlan) -> some View {
        HStack(spacing: 10) {
            line(bench.askLine(plan))
            Button("Cancel") { bench.cancelBatch() }
                .help("Escape")
                .buttonStyle(.plain)
                .font(Theme.font(12, .bold)).foregroundColor(Theme.text)
                .fixedSize()
            Button("Redevelop \(plan.items.count)") { bench.confirmBatch() }
                .help("Return")
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .fixedSize()
                .disabled(bench.batchRunning || bench.saveProblem != nil)
        }
    }
}
