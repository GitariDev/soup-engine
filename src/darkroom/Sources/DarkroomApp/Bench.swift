import AppKit
import CoreGraphics
import DarkroomCore
import DarkroomEngine
import Foundation

/// What a picture on the enlarger is of. Every result is keyed on this, so a
/// render that finishes late can never land on the wrong frame or film.
struct PictureKey: Hashable {
    let frame: String
    let film: String

    static let straight = "straight"
    static let embedded = "embedded"

    init(_ frame: Frame, film: Film?) {
        self.frame = frame.id + "|" + frame.identity
        self.film = film?.path.path ?? Self.straight
    }

    init(embedded frame: Frame) {
        self.frame = frame.id + "|" + frame.identity
        film = Self.embedded
    }

    init(_ frame: Frame, print: StackPrint) {
        self.frame = frame.id + "|" + frame.identity
        film = "print|" + print.id
    }
}

struct Picture {
    enum Stage: Int, Comparable {
        case thumbnail, placeholder, quick, fine
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    let key: PictureKey
    let image: CGImage
    let stage: Stage

    /// G1: below this it is Canon's JPEG, not the film.
    var isDeveloped: Bool { stage >= .quick }
    var cost: Int { image.bytesPerRow * image.height }
}

/// The other side of the compare.
struct Comparison: Equatable {
    /// Nil is the straight raw.
    let film: Film?
    let label: String
    /// The picture on the enlarger differs from it, so the wipe is on.
    let wipes: Bool
    let developingLabel: String
}

/// Where the enlarger is on a frame's stack. Looking never changes a state, a
/// choice or what Print makes.
enum StackPlace: Equatable {
    /// The film in hand, live: what Print would make.
    case film
    /// What Space shows: the frame on its shot-on can, or the straight raw.
    case original
    /// A print, by path: the file itself, never a render of it.
    case print(String)
}

/// Where the frames came from.
enum OpenSource: Equatable {
    case none
    case card(Card)
    case folder(URL)
}

struct ScanProgress: Equatable {
    var read: Int
    var total: Int
}

struct BatchRun {
    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let reason: String
    }

    let total: Int
    let folder: URL
    let place: String
    /// The frames that waited, and why the ones still waiting do.
    let waiting: Set<String>
    var holds: [(reason: String, count: Int)]
    let unreadable: Int
    var started = 0
    var printed = 0
    var failures: [Failure] = []
    var stopping = false
    var finished = false

    var notRun: Int { total - printed - failures.count }
}

