// darkroomctl: the engine from a terminal. To add a command, add a row to
// `commands`.
import CSoup
import CoreGraphics
import DarkroomEngine
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Command {
    let name: String
    let usage: String
    let run: ([String]) async throws -> Void
}

let commands = [
    Command(name: "render", usage: "render <CR2> <film.fs|straight> <scale> <out.ppm|jpg>", run: render),
    Command(name: "print", usage: "print <CR2> <film.fs|straight> <outdir> [--half] [--name <file>]", run: printFrame),
    Command(name: "probe", usage: "probe <CR2> [--json]", run: probe),
    Command(name: "bench", usage: "bench <CR2> <film.fs|straight>", run: bench),
    Command(name: "scan", usage: "scan <path> [--json] [--record [dir]] [--stocks <dir>]", run: scan),
    Command(name: "cards", usage: "cards [--json]", run: cards),
]

struct UsageError: Error {}

func film(_ arg: String) throws -> DarkroomFilm? {
    if arg == "straight" { return nil }
    guard let film = DarkroomFilm(url: URL(fileURLWithPath: arg)) else {
        throw DarkroomError.unreadable(arg)
    }
    return film
}

func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

func render(_ args: [String]) async throws {
    guard args.count == 4, let scale = Int(args[2]) else { throw UsageError() }
    let out = URL(fileURLWithPath: args[3])
    let image = try await Darkroom().render(URL(fileURLWithPath: args[0]), film: film(args[1]), scale: scale)
    if out.pathExtension.lowercased() == "ppm" {
        var file = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
        file.append(bytes(image))
        try file.write(to: out)
    } else {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw DarkroomError.printFailed(out.path) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DarkroomError.printFailed(out.path) }
    }
    print("\(image.width)x\(image.height) \(out.path)")
}

func printFrame(_ args: [String]) async throws {
    guard args.count >= 3 else { throw UsageError() }
    var half = false, name: String?
    var rest = args[3...].makeIterator()
    while let flag = rest.next() {
        switch flag {
        case "--half": half = true
        case "--name": name = rest.next()
        default: throw UsageError()
        }
    }
    let url = URL(fileURLWithPath: args[0])
    let can = try film(args[1])
    let stem = url.deletingPathExtension().lastPathComponent
    let leaf = can.map { $0.name.replacingOccurrences(of: " ", with: "_") } ?? "STRAIGHT"
    let landed = try await Darkroom().print(url, film: can, to: URL(fileURLWithPath: args[2]),
                                            name: name ?? "\(stem)_\(leaf).JPG", half: half)
    print(landed.path)
}

func probe(_ args: [String]) async throws {
    guard args.count == 1 || (args.count == 2 && args[1] == "--json") else { throw UsageError() }
    var facts = sb_cr2_facts()
    guard sb_cr2_probe(args[0], &facts) == 0 else { throw DarkroomError.unreadable(args[0]) }
    let text = { (s: UnsafePointer<CChar>) in String(cString: s) }
    let make = withUnsafeBytes(of: facts.make) { text($0.bindMemory(to: CChar.self).baseAddress!) }
    let model = withUnsafeBytes(of: facts.model) { text($0.bindMemory(to: CChar.self).baseAddress!) }
    let date = withUnsafeBytes(of: facts.datetime) { text($0.bindMemory(to: CChar.self).baseAddress!) }
    if args.count == 2 {
        struct Facts: Encodable {
            let width, height, orientation, iso: Int
            let make, model, dateTime: String
            let exposure, aperture: Double
        }
        return try json(Facts(width: Int(facts.width), height: Int(facts.height),
                              orientation: Int(facts.orientation), iso: Int(facts.iso),
                              make: make, model: model, dateTime: date,
                              exposure: Double(facts.exposure_time), aperture: Double(facts.aperture)))
    }
    print("\(facts.width)x\(facts.height) orientation \(facts.orientation)")
    print("\(make) \(model), \(date)")
    let shutter = facts.exposure_time > 0 ? 1 / facts.exposure_time : 0
    print("1/\(String(format: "%.1f", shutter)) s (\(facts.exposure_time) s), f/\(facts.aperture), ISO \(facts.iso)")
}

/// Cold is the first render of a frame, which decodes it. The rest are from
/// the held negative with the image cache off, so each is a real render.
func bench(_ args: [String]) async throws {
    guard args.count == 2 else { throw UsageError() }
    let url = URL(fileURLWithPath: args[0])
    let can = try film(args[1])
    let timed = { (label: String, work: () async throws -> Void) in
        let start = Date()
        try await work()
        print(String(format: "%-14@ %6.0f ms", label as NSString, Date().timeIntervalSince(start) * 1000))
    }
    let room = Darkroom(imageCacheBytes: 0)
    try await timed("cold quick") { _ = try await room.render(url, film: can, quality: .quick) }
    for _ in 0..<3 { try await timed("quick") { _ = try await room.render(url, film: can, quality: .quick) } }
    for _ in 0..<3 { try await timed("fine") { _ = try await room.render(url, film: can, quality: .fine) } }
    try await timed("placeholder") { _ = try await room.placeholder(url) }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("soup-bench-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await timed("full print") { _ = try await room.print(url, film: can, to: dir, name: "bench.jpg") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = commands.first(where: { $0.name == args.first }) else {
    for command in commands { print("darkroomctl \(command.usage)") }
    exit(2)
}
do {
    try await command.run(Array(args.dropFirst()))
} catch is UsageError {
    print("darkroomctl \(command.usage)")
    exit(2)
} catch {
    FileHandle.standardError.write(Data("darkroomctl: \(error)\n".utf8))
    exit(1)
}
