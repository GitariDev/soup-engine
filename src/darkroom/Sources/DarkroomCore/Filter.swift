import Foundation

public enum Filter: String, Sendable, Equatable, CaseIterable {
    case all, shotOn, printed, yourChoice, noRecord, notDeveloped

    public func includes(_ frame: Frame) -> Bool {
        switch self {
        case .all: return true
        case .shotOn: return frame.state == .shotOn
        case .printed: return frame.state == .printed
        case .yourChoice: return frame.state == .yourChoice
        case .noRecord: return frame.state == .noRecord
        case .notDeveloped: return !frame.isDeveloped
        }
    }

    public func apply(to frames: [Frame]) -> [Frame] { frames.filter(includes) }
}

/// All and the four states add up. Not developed is a separate axis.
public struct FilterCounts: Sendable, Equatable {
    public private(set) var all = 0
    public private(set) var shotOn = 0
    public private(set) var printed = 0
    public private(set) var yourChoice = 0
    public private(set) var noRecord = 0
    public private(set) var notDeveloped = 0

    public init(_ frames: [Frame]) {
        for f in frames {
            all += 1
            switch f.state {
            case .shotOn: shotOn += 1
            case .printed: printed += 1
            case .yourChoice: yourChoice += 1
            case .noRecord: noRecord += 1
            }
            if !f.isDeveloped { notDeveloped += 1 }
        }
    }

    public subscript(filter: Filter) -> Int {
        switch filter {
        case .all: return all
        case .shotOn: return shotOn
        case .printed: return printed
        case .yourChoice: return yourChoice
        case .noRecord: return noRecord
        case .notDeveloped: return notDeveloped
        }
    }
}
