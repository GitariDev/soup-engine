import AppKit
import DarkroomCore
import Foundation
import SwiftUI

/// Walks the real window from a script: `SoupDarkroom --drive walk.txt`. Keys
/// and the mouse go in through the event queue, the way the system delivers
/// them, so the key monitor and the views are what is under test. It does
/// nothing unless asked for, and it only ever does what a user could.
///
///     open <path>                       filter <all|shotOn|printed|yourChoice|noRecord|notDeveloped>
///     select <name>                     can <film|none>
///     key <left|right|up|down|[|]>      space <down|up>
///     mouse <x> <y>                     drag <x0> <y0> <x1> <y1>      (window points, top left)
///     image-drag <from 0..1> <to 0..1>  size <w> <h>
///     print | batch | stop              folder <path>   half <on|off>   name <text>
///     confirm | cancel                  (a redevelop's question)
///     settle                            idle
///     wait <ms>                         shot <name>
///     dump <label>                      quit
///     stack <original|back|next|film>   lose <n>   find   swap <n> <m>
///     spoil <n>                         rescan
///
/// `stack` clicks the bar under the picture. `lose` moves the frame's nth print
/// out of SOUP_SAVE, as a user would in Finder, `find` moves them all back, `swap`
/// trades two prints' files, and `spoil` leaves a file that is no picture. None
/// touches any other folder. `rescan` is what coming back to the app does.
///
/// `settle` waits for the fine render, `idle` for a batch to finish. `dump`
/// prints one JSON line. `shot` writes <SOUP_SHOTS>/<name>.png: those hold
/// photos, so point it at an ignored folder.
@MainActor
enum Driver {
    static func run(script path: String, bench: Bench) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("drive: cannot read \(path)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        if let save = ProcessInfo.processInfo.environment["SOUP_SAVE"] { bench.setSaveFolder(URL(fileURLWithPath: save)) }
        let lines = text.split(separator: "\n").map(String.init)
        Task { @MainActor in
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let word = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                await step(word[0], word.count > 1 ? word[1] : "", bench)
            }
            NSApp.terminate(nil)
        }
    }

    private static var window: NSWindow? { NSApp.windows.first { $0.contentView != nil && $0.isVisible } }

    private static func step(_ verb: String, _ rest: String, _ bench: Bench) async {
        let args = rest.split(separator: " ").map(String.init)
        let numbers = args.compactMap(Double.init)
        switch verb {
        case "open": bench.open(URL(fileURLWithPath: rest)); await scanned(bench)
        case "filter":
            if let f = Filter.allCases.first(where: { "\($0)" == rest }) { bench.setFilter(f) } else { complain(verb, rest) }
        case "select":
            if let f = bench.visible.first(where: { $0.name.hasPrefix(rest) }) { bench.select(f.id) } else { complain(verb, rest) }
        case "can":
            if rest == "none" { bench.choose(film: nil) }
            else if let f = bench.films.first(where: { Film.key($0.name) == Film.key(rest) }) { bench.choose(film: f) }
            else { complain(verb, rest) }
        case "key":
            let code: [String: UInt16] = ["left": 123, "right": 124, "down": 125, "up": 126, "[": 33, "]": 30]
            if let k = code[rest] { post(.keyDown, k); post(.keyUp, k) } else { complain(verb, rest) }
        case "space": post(rest == "up" ? .keyUp : .keyDown, 49, repeating: rest == "repeat")
        case "mouse" where numbers.count == 2: await click(CGPoint(x: numbers[0], y: numbers[1]))
        case "drag" where numbers.count == 4:
            await drag(CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]))
        case "image-drag" where numbers.count == 2:
            if let r = DriverAnchors.imageRect {
                let y = r.midY
                await drag(CGPoint(x: r.minX + r.width * numbers[0], y: y), CGPoint(x: r.minX + r.width * numbers[1], y: y))
            } else { complain(verb, "no image on screen") }
        case "size" where numbers.count == 2:
            if let w = window {
                var f = w.frame
                f.size = CGSize(width: numbers[0], height: numbers[1])
                w.setFrame(f, display: true)
            }
        case "print": bench.printCurrent()
        case "batch": bench.printBatch()
        case "stop": bench.stopBatch()
        case "confirm": bench.confirmBatch()
        case "cancel": bench.cancelBatch()
        case "folder": bench.setSaveFolder(URL(fileURLWithPath: rest))
        case "half": bench.half = rest == "on"
        case "name": bench.nameDraft = rest
        case "stack":
            if let r = DriverAnchors.marks[rest] { await click(CGPoint(x: r.midX, y: r.midY)) } else { complain(verb, rest) }
        case "lose": lose(Int(rest) ?? 0, bench)
        case "swap" where numbers.count == 2: swap(Int(numbers[0]), Int(numbers[1]), bench)
        case "spoil":
            if let url = saved(Int(rest) ?? 0, bench) { try? Data("not a picture".utf8).write(to: url) } else { complain(verb, rest) }
        case "find": find()
        case "rescan":
            bench.rescan()
            try? await Task.sleep(for: .milliseconds(400))
        case "settle":
            await poll {
                let side = bench.comparison?.wipes != true || bench.compare?.stage == .fine
                return (bench.main?.stage == .fine && !bench.showsOldFilm && side) || bench.pictureProblem != nil
            }
        case "idle": await poll(seconds: 300) { !bench.batchRunning && bench.printingIDs.isEmpty }
        case "wait": try? await Task.sleep(for: .milliseconds(numbers.first ?? 0))
        case "shot": shot(rest)
        case "dump": dump(rest, bench)
        case "quit": NSApp.terminate(nil)
        default: complain(verb, rest)
        }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private static func complain(_ verb: String, _ rest: String) {
        Swift.print("{\"driveError\":\"\(verb) \(rest)\"}")
    }

    private static func scanned(_ bench: Bench) async {
        try? await Task.sleep(for: .milliseconds(100))
        await poll(seconds: 60) { bench.scan == nil }
    }

    private static func poll(seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: the save folder, as a user would treat it

    private static var aside: URL? {
        ProcessInfo.processInfo.environment["SOUP_SAVE"].map { URL(fileURLWithPath: $0 + ".aside", isDirectory: true) }
    }

    /// The frame's nth print, only if it is directly in the throwaway save folder.
    private static func saved(_ n: Int, _ bench: Bench) -> URL? {
        let stack = bench.stack
        guard let save = ProcessInfo.processInfo.environment["SOUP_SAVE"], stack.indices.contains(n - 1),
              stack[n - 1].url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == URL(fileURLWithPath: save).resolvingSymlinksInPath().path else { return nil }
        return stack[n - 1].url
    }

    private static func lose(_ n: Int, _ bench: Bench) {
        guard let aside, let url = saved(n, bench) else {
            complain("lose", "\(n)")
            return
        }
        try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: url, to: aside.appendingPathComponent(url.lastPathComponent))
        } catch { complain("lose", "\(url.lastPathComponent)") }
    }

    private static func swap(_ n: Int, _ m: Int, _ bench: Bench) {
        guard let a = saved(n, bench), let b = saved(m, bench) else {
            complain("swap", "\(n) \(m)")
            return
        }
        let held = a.appendingPathExtension("swap")
        do {
            try FileManager.default.moveItem(at: a, to: held)
            try FileManager.default.moveItem(at: b, to: a)
            try FileManager.default.moveItem(at: held, to: b)
        } catch { complain("swap", "\(n) \(m)") }
    }

    private static func find() {
        guard let aside, let save = ProcessInfo.processInfo.environment["SOUP_SAVE"] else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: aside.path)) ?? [] {
            try? FileManager.default.moveItem(at: aside.appendingPathComponent(name),
                                              to: URL(fileURLWithPath: save).appendingPathComponent(name))
        }
    }

    // MARK: events

    private static func post(_ type: NSEvent.EventType, _ code: UInt16, repeating: Bool = false) {
        guard let w = window, let e = NSEvent.keyEvent(
            with: type == .keyUp ? .keyUp : .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: code == 49 ? " " : "", charactersIgnoringModifiers: code == 49 ? " " : "",
            isARepeat: repeating, keyCode: code) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
        guard let w = window, let height = w.contentView?.bounds.height,
              let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: height - p.y), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // A window that is not key takes a click as activation only, and with
        // the screen locked it can never become key. Then the view under the
        // pointer gets the event itself, past the window's first-click rule.
        if w.isKeyWindow {
            NSApp.postEvent(e, atStart: false)
            return
        }
        if type == .leftMouseDown { held = w.contentView?.hitTest(w.contentView?.convert(e.locationInWindow, from: nil) ?? .zero) }
        switch type {
        case .leftMouseDown: held?.mouseDown(with: e)
        case .leftMouseDragged: held?.mouseDragged(with: e)
        default: held?.mouseUp(with: e)
        }
    }

    private static var held: NSView?

    private static func click(_ p: CGPoint) async {
        mouse(.leftMouseDown, p)
        try? await Task.sleep(for: .milliseconds(30))
        mouse(.leftMouseUp, p)
    }

    private static func drag(_ a: CGPoint, _ b: CGPoint) async {
        mouse(.leftMouseDown, a)
        for i in 1...8 {
            try? await Task.sleep(for: .milliseconds(16))
            let t = CGFloat(i) / 8
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        try? await Task.sleep(for: .milliseconds(16))
        mouse(.leftMouseUp, b)
    }

    // MARK: looking

    private static func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SOUP_SHOTS"], let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            complain("shot", "set SOUP_SHOTS")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// The pixels themselves, so a walk can tell one picture from another.
    private static func sum(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffffffff }
    }

    private static func dump(_ label: String, _ bench: Bench) {
        let c = bench.counts
        var out: [String: Any] = [
            "label": label,
            "frames": bench.frames.count, "visible": bench.visible.map(\.name).prefix(64).joined(separator: " "),
            "filter": "\(bench.filter)", "chip": bench.chipText,
            "counts": "\(c)",
            "wipe": bench.wipe, "holdShotOn": bench.holdShotOn,
            "films": bench.films.count, "printName": bench.printName,
            "looking": bench.looking, "active": NSApp.isActive, "key": window?.isKeyWindow ?? false,
            "imageRect": DriverAnchors.imageRect.map { "\($0)" } ?? "",
            "printRect": DriverAnchors.printRect.map { "\($0)" } ?? "",
            "chips": DriverAnchors.chipDump,
            "printsInFolder": (try? FileManager.default.contentsOfDirectory(atPath: bench.saveFolder.path).count) ?? 0,
            "canPrint": bench.canPrintCurrent, "saveFolder": bench.saveFolder.path,
        ]
        if let p = bench.plan { out["batchTitle"] = bench.batchTitle(p); out["planLine"] = bench.planLine(p) }
        if let a = bench.askedBatch { out["askedBatch"] = a.count }
        if let f = bench.current {
            out["frame"] = f.name
            out["state"] = f.state.rawValue
            out["word"] = f.stateWord
            out["shotOn"] = f.shotOnFilm?.film ?? ""
            out["developing"] = f.developingFilm ?? ""
            out["developed"] = f.isDeveloped
            out["hold"] = bench.hold(f) ?? ""
        }
        out["filmLate"] = bench.filmLate
        out["firstFilms"] = bench.films.prefix(2).map(\.name).joined(separator: " ")
        out["showsOldFilm"] = bench.showsOldFilm
        if let p = bench.main {
            out["picture"] = "\(p.stage) \(p.key.film)"
            out["pictureSize"] = "\(p.image.width)x\(p.image.height)"
            out["pictureSum"] = sum(p.image)
        }
        out["stack"] = bench.stack.count
        out["stackFiles"] = bench.stack.map(\.name).joined(separator: " ")
        out["stackFilms"] = bench.stack.map { $0.film ?? "-" }.joined(separator: " ")
        out["stackLabel"] = bench.stackLabel
        out["onOriginal"] = bench.onOriginal
        out["place"] = bench.shownPrint?.name ?? "\(bench.place)"
        out["printWipe"] = bench.printWipe
        out["wipes"] = bench.comparison?.wipes ?? false
        out["right"] = bench.comparison?.developingLabel ?? ""
        out["left"] = bench.comparison?.label ?? ""
        out["compare"] = bench.compare.map { "\($0.stage) \($0.key.film)" } ?? ""
        out["inHand"] = bench.showsFilmInHand
        out["spaceShows"] = bench.spacePicture?.key.film ?? ""
        if let p = bench.pictureProblem { out["pictureProblem"] = p }
        if let p = bench.printError { out["printError"] = p }
        if let p = bench.saveProblem { out["saveProblem"] = p }
        if let p = bench.notice { out["notice"] = p }
        if let p = bench.lastPrint { out["lastPrint"] = p.url.path }
        if let b = bench.batch {
            out["batch"] = "started \(b.started) printed \(b.printed) failed \(b.failures.count) notRun \(b.notRun) finished \(b.finished)"
            out["skipped"] = b.holds.map { "\($0.count) \($0.reason)" }.joined(separator: "; ")
            out["unreadableSkipped"] = b.unreadable
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { Swift.print(s) }
        fflush(stdout)
    }
}

