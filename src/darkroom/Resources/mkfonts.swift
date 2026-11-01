// mkfonts.swift <index.html> <outdir>: Barlow as files, from the base64
// @font-face rules in doc/menu-sample/index.html.
//
// Those are WOFF2, which CoreText reads. This asks CoreGraphics for the decoded
// tables and writes them back out, untouched, as a plain .ttf or .otf, which
// needs nothing here but the OS. Named by PostScript name. Run with `swift`.
import CoreGraphics
import Foundation

func tagText(_ tag: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(tag >> $0 & 255) }, as: UTF8.self)
}

func checksum(_ data: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0, i = 0
    let bytes = data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
    while i < bytes.count {
        let word: UInt32 = (UInt32(bytes[i]) << 24) + (UInt32(bytes[i + 1]) << 16)
        sum &+= word + (UInt32(bytes[i + 2]) << 8) + UInt32(bytes[i + 3])
        i += 4
    }
    return sum
}

func be32(_ v: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(v >> $0 & 255) } }
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }

/// An sfnt holding the font's tables as they are, apart from head's
/// checkSumAdjustment, which belongs to the file.
func sfnt(_ font: CGFont) -> (bytes: [UInt8], isCFF: Bool) {
    let list = font.tableTags!
    var tables: [(tag: UInt32, data: [UInt8])] = []
    for i in 0..<CFArrayGetCount(list) {        // raw numbers, not objects
        let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(list, i)))
        tables.append((tag, [UInt8](font.table(for: tag)! as Data)))
    }
    tables.sort { $0.tag < $1.tag }
    let isCFF = tables.contains { tagText($0.tag) == "CFF " }
    let headAt = tables.firstIndex { tagText($0.tag) == "head" }!
    tables[headAt].data.replaceSubrange(8..<12, with: [0, 0, 0, 0])

    let n = tables.count
    let log = Int(log2(Double(n)))
    var out = be32(isCFF ? 0x4F54_544F : 0x0001_0000)
    out += be16(n)
    out += be16(16 << log)
    out += be16(log)
    out += be16(n * 16 - (16 << log))

    var offset = 12 + n * 16
    var headOffset = 0
    var body: [UInt8] = []
    for (i, t) in tables.enumerated() {
        if i == headAt { headOffset = offset }
        out += be32(t.tag)
        out += be32(checksum(t.data))
        out += be32(UInt32(offset))
        out += be32(UInt32(t.data.count))
        let padded = t.data + [UInt8](repeating: 0, count: (4 - t.data.count % 4) % 4)
        body += padded
        offset += padded.count
    }
    out += body
    out.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: be32(0xB1B0_AFBA &- checksum(out)))
    return (out, isCFF)
}

let args = CommandLine.arguments
guard args.count == 3, let html = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    print("usage: mkfonts.swift <index.html> <outdir>")
    exit(2)
}
let rule = try! NSRegularExpression(pattern: "url\\(data:font/woff2;base64,([A-Za-z0-9+/=]+)\\)")
for match in rule.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
    let b64 = String(html[Range(match.range(at: 1), in: html)!])
    guard let data = Data(base64Encoded: b64), let provider = CGDataProvider(data: data as CFData),
          let font = CGFont(provider), let name = font.postScriptName as String? else {
        print("cannot read a font in \(args[1])")
        exit(1)
    }
    let (bytes, isCFF) = sfnt(font)
    let file = Data(bytes)
    let url = URL(fileURLWithPath: args[2]).appendingPathComponent(name + (isCFF ? ".otf" : ".ttf"))
    try! file.write(to: url)
    print(url.lastPathComponent, file.count)
}
