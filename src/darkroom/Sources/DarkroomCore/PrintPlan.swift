import Foundation

public enum DestinationCheck: Sendable, Equatable {
    /// With the folder resolved through any links.
    case ok(URL)
    case refused(String)

    public var reason: String? {
        if case .refused(let r) = self { return r }
        return nil
    }
}

/// Where prints may go. G5: never onto a card, even when picked by hand.
public enum Destination {
    /// `~/Pictures/Soup Prints`.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Pictures/Soup Prints", isDirectory: true)
    }

    /// Follows every link in a path, including one that points at something not
    /// there yet, which `realpath` will not do. Nil for a loop.
    static func resolve(_ url: URL) -> URL? {
        var pending = Array(url.absoluteURL.path.split(separator: "/").map(String.init).reversed())
        var at = ""                                 // "" is the root
        var hops = 0
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        while let part = pending.popLast() {
            if part == "." { continue }
            if part == ".." {
                if let slash = at.lastIndex(of: "/") { at = String(at[..<slash]) }
                continue
            }
            let next = at + "/" + part
            let n = readlink(next, &buf, buf.count - 1)
            guard n > 0 else {
                at = next
                continue
            }
            hops += 1
            if hops > 64 { return nil }
            let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if target.hasPrefix("/") { at = "" }
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return URL(fileURLWithPath: at.isEmpty ? "/" : at, isDirectory: true)
    }

    /// Why a folder counts as on a card, or nil. Links are resolved first. Any
    /// folder named DCIM counts: a card can be freshly formatted, and refusing
    /// is the safe side. The home folder and those above it are not cards, so a
    /// backup at `~/DCIM` does not refuse the whole of the user's home.
    public static func cardReason(for url: URL,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let real = resolve(url) else { return "This folder's path goes round in a loop." }
        if real.pathComponents.contains(where: { $0.uppercased() == "DCIM" }) {
            return "\(real.lastPathComponent) is inside a camera's DCIM folder. Prints never go on a card."
        }
        let homePath = (resolve(home) ?? home).path
        for dir in Paths.upward(from: real) where Paths.isDirectory(dir) {
            let path = (resolve(dir) ?? dir).path           // standardizing drops /private
            if path == homePath || homePath.hasPrefix(path == "/" ? "/" : path + "/") { continue }
            if let dcim = Paths.child(of: dir, named: "DCIM"), Paths.isDirectory(dcim) {
                return "\(real.lastPathComponent) is on a camera card, in \(dir.lastPathComponent). Prints never go on a card."
            }
        }
        return nil
    }

    /// Refuses a card, and a folder that cannot be written. Writes nothing: a
    /// test file would be a write to whatever this is. A folder not there yet
    /// is judged by the nearest parent that is, as it is made on first print.
    public static func validate(_ url: URL,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DestinationCheck {
        if let why = cardReason(for: url, home: home) { return .refused(why) }
        guard let real = resolve(url) else { return .refused("This folder's path goes round in a loop.") }
        guard let nearest = Paths.upward(from: real).first(where: Paths.exists) else {
            return .refused("\(real.lastPathComponent) cannot be reached.")
        }
        guard Paths.isDirectory(nearest) else { return .refused("\(nearest.lastPathComponent) is a file, not a folder.") }
        guard access(nearest.path, W_OK | X_OK) == 0 else {
            return .refused("\(nearest.lastPathComponent) cannot be written to.")
        }
        return .ok(real)
    }
}

/// One print to make.
public struct PrintItem: Sendable, Equatable {
    public let frame: Frame
    public let film: Film
    /// Unique within the batch. The print step still has the final word against
    /// the disk, with an exclusive rename.
    public let requestedName: String
}

/// What a batch would do. It decides nothing about the disk and prints nothing.
public struct PrintPlan: Sendable, Equatable {
    public let destination: URL
    public let items: [PrintItem]
    /// No film, or a film not on the shelf. Never guessed.
    public let waiting: [Frame]
    /// The engine cannot read these.
    public let unreadable: [Frame]
    /// How to say the destination: `~` for the home folder.
    private let place: String

    public init(frames: [Frame], destination: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.destination = destination
        var seen = Set<String>()
        var used = Set<String>()
        var next: [String: Int] = [:]
        var items: [PrintItem] = []
        var waiting: [Frame] = []
        var unreadable: [Frame] = []
        for frame in frames where seen.insert(frame.id).inserted {
            guard frame.isReadable else {
                unreadable.append(frame)
                continue
            }
            guard let film = frame.developingCan else {
                waiting.append(frame)
                continue
            }
            let base = PrintName.base(stem: frame.file.stem, film: film.name)
            var name = base + ".JPG"
            while !used.insert(name.lowercased()).inserted {        // APFS and FAT ignore case
                let n = next[base.lowercased(), default: 2]
                next[base.lowercased()] = n + 1
                name = "\(base)-\(n).JPG"
            }
            items.append(PrintItem(frame: frame, film: film, requestedName: name))
        }
        self.items = items
        self.waiting = waiting
        self.unreadable = unreadable

        let path = destination.path, h = home.path
        if path == h {
            place = "~"
        } else if path.hasPrefix(h.hasSuffix("/") ? h : h + "/") {
            place = "~/" + path.dropFirst(h.hasSuffix("/") ? h.count : h.count + 1)
        } else {
            place = path
        }
    }

    public var total: Int { items.count + waiting.count + unreadable.count }

    /// "Print 16 of 28 to ~/Pictures/Soup Prints, 12 wait for a film".
    public var summary: String {
        var s = "Print \(items.count) of \(total) to \(place)"
        if !waiting.isEmpty { s += ", \(waiting.count) \(waiting.count == 1 ? "waits" : "wait") for a film" }
        if !unreadable.isEmpty { s += ", \(unreadable.count) cannot be read" }
        return s
    }
}

public enum PrintName {
    /// `IMG_3990_VELVIA`: the film upper-case with spaces as `_`, safe characters only.
    public static func base(stem: String, film: String) -> String {
        let f = safe(film.uppercased().replacingOccurrences(of: " ", with: "_"), or: "FILM")
        return safe(stem, or: "FRAME") + "_" + f
    }

    private static func safe(_ s: String, or fallback: String) -> String {
        let plain = s.folding(options: .diacriticInsensitive, locale: nil)
        let kept = plain.unicodeScalars.filter {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-"
        }
        return kept.isEmpty ? fallback : String(String.UnicodeScalarView(kept))
    }

    /// The full requested file name for one frame on one film.
    public static func requested(stem: String, film: String) -> String { base(stem: stem, film: film) + ".JPG" }
}