/// Where things are on screen, for a drag. The enlarger keeps this current.
@MainActor
enum DriverAnchors {
    static var imageRect: CGRect?
    static var printRect: CGRect?
    static var marks: [String: CGRect] = [:]

    /// Keeps `marks[name]` on where this view is.
    struct Mark: View {
        let name: String

        var body: some View {
            GeometryReader { geo in
                Color.clear
                    .onAppear { marks[name] = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, rect in marks[name] = rect }
            }
        }
    }

    /// The chips on the picture, by side: where each is, and the width its
    /// whole label would take, so a dump shows one that is cut short.
    static var chips: [String: (text: String, rect: CGRect)] = [:]

    static var chipDump: [String: Any] {
        chips.mapValues { chip in
            let r = chip.rect
            return ["text": chip.text, "x": r.minX, "y": r.minY, "w": r.width, "h": r.height,
                    "whole": NSHostingView(rootView: Chip(text: chip.text)).fittingSize.width]
        }
    }
}

extension View {
    /// Keeps `DriverAnchors.chips` current for one chip on the picture.
    func chipAnchor(_ side: String, _ text: String) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { DriverAnchors.chips[side] = (text, geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, rect in DriverAnchors.chips[side] = (text, rect) }
                .onChange(of: text) { _, new in DriverAnchors.chips[side] = (new, geo.frame(in: .global)) }
                .onDisappear { DriverAnchors.chips[side] = nil }
        })
    }
}
