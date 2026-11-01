import Foundation

/// A camera clock reading as plain fields. Both clocks in a match are the same
/// camera's, so there is no timezone to convert, and arithmetic is done on a
/// fixed UTC calendar so that a daylight-saving change cannot move anything.
public struct NaiveTime: Sendable, Hashable, Comparable {
    public let seconds: Int

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var c = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        c.calendar = Self.calendar
        c.timeZone = Self.calendar.timeZone
        guard year > 0, c.isValidDate, let date = c.date else { return nil }
        seconds = Int(date.timeIntervalSince1970)
    }

    /// `YYYY:MM:DD HH:MM:SS`.
    public init?(exif: String) {
        let u = Array(exif.utf8)
        guard u.count == 19, u[4] == 58, u[7] == 58, u[10] == 32, u[13] == 58, u[16] == 58 else { return nil }
        func field(_ at: Int, _ len: Int) -> Int? {
            let d = u[at..<(at + len)]
            guard d.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int(String(decoding: d, as: UTF8.self))
        }
        guard let y = field(0, 4), let mo = field(5, 2), let d = field(8, 2),
              let h = field(11, 2), let mi = field(14, 2), let s = field(17, 2) else { return nil }
        self.init(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    public static func < (a: NaiveTime, b: NaiveTime) -> Bool { a.seconds < b.seconds }
}

/// One `R1` line of `SOUPROLL.TXT`.
public struct RollLine: Sendable, Equatable {
    public let roll: Int
    public let fromFolder: Int
    public let fromNo: Int
    public let toFolder: Int
    public let toNo: Int
    public let count: Int
    public let clock: NaiveTime
    public let span: Int
    public let filmId: UInt32
    public let film: String

    /// `R1 <roll> <fromFolder> <fromNo> <toFolder> <toNo> <count> <Y> <M> <D>
    /// <h> <m> <s> <span> <filmId> <film name>`. Nil if the line is malformed.
    public init?(_ line: String) {
        let f = line.split(separator: " ", maxSplits: 15)
        guard f.count == 16, f[0] == "R1" else { return nil }
        var n: [Int] = []
        for s in f[1..<14] {
            guard s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let v = Int(s) else { return nil }
            n.append(v)
        }
        guard n[1] <= 999, n[3] <= 999, n[2] <= 9999, n[4] <= 9999,
              let clock = NaiveTime(year: n[6], month: n[7], day: n[8], hour: n[9], minute: n[10], second: n[11])
        else { return nil }
        // The id is checked against the name because a line torn by a power cut
        // can still look whole: the camera puts a newline after the tear, so
        // `CLASSIC CHROME` can arrive as `CLASSIC`, or the next line can land
        // on the end of the name. The wrong film is worse than no film.
        guard (1...8).contains(f[14].utf8.count), let value = UInt32(f[14], radix: 16),
              value == Self.nameId(f[15]) else { return nil }
        let name = f[15].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        roll = n[0]
        fromFolder = n[1]
        fromNo = n[2]
        toFolder = n[3]
        toNo = n[4]
        count = n[5]
        self.clock = clock
        span = n[12]
        filmId = value
        film = name
    }

    /// `se_name_id`: FNV-1a of the name's bytes.
    static func nameId(_ name: Substring) -> UInt32 {
        name.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    /// N in the range, going through the wrap from 9999 to 1.
    public func covers(number n: Int) -> Bool {
        if fromNo <= toNo { return n >= fromNo && n <= toNo }
        return n >= 1 && (n >= fromNo || n <= toNo)
    }

    public func covers(folder: Int) -> Bool { folder == fromFolder || folder == toFolder }

    /// T in `[clock - span - 2E - 5 s, clock + 5 s]`.
    public func covers(time: NaiveTime, exposure: Double) -> Bool {
        let t = Double(time.seconds), c = Double(clock.seconds)
        return t >= c - Double(span) - 2 * max(0, exposure) - 5 && t <= c + 5
    }
}

/// What the roll says about a frame.
public enum RollMatch: Sendable, Equatable {
    case matched(film: String, lines: [RollLine])
    /// Lines match with different films. Treated as no record: a guess is worse than a gap.
    case conflict(films: [String], reason: String)
    case none(reason: String)

    public var film: String? {
        if case .matched(let f, _) = self { return f }
        return nil
    }

    public var reason: String? {
        switch self {
        case .matched: return nil
        case .conflict(_, let r), .none(let r): return r
        }
    }

    static let noRollFile = RollMatch.none(reason: "There is no roll file for this frame.")
}

/// `SOUPROLL.TXT`, parsed and indexed. Read only.
public struct RollFile: Sendable, Equatable {
    public let lines: [RollLine]
    public let skippedUnknownTag: Int
    public let skippedMalformed: Int
    public let skippedCutOff: Int

    public var skipped: Int { skippedUnknownTag + skippedMalformed + skippedCutOff }

    /// Lines of one folder, by clock, so a frame looks at a few and not all.
    private struct Bucket: Sendable, Equatable {
        var lines: [RollLine]
        var longestSpan: Int
    }
    private let byFolder: [Int: Bucket]

    /// The roll number of the last line written with the roll on, or nil.
    public var latestRoll: Int? { lines.last { $0.roll != 0 }?.roll }

    public static func read(_ url: URL) -> RollFile? {
        (try? Data(contentsOf: url)).map(RollFile.init(data:))
    }

    public init(data: Data) {
        var parsed: [RollLine] = []
        var unknown = 0, malformed = 0, cut = 0
        var rest = data[...]
        while !rest.isEmpty {
            guard let nl = rest.firstIndex(of: 10) else {
                cut += 1                            /* no newline: the write was cut off */
                break
            }
            var bytes = rest[rest.startIndex..<nl]
            rest = rest[(nl + 1)...]
            if bytes.last == 13 { bytes = bytes.dropLast() }
            if bytes.isEmpty { continue }
            let tag = bytes.prefix { $0 != 32 }
            if !tag.elementsEqual("R1".utf8) {
                // Anything that is not a clean tag is damage, not a newer format.
                let clean = tag.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) } && !tag.isEmpty
                if clean { unknown += 1 } else { malformed += 1 }
                continue
            }
            if let text = String(bytes: bytes, encoding: .utf8), let line = RollLine(text) {
                parsed.append(line)
            } else {
                malformed += 1
            }
        }
        lines = parsed
        skippedUnknownTag = unknown
        skippedMalformed = malformed
        skippedCutOff = cut

        var index: [Int: Bucket] = [:]
        for line in parsed {
            let folders = line.fromFolder == line.toFolder ? [line.fromFolder] : [line.fromFolder, line.toFolder]
            for f in folders {
                index[f, default: Bucket(lines: [], longestSpan: 0)].lines.append(line)
                index[f]!.longestSpan = max(index[f]!.longestSpan, line.span)
            }
        }
        for key in index.keys { index[key]!.lines.sort { $0.clock < $1.clock } }
        byFolder = index
    }

    /// The matching rule. `folderName` is the DCF folder's name: a folder
    /// without a number never matches, even when it is plainly the only folder
    /// in play, because a guess is worse than a gap.
    public func match(folderName: String, number: Int?, time: NaiveTime?, exposure: Double) -> RollMatch {
        guard let folder = CardName.folderNumber(folderName) else {
            return .none(reason: "The roll file is here, but \(folderName) is not a camera folder, so it cannot be told which frames are which.")
        }
        guard let number else { return .none(reason: "This file has no frame number to look up in the roll.") }
        guard let time else { return .none(reason: "This frame has no time, so the roll cannot be trusted for it.") }
        guard let bucket = byFolder[folder] else {
            return .none(reason: "The roll has no line for folder \(folder).")
        }

        // Only lines whose clock can reach T: at or after T - 5, and no later
        // than T + the longest span + 2E + 5.
        let earliest = time.seconds - 5
        let latest = Double(time.seconds) + Double(bucket.longestSpan) + 2 * max(0, exposure) + 5
        var lo = 0, hi = bucket.lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bucket.lines[mid].clock.seconds < earliest { lo = mid + 1 } else { hi = mid }
        }
        var hits: [RollLine] = []
        while lo < bucket.lines.count, Double(bucket.lines[lo].clock.seconds) <= latest {
            let line = bucket.lines[lo]
            if line.covers(number: number), line.covers(folder: folder), line.covers(time: time, exposure: exposure) {
                hits.append(line)
            }
            lo += 1
        }

        guard let first = hits.first else {
            return .none(reason: "No line in the roll covers this frame at the time it was shot.")
        }
        var films: [String: String] = [:]
        for hit in hits { films[Film.key(hit.film)] = hit.film }
        if films.count > 1 {
            let names = films.values.sorted()
            let list = names.map(Film.display).joined(separator: " and ")
            return .conflict(films: names, reason: "The roll lists this frame on both \(list), so neither is trusted.")
        }
        return .matched(film: first.film, lines: hits)
    }

    public func match(_ file: FrameFile) -> RollMatch {
        match(folderName: file.folderName, number: file.number, time: file.time, exposure: file.facts?.exposure ?? 0)
    }
}
