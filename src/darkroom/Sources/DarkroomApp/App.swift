import AppKit
import DarkroomCore
import DarkroomEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct SoupDarkroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bench: Bench

    init() {
        Theme.registerFonts()
        // Set by tests, to keep their record and cache away from the user's.
        let support = ProcessInfo.processInfo.environment["SOUP_SUPPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let bench = Bench(support: support ?? BenchRecord.defaultDirectory,
                          cache: support?.appendingPathComponent("Cache", isDirectory: true) ?? Darkroom.defaultCacheDirectory)
        _bench = StateObject(wrappedValue: bench)
        AppDelegate.bench = bench
    }

    var body: some Scene {
        Window("Soup Darkroom", id: "bench") {
            BenchWindow(bench: bench)
        }
        .defaultSize(width: 1164, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Soup Darkroom") { About.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    if let url = Panels.pickFolderOrFile() { bench.open(url) }
                }
                .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print") { bench.printCurrent() }.keyboardShortcut("p")
                Button("Print These") { bench.printBatch() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var bench: Bench?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Run from `swift run` there is no bundle to make this a regular app.
        NSApp.setActivationPolicy(.regular)
        if Arguments.value(after: "--drive") == nil { NSApp.activate(ignoringOtherApps: true) }
        MainActor.assumeIsolated {
            guard let bench = Self.bench else { return }
            KeyMonitor.shared.install(bench: bench)
            bench.start(path: Arguments.value(after: "--open"))
            if let script = Arguments.value(after: "--drive") { Driver.run(script: script, bench: bench) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

enum Arguments {
    static func value(after flag: String) -> String? {
        let all = CommandLine.arguments
        guard let at = all.firstIndex(of: flag), at + 1 < all.count else { return nil }
        return all[at + 1]
    }
}

struct BenchWindow: View {
    @ObservedObject var bench: Bench

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(bench: bench)
            HStack(spacing: 0) {
                ShelfView(bench: bench)
                EnlargerView(bench: bench)
                TrayView(bench: bench)
            }
            FilterBar(bench: bench)
            StripView(bench: bench)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .foregroundColor(Theme.text)
        .background(Theme.background)
        .ignoresSafeArea(.all, edges: .top)
        .background(TitleBar())
    }
}

/// The header sits in the title bar, with the traffic lights centred against it.
private struct TitleBar: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unifiedCompact
            window.isReleasedWhenClosed = false
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Space and the arrows work wherever focus is, except while typing a name.
@MainActor
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var monitor: Any?

    func install(bench: Bench) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            Self.handle(event, bench) ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { bench.holdShotOn = false }
        }
    }

    private static func handle(_ event: NSEvent, _ bench: Bench) -> Bool {
        if NSApp.modalWindow != nil { return false }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let typing = NSApp.keyWindow?.firstResponder is NSText
        switch event.keyCode {
        case 49:    // Space
            if event.type == .keyUp {
                if bench.holdShotOn { bench.holdShotOn = false; return true }
                return !typing
            }
            guard plain, !typing else { return false }
            if !event.isARepeat { bench.holdShotOn = true }
            return true
        case 123, 124, 125, 126:    // arrows
            guard plain, !typing, event.type == .keyDown else { return false }
            switch event.keyCode {
            case 123: bench.stepFrame(by: -1)
            case 124: bench.stepFrame(by: 1)
            case 125: bench.stepFilm(by: 1)
            default: bench.stepFilm(by: -1)
            }
            return true
        case 33, 30:    // [ and ]
            guard plain, !typing, event.type == .keyDown else { return false }
            bench.stepStack(by: event.keyCode == 33 ? -1 : 1)
            return true
        case 36, 76, 53:    // Return, Enter and Escape answer the Redevelop question
            guard plain, !typing, event.type == .keyDown, bench.askedBatch != nil else { return false }
            if event.keyCode == 53 { bench.cancelBatch() } else { bench.confirmBatch() }
            return true
        default:
            return false
        }
    }
}

@MainActor
enum Panels {
    static func pickFolderOrFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Open a folder of CR2s, a card, or one CR2."
        if let type = UTType(filenameExtension: "cr2") { panel.allowedContentTypes = [type, .folder] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where prints go. Prints never go on a card."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickFilm() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a .fs film."
        if let type = UTType(filenameExtension: "fs") { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Takes the keyboard back from the name field.
    static func dropFocus() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

@MainActor
enum About {
    static func show() {
        let text = """
        A raw developer for Rebel T5i / 700D cards, over the Soup Engine.

        GPL v2. Distributed without any warranty.

        UX and UI inspired by M-Film, by @hng.spl. None of their code was seen or used.
        """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Soup Darkroom", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