/// Thumbnails for the strip, held so that a cell scrolled back is there at once.
final class Thumbnails: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let store = NSCache<NSString, Box>()
    private let darkroom: Darkroom

    init(darkroom: Darkroom) {
        self.darkroom = darkroom
        store.totalCostLimit = 256 << 20
    }

    func cached(_ frame: Frame) -> CGImage? { store.object(forKey: frame.id as NSString)?.image }

    func load(_ frame: Frame) async -> CGImage? {
        guard let image = try? await darkroom.thumbnail(frame.file.url), !Task.isCancelled else { return nil }
        store.setObject(Box(image), forKey: frame.id as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// The whole bench: everything that is not view code.
@MainActor
final class Bench: ObservableObject {
    // What is open.
    @Published private(set) var source: OpenSource = .none
    @Published private(set) var cardGone: String?
    /// Reading the volumes: nothing here can run on the main actor, because
    /// macOS holds the first read of a card until the user answers its prompt.
    @Published private(set) var looking = false
    @Published private(set) var refusedVolume: String?
    @Published private(set) var scan: ScanProgress?
    @Published private(set) var frames: [Frame] = []
    @Published private(set) var films: [Film] = []
    @Published private(set) var rollNumber: Int?

    // The strip.
    @Published private(set) var filter: Filter = .all
    @Published private(set) var counts = FilterCounts([])
    @Published private(set) var visible: [Frame] = []
    @Published private(set) var stripVersion = 0
    @Published private(set) var plan: PrintPlan?

    // The frame on the enlarger.
    @Published private(set) var selectedID: String?
    /// The selection while an empty tab has nothing to show it on.
    private var heldID: String?
    @Published private(set) var current: Frame?
    @Published private(set) var main: Picture? {
        didSet { if main?.key == workKeys.first { filmLate = false } }
    }
    /// The picture has been the wrong film for more than a moment.
    @Published private(set) var filmLate = false
    @Published private(set) var compare: Picture?
    @Published private(set) var comparison: Comparison?
    @Published private(set) var pictureProblem: String?
    /// Frames whose header reads but whose sensor data does not.
    @Published private(set) var broken: Set<String> = []
    @Published var holdShotOn = false
    @Published var wipe = 0.5
    /// A print shows whole until the user wipes it: nothing else tells prints apart.
    @Published var printWipe = 0.0
    @Published private(set) var place: StackPlace = .film
    /// Prints found missing since the frames were last read. A frame keeps what
    /// the card told it when the card is pulled, so this is what hides its print.
    @Published private var gone: Set<String> = []

    // Printing.
    @Published private(set) var saveFolder: URL
    @Published private(set) var saveProblem: String?
    @Published var nameDraft: String?
    @Published var half = false
    @Published private(set) var printingIDs: Set<String> = []
    @Published private(set) var printError: String?
    @Published private(set) var lastPrint: (frame: String, url: URL)?
    @Published private(set) var batch: BatchRun?
    /// The frames a redevelop is waiting on a yes for.
    @Published private(set) var askedBatch: [String]?

    /// Says what just went wrong. Nothing to dismiss: the next action replaces it.
    @Published private(set) var notice: String?

    let darkroom: Darkroom
    let thumbs: Thumbnails

    private let support: URL
    private var record: BenchRecord
    private var shelf: FilmShelf
    private var roll: RollFile?
    private var openedSource: BenchSource?
    private var files: [FrameFile] = []

    private var generation = 0
    private var scanTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var workKeys: [PictureKey] = []
    private var lateTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?

    private var loadedFilms: [String: DarkroomFilm] = [:]
    private var cache: [PictureKey: Picture] = [:]
    private var cacheOrder: [PictureKey] = []
    private var cacheCost = 0
    /// Most of these are the engine's own images, so this costs little on top.
    private static let cacheLimit = 400 << 20

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static var stocksFolder: URL? {
        if let env = ProcessInfo.processInfo.environment["SOUP_STOCKS"] { return URL(fileURLWithPath: env) }
        return Bundle.main.resourceURL?.appendingPathComponent("stocks")
    }

    /// `support` holds the bench record, added films and the last-open folder.
    init(support: URL = BenchRecord.defaultDirectory, cache: URL = Darkroom.defaultCacheDirectory) {
        self.support = support
        let dark = Darkroom(cacheDirectory: cache)
        darkroom = dark
        thumbs = Thumbnails(darkroom: dark)
        var problem: String?
        do {
            record = try BenchRecord.load(directory: support, checkPrints: false)
            if let aside = record.setAside {
                problem = "The bench record could not be read. It was kept as \(aside.lastPathComponent)."
            }
        } catch {
            record = BenchRecord(directory: support)
            problem = error.localizedDescription
        }
        saveFolder = record.saveFolder ?? Destination.defaultFolder()
        shelf = FilmShelf(cardFolder: nil, addedFolder: support.appendingPathComponent("Films", isDirectory: true),
                          bundledFolder: Self.stocksFolder)
        films = shelf.ordered
        notice = problem
        checkSaveFolder()
        watchSystem()
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let add = { [weak self] (center: NotificationCenter, name: Notification.Name, run: @escaping @MainActor (Bench, Notification) -> Void) in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    run(self, note)
                }
            }
            self?.observers.append((center, token))
        }
        add(workspace, NSWorkspace.didMountNotification) { bench, note in bench.volumeMounted(note) }
        add(workspace, NSWorkspace.didUnmountNotification) { bench, note in bench.volumeUnmounted(note) }
        add(.default, NSApplication.didBecomeActiveNotification) { bench, _ in bench.becameActive() }
    }

    /// First look: a path given at launch, then a card, then the last folder.
    func start(path: String?) {
        if let path {
            open(URL(fileURLWithPath: path))
            return
        }
        let token = generation
        looking = true
        Task { [weak self] in
            let (cards, refused) = await Task.detached {
                let volumes = CardFinder.mountedVolumes()
                return (CardFinder.findCards(volumes: volumes), CardFinder.refusedVolumes(volumes: volumes))
            }.value
            guard let self, token == self.generation else { return }
            self.looking = false
            self.refusedVolume = refused.first
            if let card = cards.first {
                self.open(card.root)
            } else if let last = self.lastOpen {
                self.open(last)
            }
        }
    }

    /// Back from System Settings, a refused card may have become readable.
    private func becameActive() {
        if case .none = source, !looking {
            start(path: nil)
        } else {
            rescan()
        }
    }

    // MARK: Opening

    func open(_ url: URL) {
        generation += 1
        let token = generation
        scanTask?.cancel()
        rescanTask?.cancel()
        notice = nil
        looking = true
        scan = ScanProgress(read: 0, total: 0)
        scanTask = Task { [weak self] in
            let found = await Task.detached { () -> Result<(BenchSource, Card?), Error> in
                Result {
                    let opened = try DarkroomCore.Bench.open(folderOrFile: url)
                    return (opened, Self.card(holding: url))
                }
            }.value
            guard let self, token == self.generation else { return }
            self.looking = false
            switch found {
            case .failure(let error):
                self.scan = nil
                self.notice = error.localizedDescription
            case .success(let (opened, card)):
                await self.read(opened, url: url, card: card, token: token)
            }
        }
    }

    /// Only the volume in question: a folder on the Mac needs no card permission.
    private nonisolated static func card(holding url: URL) -> Card? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        let root = URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2])
        return CardFinder.findCards(volumes: [root]).first
    }

    private func read(_ opened: BenchSource, url: URL, card: Card?, token: Int) async {
        openedSource = opened
        cardGone = nil
        refusedVolume = nil
        source = card.map(OpenSource.card) ?? .folder(url)
        if card == nil { lastOpen = url }
        files = []
        frames = []
        broken = []
        filter = .all
        selectedID = nil
        heldID = nil
        lastPrint = nil
        current = nil
        place = .film
        gone = []
        roll = nil
        rollNumber = nil
        scan = ScanProgress(read: 0, total: 0)
        derive()
        develop()

        let added = shelf.addedFolder, bundled = shelf.bundledFolder
        let known = record
        let (shelf, roll, prints) = await Task.detached {
            (FilmShelf(cardFolder: opened.filmFolder, addedFolder: added, bundledFolder: bundled),
             opened.rollFile.flatMap(RollFile.read), known.presence())
        }.value
        guard token == generation else { return }
        self.shelf = shelf
        self.roll = roll
        record.take(prints)
        rollNumber = roll?.latestRoll
        films = shelf.ordered
        loadFilms()
        for await event in FrameScanner().stream(opened) {
            guard token == generation else { return }
            take(event)
        }
    }

    private func take(_ event: ScanEvent) {
        switch event {
        case .listed(let total, let problems):
            scan = ScanProgress(read: 0, total: total)
            if let first = problems.first { notice = first }
        case .frames(let batch):
            files += batch
            frames += Frame.assemble(batch, roll: roll, record: &record, shelf: shelf)
            scan?.read = files.count
            derive()
            // One file was asked for, so it is the one to show.
            if isLoneFile, selectedID == nil { select(frames.first?.id) }
        case .finished:
            scan = nil
        }
    }

    /// Films are read ahead so a card pulled later does not take them with it.
    private func loadFilms() {
        let missing = films.filter { loadedFilms[$0.path.path] == nil }
        Task { [weak self] in
            for film in missing { _ = await self?.loaded(film) }
        }
    }

    private func loaded(_ film: Film) async -> DarkroomFilm? {
        if let hit = loadedFilms[film.path.path] { return hit }
        let path = film.path
        let made = await Task.detached { DarkroomFilm(url: path) }.value
        if let made { loadedFilms[path.path] = made }
        return made
    }

    private var lastOpenFile: URL { support.appendingPathComponent("last-open.txt") }

    private var lastOpen: URL? {
        get {
            guard let path = try? String(contentsOf: lastOpenFile, encoding: .utf8),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? newValue?.path.write(to: lastOpenFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Cards coming and going

    private func volumeMounted(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        Task { [weak self] in
            let card = await Task.detached { CardFinder.findCards(volumes: [url]).first }.value
            if let card { self?.open(card.root) }
        }
    }

    private func volumeUnmounted(_ note: Notification) {
        guard case .card(let card) = source,
              let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              url.standardizedFileURL.path == card.root.standardizedFileURL.path else { return }
        cardWentAway(card.name)
    }

    /// Everything already on the bench stays. Frames decoded so far still show.
    private func cardWentAway(_ name: String) {
        generation += 1
        scanTask?.cancel()
        rescanTask?.cancel()
        scan = nil
        cardGone = name
        notice = nil
    }

    /// Cheap: names and sizes first, and only new or changed files are opened.
    func rescan() {
        guard scan == nil, cardGone == nil, batch?.finished != false else { return }
        guard let picked = openedSource?.picked else { return }
        generation += 1
        let token = generation
        let known = Dictionary(files.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let added = shelf.addedFolder, bundled = shelf.bundledFolder
        let printed = record

        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            let fresh = await Task.detached { () -> Rescan? in
                guard let opened = try? DarkroomCore.Bench.open(folderOrFile: picked) else { return nil }
                let scanner = FrameScanner()
                var out: [FrameFile] = []
                for folder in opened.folders {
                    let listing = scanner.list(folder)
                    if listing.problem != nil { return nil }
                    for entry in listing.cr2s {
                        if let only = opened.onlyFile, only.lastPathComponent != entry.url.lastPathComponent { continue }
                        if Task.isCancelled { return nil }
                        if let old = known[entry.url.path], Self.unchanged(old, entry, listing) {
                            out.append(old)
                        } else {
                            out.append(scanner.read(entry, in: listing))
                        }
                    }
                }
                let shelf = FilmShelf(cardFolder: opened.filmFolder, addedFolder: added, bundledFolder: bundled)
                return Rescan(opened: opened, files: out, roll: opened.rollFile.flatMap(RollFile.read), shelf: shelf,
                              prints: printed.presence())
            }.value
            guard let self, token == self.generation, let fresh else { return }
            self.apply(rescan: fresh)
        }
    }

    private nonisolated static func unchanged(_ old: FrameFile, _ entry: FolderListing.Entry,
                                              _ listing: FolderListing) -> Bool {
        guard old.bytes == entry.bytes else { return false }
        let beside = old.digits.flatMap { listing.prints[$0] }
        return old.cardPrint?.url == (beside?.bytes ?? 0 > 0 ? beside?.url : nil)
            && old.cardPrint?.bytes == (beside?.bytes ?? 0 > 0 ? beside?.bytes : nil)
            && old.cutOffPrint == (beside?.bytes == 0)
    }

    private struct Rescan: Sendable {
        let opened: BenchSource
        let files: [FrameFile]
        let roll: RollFile?
        let shelf: FilmShelf
        let prints: [String: Bool]
    }

    private func apply(rescan fresh: Rescan) {
        openedSource = fresh.opened
        files = fresh.files
        roll = fresh.roll
        rollNumber = fresh.roll?.latestRoll
        shelf = fresh.shelf
        record.take(fresh.prints)
        gone = []
        if films != shelf.ordered {
            films = shelf.ordered
            loadFilms()
        }
        let next = Frame.assemble(files, roll: roll, record: &record, shelf: shelf)
        // A print on the enlarger may have been changed where it stands.
        if shownPrint != nil { workKeys = [] }
        if next != frames {
            frames = next
            derive()
        }
        develop()
    }

    // MARK: The strip

    private func derive() {
        counts = FilterCounts(frames)
        if let id = selectedID, !frames.contains(where: { $0.id == id }) {
            selectedID = nil
            nameDraft = nil
        }
        if let id = heldID, !frames.contains(where: { $0.id == id }) { heldID = nil }
        // The selected frame stays on the strip when its state changes under
        // the filter, so choosing a can does not pull it away from the user.
        visible = frames.filter { filter.includes($0) || $0.id == selectedID }
        stripVersion += 1
        current = selectedID.flatMap { id in visible.first { $0.id == id } }
        plan = filter == .all ? nil : PrintPlan(frames: filter.apply(to: frames), destination: saveFolder)
        // A yes holds for the frames it was asked about, and no others.
        if askedBatch != plan?.items.map(\.frame.id) { askedBatch = nil }
        settleBatch()
    }

    /// A finished batch's skips hold only while those frames still wait.
    private func settleBatch() {
        guard let run = batch, run.finished, !run.waiting.isEmpty else { return }
        let still = frames.filter { run.waiting.contains($0.id) && !$0.canPrint && !isUnreadable($0) }
        if still.isEmpty {
            batch = nil
        } else {
            batch?.holds = PrintPlan.holds(of: still)
        }
    }

    func setFilter(_ filter: Filter) {
        self.filter = filter
        askedBatch = nil
        lastPrint = nil
        if batch?.finished == true { batch = nil }
        let wanted = selectedID ?? heldID
        if let id = wanted, let frame = frames.first(where: { $0.id == id }), filter.includes(frame) {
            if selectedID == nil {
                select(id)
            } else {
                derive()
            }
            return
        }
        if selectedID != nil {
            selectedID = nil
            derive()
        }
        if let first = filter.apply(to: frames).first?.id {
            select(first)
        } else {
            heldID = wanted
            derive()
            develop()
        }
    }

    /// A frame that has left the filter gives way to the next one still in it,
    /// and when none is left the tab is empty and the selection is held.
    private func moveOn(from id: String) {
        guard selectedID == id, let at = visible.firstIndex(where: { $0.id == id }),
              !filter.includes(visible[at]) else { return }
        let next = visible[(at + 1)...].first(where: filter.includes) ?? visible[..<at].last(where: filter.includes)
        if let next {
            select(next.id)
        } else {
            selectedID = nil
            heldID = id
            nameDraft = nil
            derive()
            develop()
        }
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        notice = nil
        heldID = nil
        selectedID = id
        nameDraft = nil
        half = false
        centreLineAtAnEnd()
        printError = nil
        printWipe = 0
        derive()
        place = landing
        checkStack()
        develop()
    }

    /// Left and right, within the current filter.
    func stepFrame(by delta: Int) {
        guard !visible.isEmpty else { return }
        guard let id = selectedID, let at = visible.firstIndex(where: { $0.id == id }) else {
            select(visible[delta > 0 ? 0 : visible.count - 1].id)
            return
        }
        let next = at + delta
        if visible.indices.contains(next) { select(visible[next].id) }
    }

    /// Up and down, along the shelf.
    func stepFilm(by delta: Int) {
        guard current != nil, !films.isEmpty else { return }
        guard let id = developingFilmID, let at = films.firstIndex(where: { $0.id == id }) else {
            choose(film: films[delta > 0 ? 0 : films.count - 1])
            return
        }
        let next = at + delta
        if films.indices.contains(next) { choose(film: films[next]) }
    }

    // MARK: Choosing a film

    /// Picking the frame's own recorded film clears the choice, and so does nil.
    func choose(film: Film?) {
        guard let frame = current else { return }
        record.choose(film, for: frame)
        centreLineAtAnEnd()
        nameDraft = nil
        lastPrint = nil
        printError = nil
        place = .film
        save()
        rebuild(identity: frame.identity)
        develop()
    }

    func addFilm(from url: URL) {
        do {
            try shelf.addFilm(from: url)
            films = shelf.ordered
            notice = nil
            loadFilms()
            let all = frames.map { $0.updated(record: &record, shelf: shelf) }
            frames = all
            derive()
            develop()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func save() {
        do {
            try record.save()
        } catch {
            notice = "The bench record could not be saved: \(error.localizedDescription)"
        }
    }

    private func rebuild(identity: String) {
        var all = frames
        for i in all.indices where all[i].identity == identity {
            all[i] = all[i].updated(record: &record, shelf: shelf)
        }
        frames = all
        derive()
    }

    var developingFilmID: String? { current?.developingCan?.id }
    var shotOnFilmID: String? { current?.otherwiseFilm?.id ?? current?.shotOnFilm.map { Film.key($0.film) } }

    // MARK: The stack

    /// This frame's prints as the disk has them, oldest first. Its length is the count.
    var stack: [StackPrint] { current?.stack.filter { !gone.contains($0.id) } ?? [] }

    var shownPrint: StackPrint? {
        guard case .print(let path) = place else { return nil }
        return stack.first { $0.id == path }
    }

    /// "PRINT 2 OF 3" on a print, "3 PRINTS" anywhere else.
    var stackLabel: String {
        let all = stack
        if let print = shownPrint, let at = all.firstIndex(of: print) { return "PRINT \(at + 1) OF \(all.count)" }
        return "\(all.count) \(all.count == 1 ? "PRINT" : "PRINTS")"
    }

    /// Which one is up: the film in hand is the original when it is the same picture.
    var onOriginal: Bool {
        !stack.isEmpty && (place == .original || (place == .film && current?.developsAsOriginal == true))
    }

    /// A film in hand with no print yet, which the stack cannot show any other way.
    var pendingFilm: Film? { current.flatMap { $0.hasPendingChoice ? $0.developingCan : nil } }

    /// What Space can show. A print is never called the original, even when its
    /// CR2 cannot be read and there is no original to show.
    var spacePicture: Picture? {
        if comparison?.wipes == true { return compare }
        return shownPrint == nil ? main : nil
    }

    /// The picture up is what Print would make.
    var showsFilmInHand: Bool {
        switch place {
        case .film: return true
        case .original: return current?.developsAsOriginal == true
        case .print: return false
        }
    }

    private var stops: [StackPlace] {
        let prints = stack
        guard !prints.isEmpty else { return [] }
        return [.original] + prints.map { .print($0.id) } + (pendingFilm == nil ? [] : [.film])
    }

    /// `[` and `]`, and the arrows beside the count. It wraps, so it cycles.
    func stepStack(by delta: Int) {
        let stops = stops
        guard !stops.isEmpty else { return }
        guard let at = stops.firstIndex(of: onOriginal ? .original : place) else {
            go(to: stops[delta > 0 ? 0 : stops.count - 1])
            return
        }
        go(to: stops[(at + delta + stops.count) % stops.count])
    }

    func go(to place: StackPlace) {
        guard current != nil, place != self.place else { return }
        self.place = place
        checkStack()
        develop()
    }

    /// A printed frame opens on its newest print, and any other on the film in hand.
    private var landing: StackPlace {
        guard current?.state == .printed, let newest = stack.last else { return .film }
        return .print(newest.id)
    }

    /// The count is what is on disk now, so each look at a stack asks the disk.
    private func checkStack() {
        guard let frame = current else { return }
        let prints = frame.stack
        guard !prints.isEmpty else { return }
        Task { [weak self] in
            let found = await Task.detached {
                Dictionary(prints.map { ($0.id, $0.isOnDisk) }, uniquingKeysWith: { a, _ in a })
            }.value
            self?.take(found, of: frame)
        }
    }

    private func take(_ found: [String: Bool], of frame: Frame) {
        let missing = Set(found.filter { !$0.value }.keys)
        gone = gone.subtracting(found.keys).union(missing)
        guard !missing.isEmpty else { return }
        record.take(found)
        rebuild(identity: frame.identity)
        develop()
        rescan()
    }

    // MARK: The enlarger

    private func compared(with frame: Frame) -> Comparison? {
        let developing = frame.developingCan
        let shot = frame.otherwiseFilm
        let label = shot.map { "SHOT ON \(Film.key($0.name))" } ?? "STRAIGHT RAW"
        if let print = shownPrint {
            let right = stackLabel + (print.film.map { " · \(Film.key($0))" } ?? "")
            return Comparison(film: shot, label: label, wipes: !isUnreadable(frame), developingLabel: right)
        }
        if place == .original { return Comparison(film: shot, label: label, wipes: false, developingLabel: "") }
        let wipes = developing != nil && developing?.id != shot?.id
        let right = "YOUR CHOICE \(developing.map { Film.key($0.name) } ?? "")"
        return Comparison(film: shot, label: label, wipes: wipes, developingLabel: right)
    }

    /// The enlarger still shows the film it had before this one was picked.
    var showsOldFilm: Bool { main.map { $0.key != workKeys.first } ?? false }

    /// A line at an end shows one side only, so what just changed could be the
    /// side it hides. Anywhere else the user put it, it stays.
    private func centreLineAtAnEnd() {
        if wipe <= 0 || wipe >= 1 { wipe = 0.5 }
    }

    /// Puts the best picture already held on the bench at once, then works up
    /// through the stages. Whatever was running for another key is cancelled.
    private func develop() {
        if case .print = place, shownPrint == nil { place = landing }
        guard let frame = current else {
            place = .film
            work?.cancel()
            lateTask?.cancel()
            filmLate = false
            workKeys = []
            main = nil
            compare = nil
            comparison = nil
            pictureProblem = nil
            return
        }
        let print = shownPrint
        let film = place == .original ? frame.otherwiseFilm : frame.developingCan
        let mainKey = print.map { PictureKey(frame, print: $0) } ?? PictureKey(frame, film: film)
        let side = compared(with: frame)
        let sideKey = side.flatMap { $0.wipes ? PictureKey(frame, film: $0.film) : nil }
        let keys = [mainKey, sideKey].compactMap { $0 }
        comparison = side
        guard keys != workKeys else { return }
        workKeys = keys
        work?.cancel()
        lateTask?.cancel()
        filmLate = false
        pictureProblem = nil
        // A print is its own file, and needs nothing from the CR2.
        guard print != nil || (frame.isReadable && !broken.contains(frame.id)) else {
            showUnreadable(Self.reason(DarkroomError.unreadable(frame.name)))
            return
        }

        // G1 holds: only a developed picture of this frame stays up, and only
        // until its film arrives. The label and the chip say it is the old one.
        if let held = cache[mainKey] {
            main = held
        } else if let old = main, old.isDeveloped, old.key.frame == mainKey.frame {
            lateTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.showsOldFilm else { return }
                self.filmLate = true
            }
        } else {
            main = bestStandIn(frame, key: mainKey)
        }
        compare = sideKey.flatMap { cache[$0] }
        let others = films
        work = Task { [weak self] in
            await self?.work(on: frame, print: print, film: film, side: side, mainKey: mainKey, sideKey: sideKey,
                             others: others)
        }
    }

    /// No stand-in stays up: with nothing left to arrive, DEVELOPING would be
    /// a promise, and there is nothing to compare.
    private func showUnreadable(_ why: String) {
        main = nil
        compare = nil
        comparison = nil
        pictureProblem = why
    }

    private func bestStandIn(_ frame: Frame, key: PictureKey) -> Picture? {
        if let embedded = cache[PictureKey(embedded: frame)] {
            return Picture(key: key, image: embedded.image, stage: .placeholder)
        }
        return thumbs.cached(frame).map { Picture(key: key, image: $0, stage: .thumbnail) }
    }

    private func work(on frame: Frame, print: StackPrint?, film: Film?, side: Comparison?, mainKey: PictureKey,
                      sideKey: PictureKey?, others: [Film]) async {
        do {
            // A task cancelled before it first ran must not touch the bench,
            // and a hit in the engine's cache returns without looking.
            try Task.checkCancellation()
            if let print {
                try await show(print, of: frame, key: mainKey)
                if !frame.isReadable { return }
                // A step along the stack moves on before this is up.
                if sideKey.flatMap({ cache[$0] }) == nil { try await Task.sleep(for: .milliseconds(150)) }
            } else {
                if (main?.stage ?? .thumbnail) < .placeholder {
                    let image = try await darkroom.placeholder(frame.file.url)
                    try Task.checkCancellation()
                    let embedded = Picture(key: PictureKey(embedded: frame), image: image, stage: .placeholder)
                    remember(embedded)
                    if (main?.stage ?? .thumbnail) < .placeholder {
                        main = Picture(key: mainKey, image: image, stage: .placeholder)
                    }
                }
                // A held arrow key moves on before this is up, so a skim starts no decode.
                if cache[mainKey] == nil { try await Task.sleep(for: .milliseconds(30)) }
                try await render(frame, film, mainKey, .quick) { self.main = $0 }
            }
            if let side, let sideKey {
                try await render(frame, side.film, sideKey, .quick) { self.compare = $0 }
            }
            if print == nil { try await render(frame, film, mainKey, .fine) { self.main = $0 } }
            if let side, let sideKey {
                try await render(frame, side.film, sideKey, .fine) { self.compare = $0 }
            }
            // Every other can, small, so choosing one changes the picture at once.
            for other in others {
                let key = PictureKey(frame, film: other)
                if cache[key] == nil { try await render(frame, other, key, .quick) { _ in } }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, (main?.stage ?? .thumbnail) < .quick || showsOldFilm else { return }
            filmLate = false
            showUnreadable(Self.reason(error))
            if cardGone == nil, FileManager.default.fileExists(atPath: frame.file.url.path) {
                broken.insert(frame.id)
            }
        }
    }

    /// The file, whatever size it is. One that went is out of the stack at once.
    private func show(_ print: StackPrint, of frame: Frame, key: PictureKey) async throws {
        do {
            let image = try await darkroom.printPicture(print.url, frameOrientation: frame.file.facts?.orientation ?? 1)
            try Task.checkCancellation()
            main = Picture(key: key, image: image, stage: .fine)
        } catch DarkroomError.printGone {
            take([print.id: false], of: frame)
            throw CancellationError()
        } catch DarkroomError.printUnreadable {
            try Task.checkCancellation()    // the bench may be on another frame by now
            main = nil
            filmLate = false
            pictureProblem = "\(print.name) cannot be read. The file stays as it is."
        }
    }

    private func render(_ frame: Frame, _ film: Film?, _ key: PictureKey, _ stage: Picture.Stage,
                        show: (Picture) -> Void) async throws {
        try Task.checkCancellation()
        if let held = cache[key], held.stage >= stage {
            show(held)
            return
        }
        var dark: DarkroomFilm?
        if let film {
            dark = await loaded(film)
            try Task.checkCancellation()
            if dark == nil { throw DarkroomError.unreadable(film.path.lastPathComponent) }
        }
        let image = try await darkroom.render(frame.file.url, film: dark, quality: stage == .fine ? .fine : .quick)
        try Task.checkCancellation()
        let picture = Picture(key: key, image: image, stage: stage)
        remember(picture)
        show(picture)
    }

    private func remember(_ picture: Picture) {
        if let old = cache[picture.key] {
            cacheCost -= old.cost
            cacheOrder.removeAll { $0 == picture.key }
        }
        cache[picture.key] = picture
        cacheOrder.append(picture.key)
        cacheCost += picture.cost
        while cacheCost > Self.cacheLimit, cacheOrder.count > 1 {
            let key = cacheOrder.removeFirst()
            cacheCost -= cache.removeValue(forKey: key)?.cost ?? 0
        }
    }

    // MARK: Printing

    func setSaveFolder(_ url: URL) {
        saveFolder = url
        checkSaveFolder()
        if saveProblem == nil {
            record.saveFolder = url
            save()
        }
        derive()
    }

    private func checkSaveFolder() { saveProblem = Destination.validate(saveFolder).reason }

    /// The folder, made if it is the first print. Nil if refused, with the reason in `saveProblem`.
    private func readyFolder() -> URL? {
        switch Destination.validate(saveFolder) {
        case .refused(let why):
            saveProblem = why
            return nil
        case .ok(let real):
            saveProblem = nil
            do {
                try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            } catch {
                saveProblem = "\(real.lastPathComponent) could not be made: \(error.localizedDescription)"
                return nil
            }
            if record.saveFolder != saveFolder {
                record.saveFolder = saveFolder
                save()
            }
            return real
        }
    }

    /// The name in the tray: the user's, or the one the film gives.
    var printName: String {
        if let nameDraft { return nameDraft }
        guard let frame = current, let film = frame.developingCan else { return "" }
        return PrintName.requested(stem: frame.file.stem, film: film.name)
    }

    private func cleanedName() -> String? {
        var name = printName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        let low = name.lowercased()
        if !low.hasSuffix(".jpg"), !low.hasSuffix(".jpeg") { name += ".JPG" }
        return name
    }

    func isUnreadable(_ frame: Frame) -> Bool { !frame.isReadable || broken.contains(frame.id) }

    /// `Frame.printHold`, with what only the engine has found out.
    func hold(_ frame: Frame) -> String? { broken.contains(frame.id) ? "This CR2 cannot be read." : frame.printHold }

    var canPrintCurrent: Bool {
        guard let frame = current, !isUnreadable(frame) else { return false }
        return frame.canPrint && saveProblem == nil && !printingIDs.contains(frame.id)
    }

    func printCurrent() {
        guard let frame = current else { return }
        guard let film = frame.developingCan, frame.canPrint, !isUnreadable(frame) else {
            printError = hold(frame)
            return
        }
        guard !printingIDs.contains(frame.id) else { return }
        guard let name = cleanedName() else {
            printError = "A print's name cannot be empty, start with a dot, or hold a slash or colon."
            return
        }
        guard let folder = readyFolder() else { return }
        let half = half
        printError = nil
        lastPrint = nil
        printingIDs.insert(frame.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.printingIDs.remove(frame.id) }
            do {
                guard let dark = await self.loaded(film) else {
                    throw DarkroomError.unreadable(film.path.lastPathComponent)
                }
                let url = try await self.darkroom.print(frame.file.url, film: dark, to: folder, name: name,
                                                        half: half, quality: 92)
                self.add(url, film: film, to: frame)
                self.nameDraft = nil
                self.lastPrint = (frame.id, url)
                // The enlarger goes to the print, unless another can was picked meanwhile.
                if self.selectedID == frame.id, self.current?.developingCan?.id == film.id {
                    self.place = .print(url.path)
                }
                self.moveOn(from: frame.id)
                if self.selectedID == frame.id { self.develop() }
                // The tray that says where it went moves with the selection.
                if let moved = self.selectedID, moved != frame.id { self.lastPrint = (moved, url) }
            } catch {
                self.printError = Self.reason(error)
            }
        }
    }

    /// A name that came free may be one this bench had seen go.
    private func add(_ url: URL, film: Film, to frame: Frame) {
        gone.remove(url.path)
        record.addPrint(DeskPrint(url: url, film: film.name), identity: frame.identity)
        save()
        rebuild(identity: frame.identity)
        develop()
    }

    var batchRunning: Bool { batch?.finished == false }

    /// The frames under the current filter, each on its own film.
    func printBatch() {
        guard !batchRunning else { return }
        guard filter != .all else {
            notice = "Choose a filter first, so the batch is the frames you can see."
            return
        }
        let plan = PrintPlan(frames: filter.apply(to: frames), destination: saveFolder)
        guard !plan.items.isEmpty else {
            notice = "Nothing here can print yet."
            return
        }
        if redevelops(plan) {
            askedBatch = plan.items.map(\.frame.id)
        } else {
            start(plan)
        }
    }

    /// The yes to `printBatch` on frames already printed.
    func confirmBatch() {
        guard !batchRunning, let plan, askedBatch == plan.items.map(\.frame.id) else { return }
        askedBatch = nil
        start(plan)
    }

    func cancelBatch() { askedBatch = nil }

    private func start(_ plan: PrintPlan) {
        guard let folder = readyFolder() else {
            notice = saveProblem
            return
        }
        let waiting = plan.waiting.filter { !isUnreadable($0) }
        batch = BatchRun(total: plan.items.count, folder: folder, place: place(folder),
                         waiting: Set(waiting.map(\.id)), holds: PrintPlan.holds(of: waiting),
                         unreadable: plan.unreadable.count + plan.waiting.count - waiting.count)
        let items = plan.items
        batchTask = Task { [weak self] in
            await self?.runBatch(items, to: folder)
            self?.batch?.finished = true
            self?.batchTask = nil
            self?.batchEnded()
        }
    }

    private enum Outcome: Sendable {
        case printed(PrintItem, URL)
        case failed(PrintItem, String)
    }

    /// At most two at once. A failure is noted and the batch goes on.
    private func runBatch(_ items: [PrintItem], to folder: URL) async {
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0, running = 0
            while true {
                while running < 2, next < items.count, batch?.stopping != true {
                    let item = items[next]
                    next += 1
                    running += 1
                    batch?.started = next
                    let dark = await loaded(item.film)
                    let darkroom = darkroom
                    group.addTask {
                        guard let dark else { return .failed(item, "The film could not be read.") }
                        do {
                            let url = try await darkroom.print(item.frame.file.url, film: dark, to: folder,
                                                               name: item.requestedName, half: false, quality: 92)
                            return .printed(item, url)
                        } catch {
                            return .failed(item, await Self.reason(error))
                        }
                    }
                }
                guard running > 0, let outcome = await group.next() else { break }
                running -= 1
                take(outcome)
            }
        }
    }

    private func take(_ outcome: Outcome) {
        switch outcome {
        case .printed(let item, let url):
            batch?.printed += 1
            add(url, film: item.film, to: item.frame)
        case .failed(let item, let why):
            batch?.failures.append(.init(name: item.frame.name, reason: why))
        }
    }

    /// The tray goes to what still needs the user, or the work moves on.
    private func batchEnded() {
        let waiting = batch?.waiting ?? []
        if let first = visible.first(where: { waiting.contains($0.id) && filter.includes($0) }) {
            select(first.id)
        } else if let id = selectedID {
            moveOn(from: id)
        }
    }

    /// Finishes what is on the enlarger now, and starts nothing new.
    func stopBatch() { batch?.stopping = true }

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func showFolder(_ url: URL) { NSWorkspace.shared.open(url) }

    private static func reason(_ error: Error) -> String {
        switch error {
        case DarkroomError.unreadable: return "The CR2 cannot be read. If it was on a card, the card may have gone."
        case DarkroomError.renderFailed: return "The engine could not develop this frame."
        case DarkroomError.printFailed(let why): return "The print could not be written: \(why)."
        case DarkroomError.refusedDestination: return "Prints never go on a card."
        case DarkroomError.badName(let name): return "\(name) cannot be used as a name."
        default: return error.localizedDescription
        }
    }

    // MARK: What the views say

    /// `~` for the home folder.
    func place(_ url: URL) -> String {
        let path = url.path, home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Printed frames already have their prints, so this makes more files.
    func redevelops(_ plan: PrintPlan) -> Bool { plan.items.contains { $0.frame.state == .printed } }

    private func batchVerb(_ plan: PrintPlan) -> String { redevelops(plan) ? "Redevelop" : "Print" }

    func batchTitle(_ plan: PrintPlan) -> String {
        let n = plan.items.count
        return "\(batchVerb(plan)) \(n == 1 ? "this 1 on its film" : "these \(n) on their films")"
    }

    func planLine(_ plan: PrintPlan) -> String {
        if plan.waiting.isEmpty && plan.unreadable.isEmpty { return "to \(place(plan.destination))" }
        return batchVerb(plan) + plan.summary.dropFirst("Print".count)
    }

    /// Asked before a redevelop writes. The print step keeps every name free.
    func askLine(_ plan: PrintPlan) -> String {
        let n = plan.items.count
        return "\(n) new \(n == 1 ? "file" : "files") in \(place(plan.destination)). The prints already there stay."
    }

    /// Stands until the bench moves on to another card or folder.
    var cardNote: String? {
        cardGone.map { "\($0) was removed. Frames already decoded still show; the rest wait for the card." }
    }

    var cardPresent: Bool {
        if case .card = source { return cardGone == nil }
        return false
    }

    /// The header's chip. Only what is known: no roll, no ROLL part.
    var chipText: String {
        switch source {
        case .none:
            return "NO CARD"
        case .folder(let url):
            return url.lastPathComponent
        case .card(let card):
            if cardGone != nil { return "NO CARD" }
            var parts = [card.name]
            if let model = frames.first(where: \.isReadable)?.file.facts?.model {
                parts.append(Self.bodyName(model))
            }
            if let rollNumber { parts.append("ROLL \(rollNumber)") }
            return parts.joined(separator: " · ")
        }
    }

    /// The body has three names, and the camera's screens call it the 700D.
    private static func bodyName(_ model: String) -> String {
        if model.contains("T5i") || model.contains("X7i") { return "700D" }
        return model.replacingOccurrences(of: "Canon EOS ", with: "")
    }

    /// One CR2 was opened on its own, not the folder it sits in.
    private var isLoneFile: Bool { openedSource?.onlyFile != nil }

    var openLabel: String { isLoneFile ? "Open a folder..." : "Open another folder..." }

    private var filmsCount: String { "\(films.count) \(films.count == 1 ? "film" : "films")" }

    var emptyTitle: String {
        if case .folder = source, isLoneFile {
            if scan != nil { return "Reading the frame." }
            return frames.isEmpty ? "No CR2s here." : "Frame open. \(filmsCount)."
        }
        let isCard: Bool
        switch source {
        case .none:
            if looking { return "Looking for a card." }
            if let refusedVolume { return "macOS has not let Soup Darkroom read \(refusedVolume)." }
            return "No card yet. Put one in, or open a folder."
        case .card: isCard = true
        case .folder: isCard = false
        }
        if let scan {
            let what = isCard ? "Reading the card." : "Reading the folder."
            return scan.total == 0 ? what : "\(what) \(scan.read) of \(scan.total)."
        }
        if frames.isEmpty { return isCard ? "Card found. No frames on it." : "No CR2s here." }
        let count = "\(frames.count) \(frames.count == 1 ? "frame" : "frames"), \(filmsCount)."
        return (isCard ? "Card found. " : "Folder open. ") + count
    }

    var emptySubtitle: String? {
        if case .none = source, !looking, refusedVolume != nil {
            return "Allow Removable Volumes in System Settings, Privacy & Security, Files and Folders."
        }
        guard let opened = openedSource, source != .none else { return nil }
        var where_: String
        if opened.folders.count == 1, let folder = opened.folders.first {
            let parent = folder.deletingLastPathComponent().lastPathComponent
            where_ = parent.uppercased() == "DCIM" ? "DCIM/\(folder.lastPathComponent)" : folder.lastPathComponent
        } else {
            where_ = "\(opened.folders.count) folders"
        }
        if opened.onlyFile != nil { where_ = opened.picked.lastPathComponent }
        if scan != nil || frames.isEmpty { return where_ }
        let linked = frames.filter { $0.shotOnFilm != nil }.count
        return "\(where_) · \(linked) linked · \(frames.count - linked) with no record"
    }

    var stripEmptyLine: String { scan != nil ? "Reading frames." : filter.emptyLine }
}
