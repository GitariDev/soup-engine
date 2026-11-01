import Foundation

public enum FrameState: String, Sendable, Equatable, CaseIterable {
    case yourChoice, printed, shotOn, noRecord
}

/// The film a frame was shot on, and where that came from.
public struct ShotOn: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case roll, cardPrint }
    public let film: String
    public let source: Source

    public init(film: String, source: Source) {
        self.film = film
        self.source = source
    }
}

/// One real print of a frame, as a file.
public struct StackPrint: Sendable, Equatable, Identifiable {
    public let url: URL
    /// Nil for a card print with no tag: the film is not known, so none is named.
    public let film: String?
    /// The `FLM_` beside the CR2, rather than a print this app made.
    public let isCardPrint: Bool

    public init(url: URL, film: String?, isCardPrint: Bool) {
        self.url = url
        self.film = film
        self.isCardPrint = isCardPrint
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    /// Reads the volume the print is on, so it never runs on the main actor.
    public var isOnDisk: Bool { isPrint(url) }
}

/// A CR2 with everything known about it. The state follows the plan's table:
/// exactly one of four, and Not developed is a separate question.
public struct Frame: Sendable, Equatable, Identifiable {
    public let file: FrameFile
    public let rollMatch: RollMatch
    /// This app's prints of the frame still on disk.
    public let deskPrints: [DeskPrint]
    /// The user's pick. Never equal to the film it would develop on anyway.
    public let choice: String?
    /// The shot-on film's can, if it is on the shelf: the film this frame
    /// would develop on with no choice made (R4).
    public let otherwiseFilm: Film?
    private let choiceCan: Film?

    /// A choice equal to this file's own film does not count here. It stays in
    /// the record: a copy of the frame with no record may be the one that made it.
    public init(file: FrameFile, rollMatch: RollMatch, record: inout BenchRecord, shelf: FilmShelf) {
        self.file = file
        self.rollMatch = rollMatch
        deskPrints = record.deskPrints(for: file.identity)
        let recorded = Self.shotOn(rollMatch, file.cardPrint)
        otherwiseFilm = recorded.flatMap { shelf.film(named: $0.film) }
        var picked = record.choices[file.identity]
        if let p = picked, let other = otherwiseFilm, Film.key(p) == Film.key(other.name) { picked = nil }
        choice = picked
        choiceCan = picked.flatMap { shelf.film(named: $0) }
    }

    /// One frame per file, joined to the roll and the record.
    public static func assemble(_ files: [FrameFile], roll: RollFile?, record: inout BenchRecord,
                                shelf: FilmShelf) -> [Frame] {
        files.map { file in
            Frame(file: file, rollMatch: roll?.match(file) ?? RollMatch.noRollFile, record: &record, shelf: shelf)
        }
    }

    /// The same frame after the record or the shelf changed.
    public func updated(record: inout BenchRecord, shelf: FilmShelf) -> Frame {
        Frame(file: file, rollMatch: rollMatch, record: &record, shelf: shelf)
    }

    /// A roll conflict is no record, even with a print beside the frame.
    private static func shotOn(_ match: RollMatch, _ print: CardPrint?) -> ShotOn? {
        switch match {
        case .matched(let film, _): return ShotOn(film: film, source: .roll)
        case .conflict: return nil
        case .none: return print?.film.map { ShotOn(film: $0, source: .cardPrint) }
        }
    }

    /// Unique in a list, unlike `identity`: a copied folder holds the same frame twice.
    public var id: String { file.url.path }
    public var identity: String { file.identity }
    public var name: String { file.name }
    /// The four digits before the extension.
    public var number: Int? { file.number }
    public var isReadable: Bool { file.isReadable }
    public var cardPrint: CardPrint? { file.cardPrint }

    public var shotOnFilm: ShotOn? { Self.shotOn(rollMatch, file.cardPrint) }

    /// The choice, else the shot-on film when it is on the shelf, else nil.
    public var developingFilm: String? { choice ?? otherwiseFilm?.name }

    /// The film to develop on, when it is on the shelf.
    public var developingCan: Film? { choice == nil ? otherwiseFilm : choiceCan }

    /// False when there is no film, the film is not on the shelf (a choice can
    /// leave the shelf with its card), or the engine cannot read the CR2.
    public var canPrint: Bool { isReadable && developingCan != nil }

    /// Rule 1: a non-empty `FLM_` beside it. Rule 2: this app's print on disk.
    public var isDeveloped: Bool { cardPrint != nil || !deskPrints.isEmpty }

    /// Every film this frame is printed on, the card's first.
    public var printedFilms: [String] { [cardPrint?.film].compactMap { $0 } + deskPrints.map(\.film) }

    /// Every print of this frame on disk as of the last look: the card's first,
    /// then this app's in the order made. One file is one print, so this is the
    /// count. `printedFilms` is not: a card print with no tag has no film to list.
    public var stack: [StackPrint] {
        let card = cardPrint.map { StackPrint(url: $0.url, film: $0.film, isCardPrint: true) }
        let desk = deskPrints.map { StackPrint(url: $0.url, film: $0.film, isCardPrint: false) }
        var seen = Set<String>()
        return ([card].compactMap { $0 } + desk).filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// A choice with no print on that film yet. Once it is printed nothing is pending.
    public var hasPendingChoice: Bool {
        guard let choice else { return false }
        return !printedFilms.contains { Film.key($0) == Film.key(choice) }
    }

    public var state: FrameState {
        if hasPendingChoice { return .yourChoice }
        if isDeveloped { return .printed }
        return shotOnFilm == nil ? .noRecord : .shotOn
    }

    /// G4: when no film is recorded, why, in plain words.
    public var noRecordReason: String? {
        guard shotOnFilm == nil else { return nil }
        return rollMatch.reason ?? "No film is recorded for this frame."
    }

    /// Why this frame does not print, in plain words, or nil when it does.
    public var holdReason: String? {
        if !isReadable { return "This CR2 cannot be read" }
        if canPrint { return nil }
        if let film = developingFilm ?? shotOnFilm?.film { return "\(Film.display(film)) is not on the shelf" }
        return "No film is recorded"
    }

    /// Why Print waits, and what to do about it, or nil when it does not.
    public var printHold: String? {
        holdReason.map { isReadable ? "\($0). Choose a can to print." : "\($0)." }
    }
}
