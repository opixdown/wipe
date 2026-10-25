// wipe — lock the keyboard (and optionally blank the screen) while you clean your Mac.
//
// Works with a CGEventTap at the HID level, so it sees keys before macOS acts on them:
// letters, modifiers, the function row, brightness, volume and media keys are all
// swallowed. The power / Touch ID button is handled in hardware and can't be blocked.
//
// The tap lives on its own thread so drawing the UI can never hold up the keyboard, and a
// watchdog unlocks everything if the UI thread ever stops responding.

import AppKit
import ApplicationServices
import Foundation
import QuartzCore

let version = "0.5.0"

// MARK: - style

let E = "\u{1B}["
let reset = "\(E)0m", bold = "\(E)1m"
func fg(_ n: Int) -> String { "\(E)38;5;\(n)m" }
// Terracotta accent and mid greys read on both light and dark terminal themes.
let accentN = 173
let accent = fg(accentN), muted = fg(245), faint = fg(240)

let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

func write(_ s: String) { print(s, terminator: ""); fflush(stdout) }

func duration(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

// MARK: - key names (for wipe configure)

let keyLabels: [Int: String] = [
    0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
    45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    53: "esc", 48: "tab", 49: "space", 36: "return", 51: "delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
]

// Device-specific modifier bits, so left and right are tracked separately.
let modifierMask: [Int: UInt64] = [
    56: 0x02, 60: 0x04,           // shift L / R
    59: 0x01, 62: 0x2000,         // control L / R
    58: 0x20, 61: 0x40,           // option L / R
    55: 0x08, 54: 0x10,           // command L / R
    63: 0x800000,                 // fn / globe
]

// MARK: - exit shortcut (wipe configure)

struct Combo: Codable, Equatable {
    var ctrl: Bool, shift: Bool, alt: Bool, cmd: Bool
    var key: Int
    var label: String

    var text: String {
        var p: [String] = []
        if ctrl { p.append("ctrl") }
        if alt { p.append("⌥") }
        if shift { p.append("⇧") }
        if cmd { p.append("⌘") }
        return (p + [label]).joined(separator: " ")
    }

    func modifiersMatch(_ f: CGEventFlags) -> Bool {
        f.contains(.maskControl) == ctrl && f.contains(.maskShift) == shift
            && f.contains(.maskAlternate) == alt && f.contains(.maskCommand) == cmd
    }
}

let defaultCombo = Combo(ctrl: true, shift: true, alt: false, cmd: false, key: 7, label: "X")
let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wipe/config.json")

func loadCombo() -> Combo {
    guard let data = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Combo.self, from: data) else { return defaultCombo }
    return c
}

func saveCombo(_ c: Combo) {
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    try? enc.encode(c).write(to: configURL)
}

var combo = loadCombo()

// MARK: - options

enum Mode {
    case keyboard, black, white
    var title: String { switch self { case .keyboard: "keyboard"; case .black: "black screen"; case .white: "white screen" } }
}

var startMode: Mode?
var configureOnly = false
var preview = false   // show the keyboard screen and a pretend exit hold; nothing is locked
var timeout: TimeInterval = 120
let holdSeconds: TimeInterval = 1.0

func usage() -> Never {
    print("""

       \(accent)●\(reset) \(bold)wipe\(reset)  \(muted)clean your Mac without shutting it down · v\(version)\(reset)

       \(bold)wipe\(reset)                  \(muted)pick a mode from a menu\(reset)
       \(bold)wipe screen black\(reset)     \(muted)black screen, keyboard locked\(reset)
       \(bold)wipe screen white\(reset)     \(muted)white screen, keyboard locked\(reset)
       \(bold)wipe keyboard\(reset)         \(muted)lock every key while you clean\(reset)
       \(bold)wipe configure\(reset)        \(muted)change the exit shortcut\(reset)
       \(bold)wipe preview\(reset)          \(muted)see the keyboard screen, nothing locked\(reset)

       \(faint)-t, --timeout <sec>   unlock by itself after this long (default 120)\(reset)

       \(muted)exit any mode: hold\(reset) \(combo.text) \(muted)for a second\(reset)

    """)
    exit(0)
}

func fail(_ msg: String) -> Never {
    fputs("wipe: \(msg)\n", stderr)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "keyboard", "keys", "kb": startMode = .keyboard
    case "screen":
        startMode = .black
        if let next = args.first, next == "black" || next == "white" {
            startMode = next == "white" ? .white : .black
            args.removeFirst()
        }
    case "black": startMode = .black
    case "white": startMode = .white
    case "configure", "--configure", "config": configureOnly = true
    case "preview": preview = true
    case "-t", "--timeout":
        guard let s = args.first, let v = Double(s), v >= 10 else { fail("--timeout needs a number of seconds (at least 10)") }
        args.removeFirst()
        timeout = min(v, 1800)
    case "-h", "--help", "help": usage()
    case "-v", "--version": print(version); exit(0)
    default: fail("unknown command '\(a)'. Try 'wipe help'.")
    }
}

// MARK: - terminal

var savedTermios = termios()
var rawActive = false

func rawOn() {
    guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
    var t = savedTermios
    t.c_lflag &= ~tcflag_t(ECHO | ICANON)
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    rawActive = true
}

func restoreTerminal() {
    if rawActive { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios); rawActive = false }
    write("\(E)?25h")
}

/// Waits up to `ms` for a key press; returns the raw bytes (arrows arrive as escape sequences).
/// If the terminal goes away (window closed, parent gone), wipe quits instead of waiting forever.
func readKey(_ ms: Int32) -> [UInt8]? {
    if getppid() == 1 { quit() }
    var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, ms) > 0 else { return nil }
    if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && p.revents & Int16(POLLIN) == 0 { quit() }
    var buf = [UInt8](repeating: 0, count: 8)
    let n = read(STDIN_FILENO, &buf, 8)
    if n <= 0 { quit() }
    return Array(buf[0..<n])
}

func eraseLines(_ n: Int) {
    if n > 0 { write("\r\(E)\(n)A\(E)J") } else { write("\r\(E)J") }
}

let terminalApp: String = {
    switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "" {
    case "Apple_Terminal": return "Terminal"
    case "iTerm.app": return "iTerm"
    case "WarpTerminal": return "Warp"
    case "vscode": return "Visual Studio Code"
    case "ghostty": return "Ghostty"
    default: return "your terminal app"
    }
}()

// The app that owns this terminal; focus goes back to it after a screen mode.
let terminalOwner = NSWorkspace.shared.frontmostApplication

func quit(_ code: Int32 = 0) -> Never {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    restoreTerminal()
    exit(code)
}

for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        restoreTerminal()
        print("")
        exit(0)
    }
}

// MARK: - shared state (written by the tap thread, read by the UI thread)

let lock = NSLock()
@discardableResult func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

var tap: CFMachPort?
var tapRunLoop: CFRunLoop?
var tapOn = false
var heartbeat = Date()             // the UI thread bumps this every frame
var watchdogTripped = false

var down = Set<Int>()              // keys held right now; the session ends once they're let go
var comboSince: Date?
var releasingSince: Date?          // exit reached; still swallowing until the keys are let go
var captureMode = false            // wipe configure: grab the next shortcut instead
var captured: (code: Int, flags: CGEventFlags)?

var startedAt = Date()

func resetSession() {
    locked {
        down = []; comboSince = nil; releasingSince = nil
        watchdogTripped = false; heartbeat = Date()
    }
    startedAt = Date()
}

// MARK: - event tap

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap, locked({ tapOn && !watchdogTripped }) { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    // NX_SYSDEFINED (14): brightness, volume, media keys. Subtype 8 is the key ones;
    // anything else (mouse aux buttons) passes through untouched.
    if type.rawValue == 14 {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
    }

    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    lock.lock()
    defer { lock.unlock() }

    if captureMode {
        if type == .keyDown, captured == nil, modifierMask[code] == nil { captured = (code, flags) }
        return nil
    }

    switch type {
    case .keyDown:
        down.insert(code)
        if code == combo.key && combo.modifiersMatch(flags) && comboSince == nil { comboSince = Date() }
    case .keyUp:
        down.remove(code)
        if code == combo.key { comboSince = nil }
    case .flagsChanged:
        if let mask = modifierMask[code] {
            if flags.rawValue & mask != 0 { down.insert(code) } else { down.remove(code) }
        }
        if !combo.modifiersMatch(flags) { comboSince = nil }
    default:
        break   // media keys: swallowed, nothing to track
    }
    return nil   // swallow
}

func setTap(_ on: Bool) {
    guard let tap else { return }
    locked { tapOn = on; heartbeat = Date() }
    CGEvent.tapEnable(tap: tap, enable: on)
}

/// Runs the tap on its own thread, plus a watchdog that lets go of the keyboard if the
/// UI thread stops bumping the heartbeat for more than 2.5 seconds.
func startTapThread(_ tap: CFMachPort) {
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread {
        let rl = CFRunLoopGetCurrent()!
        tapRunLoop = rl
        CFRunLoopAddSource(rl, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        let watchdog = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0) { _ in
            let stalled = locked { tapOn && Date().timeIntervalSince(heartbeat) > 2.5 }
            if stalled {
                locked { watchdogTripped = true; tapOn = false }
                CGEvent.tapEnable(tap: tap, enable: false)
            }
        }
        CFRunLoopAddTimer(rl, watchdog, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
    thread.name = "wipe.tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
}

// MARK: - permission

func spinWhile(_ label: String, limit: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(limit)
    var i = 0
    while !done() {
        if Date() > end { write("\r\(E)K"); return false }
        write("\r\(E)K   \(accent)\(spinner[i % spinner.count])\(reset) \(muted)\(label)\(reset)")
        i += 1
        Thread.sleep(forTimeInterval: 0.08)
    }
    write("\r\(E)K")
    return true
}

func ensureTap() {
    if tap != nil { return }

    if !AXIsProcessTrusted() {
        print("""

           \(bold)One-time setup\(reset)
           \(muted)wipe needs permission to lock the keyboard.
           System Settings is opening — turn on the switch next to \(reset)\(terminalApp)\(muted).\(reset)

        """)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        if !spinWhile("waiting for permission", limit: 180, until: { AXIsProcessTrusted() }) {
            print("   \(muted)Gave up waiting. Run wipe again when you're ready.\(reset)\n")
            quit(1)
        }
        print("   \(accent)✓\(reset) \(muted)permission granted\(reset)")
    }

    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
    tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: callback, userInfo: nil)
        ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                             eventsOfInterest: mask, callback: callback, userInfo: nil)
    guard let tap else {
        print("""

           \(accent)!\(reset) macOS still isn't letting wipe lock the keyboard.
             \(muted)Quit \(terminalApp) completely (⌘Q), open it again, and run wipe.\(reset)

        """)
        quit(1)
    }
    CGEvent.tapEnable(tap: tap, enable: false)
    startTapThread(tap)
}

// MARK: - wordmark

/// The accent dot breathes on a two-second loop.
func dot(_ t: Double) -> String {
    let ramp = [173, 173, 174, 180, 216, 180, 174, 173]
    return fg(ramp[Int(t * 4) % ramp.count]) + "●" + reset
}

/// "wipe  tagline" with a shine that sweeps across once, like the buttons on the site.
func wordmark(_ t: Double, _ tagline: String) -> String {
    let text = Array("wipe  " + tagline)
    let p = (t - 0.15) / 0.7 * Double(text.count + 8) - 4
    var s = "   " + dot(t) + " "
    for (j, ch) in text.enumerated() {
        let lit = abs(Double(j) - p) < 2
        let base = j < 4 ? bold : muted
        s += (lit ? accent + (j < 4 ? bold : "") : base) + String(ch) + reset
    }
    return s
}

// MARK: - configure

/// Asks for a new exit shortcut. Returns to the menu when saved or on back.
func configure() {
    ensureTap()
    var drawn = 0
    // show the outcome for a moment, then clear it so the menu comes back clean
    defer { Thread.sleep(forTimeInterval: 0.9); eraseLines(drawn); tcflush(STDIN_FILENO, TCIFLUSH) }
    func show(_ lines: [String]) {
        var s = drawn > 0 ? "\r\(E)\(drawn)A" : ""
        for l in lines { s += l + "\(E)K\n" }
        write(s + "\(E)J")
        drawn = lines.count
    }
    let header = ["", "   \(dot(0)) \(bold)wipe\(reset)  \(muted)exit shortcut\(reset)", "",
                  "   \(faint)now\(reset)   \(bold)\(combo.text)\(reset)"]

    while true {
        locked { captured = nil; captureMode = true }
        setTap(true)
        var i = 0
        var got: (code: Int, flags: CGEventFlags)?
        let t0 = Date()
        while got == nil {
            if Date().timeIntervalSince(t0) > 30 { break }
            show(header + ["", "   \(accent)\(spinner[i % spinner.count])\(reset) \(muted)press the new shortcut — use ctrl, ⌥ or ⌘ with a key\(reset)", "", "   \(bold)esc\(reset) \(faint)back\(reset)"])
            i += 1
            locked { heartbeat = Date() }
            Thread.sleep(forTimeInterval: 0.08)
            got = locked { captured }
        }
        setTap(false)
        locked { captureMode = false }
        Thread.sleep(forTimeInterval: 0.15)   // let the keys come up before reading the terminal again
        tcflush(STDIN_FILENO, TCIFLUSH)

        guard let got else {
            show(header + ["", "   \(muted)nothing pressed — kept\(reset) \(combo.text)", ""])
            return
        }
        let f = got.flags
        if got.code == 53 && f.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand]).isEmpty {
            show(header + ["", "   \(muted)back — kept\(reset) \(combo.text)", ""])
            return
        }
        let candidate = Combo(ctrl: f.contains(.maskControl), shift: f.contains(.maskShift), alt: f.contains(.maskAlternate),
                              cmd: f.contains(.maskCommand), key: got.code, label: keyLabels[got.code] ?? "key \(got.code)")

        if !(candidate.ctrl || candidate.alt || candidate.cmd) {
            show(header + ["", "   \(accent)!\(reset) \(bold)\(candidate.text)\(reset) \(muted)is too easy to hit while wiping — add ctrl, ⌥ or ⌘\(reset)"])
            Thread.sleep(forTimeInterval: 1.6)
            continue
        }

        show(header + ["", "   \(accent)›\(reset) \(faint)new\(reset)   \(bold)\(candidate.text)\(reset)", "",
                       "   \(bold)↵\(reset) \(faint)save\(reset)   \(bold)r\(reset) \(faint)try again\(reset)   \(bold)d\(reset) \(faint)default\(reset)   \(bold)esc\(reset) \(faint)back\(reset)"])
        while true {
            guard let b = readKey(1000) else { continue }
            if b == [0x0A] || b == [0x0D] {
                locked { combo = candidate }; saveCombo(combo)
                show(header.dropLast() + ["   \(accent)✓\(reset) \(muted)saved — hold\(reset) \(bold)\(combo.text)\(reset) \(muted)to exit any mode\(reset)", ""])
                return
            }
            if b == [0x64] {
                locked { combo = defaultCombo }; saveCombo(combo)
                show(header.dropLast() + ["   \(accent)✓\(reset) \(muted)back to the default —\(reset) \(bold)\(combo.text)\(reset)", ""])
                return
            }
            if b == [0x72] { break }
            if b == [0x1B] || b == [0x71] || b == [0x03] {
                show(header + ["", "   \(muted)back — kept\(reset) \(combo.text)", ""])
                return
            }
        }
    }
}

// MARK: - menu

enum Choice { case mode(Mode), configure }
struct Item { let title: String; let detail: () -> String; let choice: Choice }
let items: [Item] = [
    Item(title: "Black screen", detail: { "wipe screen black" }, choice: .mode(.black)),
    Item(title: "White screen", detail: { "wipe screen white" }, choice: .mode(.white)),
    Item(title: "Keyboard", detail: { "wipe keyboard" }, choice: .mode(.keyboard)),
    Item(title: "Exit shortcut", detail: { "\(combo.text)  ·  wipe configure" }, choice: .configure),
]

/// Returns the picked item index, or nil to quit.
func runMenu(_ startSel: Int) -> Int? {
    var sel = startSel
    var drawn = 0
    var last = ""
    let t0 = Date()
    write("\(E)?25l")

    func draw() {
        let t = Date().timeIntervalSince(t0)
        var lines = ["", wordmark(t, "clean without shutting down"), ""]
        for (i, it) in items.enumerated() {
            if i == 3 { lines.append("") }
            let title = it.title.padding(toLength: 16, withPad: " ", startingAt: 0)
            lines.append(i == sel
                ? "   \(accent)›\(reset) \(bold)\(title)\(reset)\(faint)\(it.detail())\(reset)"
                : "     \(muted)\(title)\(reset)\(faint)\(it.detail())\(reset)")
        }
        lines += ["", "   \(faint)↑↓ choose  ·  enter start  ·  q quit\(reset)"]

        // lines rise in one after another
        var s = ""
        for (i, line) in lines.enumerated() { s += (t >= Double(i) * 0.04 ? line : "") + "\(E)K\n" }
        guard s != last else { return }
        last = s
        write((drawn > 0 ? "\r\(E)\(drawn)A" : "") + s)
        drawn = lines.count
    }

    while true {
        draw()
        guard let b = readKey(40) else { continue }
        switch b {
        case [0x1B, 0x5B, 0x41], [0x6B]: sel = (sel + items.count - 1) % items.count       // ↑ k
        case [0x1B, 0x5B, 0x42], [0x6A]: sel = (sel + 1) % items.count                     // ↓ j
        case [0x0A], [0x0D]: eraseLines(drawn); return sel
        case [0x71], [0x1B], [0x03]: eraseLines(drawn); return nil                          // q esc ^C
        default:
            if b.count == 1, b[0] >= 0x31, b[0] < 0x31 + UInt8(items.count) {
                eraseLines(drawn); return Int(b[0] - 0x31)
            }
        }
    }
}

// MARK: - state snapshot

struct Snapshot { let down: Set<Int>, comboSince: Date?, releasingSince: Date? }

func snapshot() -> Snapshot {
    locked { Snapshot(down: down, comboSince: comboSince, releasingSince: releasingSince) }
}

// MARK: - screen windows

var windows: [NSWindow] = []
var hintLabel: NSTextField?
var ringTrack: CAShapeLayer?
var ringBar: CAShapeLayer?

func showScreens(_ m: Mode) {
    let accentColor = NSColor(red: 0.80, green: 0.47, blue: 0.36, alpha: 1)
    let (color, ink): (NSColor, NSColor) = switch m {
    case .black: (.black, NSColor(white: 0.38, alpha: 1))
    case .white: (.white, NSColor(white: 0.62, alpha: 1))
    case .keyboard: (NSColor(red: 0.075, green: 0.071, blue: 0.067, alpha: 1), NSColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1))
    }
    for screen in NSScreen.screens {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.backgroundColor = color
        // stays put over every desktop and never shows up as its own window in Mission Control
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        windows.append(w)

        guard screen == NSScreen.main, let view = w.contentView else { continue }
        let label = NSTextField(labelWithString: "hold  \(combo.text)  to exit")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = m == .keyboard ? ink.withAlphaComponent(0.45) : ink
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 56, width: screen.frame.width, height: 20)
        view.addSubview(label)
        hintLabel = label

        if m == .keyboard {
            let title = NSTextField(labelWithString: preview ? "Keyboard locked (preview)" : "Keyboard locked")
            title.font = .systemFont(ofSize: 30, weight: .semibold)
            title.textColor = ink
            title.alignment = .center
            title.frame = NSRect(x: 0, y: view.bounds.midY + 64, width: screen.frame.width, height: 40)
            view.addSubview(title)
            let sub = NSTextField(labelWithString: "wipe away — nothing you press will do anything")
            sub.font = .systemFont(ofSize: 14)
            sub.textColor = ink.withAlphaComponent(0.5)
            sub.alignment = .center
            sub.frame = NSRect(x: 0, y: view.bounds.midY + 38, width: screen.frame.width, height: 20)
            view.addSubview(sub)
        }

        // ring in the middle of the screen, shown while the exit keys are held
        view.wantsLayer = true
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY - (m == .keyboard ? 30 : 0))
        let path = CGMutablePath()
        path.addArc(center: c, radius: 34, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        let ringColor = m == .keyboard ? accentColor : ink
        for (i, layer) in [CAShapeLayer(), CAShapeLayer()].enumerated() {
            layer.path = path
            layer.fillColor = nil
            layer.lineWidth = 4
            layer.lineCap = .round
            layer.strokeColor = (i == 0 ? ink.withAlphaComponent(m == .keyboard ? 0.12 : 0.25) : ringColor).cgColor
            layer.strokeEnd = i == 0 ? 1 : 0
            layer.opacity = 0
            view.layer?.addSublayer(layer)
            if i == 0 { ringTrack = layer } else { ringBar = layer }
        }
    }
    NSApp.activate(ignoringOtherApps: true)
    // Kiosk mode: trackpad swipes can't open Mission Control or switch desktops while cleaning.
    NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
    NSCursor.hide()

    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.4
        for w in windows { w.animator().alphaValue = 1 }
    }
    // On a blank screen, fade the hint so it doesn't hide the dust you're trying to see.
    guard m != .keyboard else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard locked({ comboSince == nil && releasingSince == nil }) else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            hintLabel?.animator().alphaValue = 0
        }
    }
}

func updateScreenRing(_ s: Snapshot, _ now: Date, keepHint: Bool) {
    guard let bar = ringBar, let track = ringTrack, let h = hintLabel else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if s.releasingSince != nil {
        bar.strokeEnd = 1; bar.opacity = 1; track.opacity = 1
        h.stringValue = "unlocked — let go of the keys"; h.alphaValue = 1
    } else if let since = s.comboSince {
        bar.strokeEnd = min(now.timeIntervalSince(since) / holdSeconds, 1)
        bar.opacity = 1; track.opacity = 1
        h.stringValue = "keep holding"; h.alphaValue = 1
    } else {
        bar.opacity = 0; track.opacity = 0
        if h.stringValue != "hold  \(combo.text)  to exit" { h.stringValue = "hold  \(combo.text)  to exit"; h.alphaValue = keepHint ? 1 : 0 }
    }
    CATransaction.commit()
}

func hideScreens() {
    for i in 0...8 {
        for w in windows { w.alphaValue = 1 - CGFloat(i) / 8 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    for w in windows { w.orderOut(nil); w.close() }
    windows = []
    hintLabel = nil; ringBar = nil; ringTrack = nil
    NSApp.presentationOptions = []
    NSCursor.unhide()
    // hand focus back to the terminal so the menu keeps working
    terminalOwner?.activate(options: [])
}

// MARK: - session

struct Result { let auto: Bool; let safety: Bool; let took: TimeInterval }

func stopApp() {
    NSApp.stop(nil)
    if let ev = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(ev, atStart: true)
    }
}

func runSession(_ m: Mode, simulate: Bool = false) -> Result {
    resetSession()
    tcflush(STDIN_FILENO, TCIFLUSH)
    if !simulate { setTap(true) }
    write("\(E)?25l")
    showScreens(m)

    var result: Result?
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
        guard result == nil else { return }
        if getppid() == 1 { quit() }   // the terminal is gone; never keep the keyboard locked behind it
        let now = Date()
        let t = now.timeIntervalSince(startedAt)

        let tripped: Bool = locked {
            heartbeat = now
            // preview: hold the exit keys after a moment so you can see the ring
            if simulate, t > 1.6, comboSince == nil, releasingSince == nil { comboSince = now }
            if releasingSince == nil, let since = comboSince, now.timeIntervalSince(since) >= holdSeconds {
                releasingSince = now
            }
            return watchdogTripped
        }

        let s = snapshot()
        if tripped {
            result = Result(auto: true, safety: true, took: t)
        } else if let r = s.releasingSince, s.down.isEmpty || now.timeIntervalSince(r) > (simulate ? 0.6 : 3) {
            result = Result(auto: false, safety: false, took: t)
        } else if t >= timeout {
            result = Result(auto: true, safety: false, took: t)
        }

        updateScreenRing(s, now, keepHint: m == .keyboard)
        if result != nil { stopApp() }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApp.run()
    timer.invalidate()

    setTap(false)
    Thread.sleep(forTimeInterval: 0.05)
    tcflush(STDIN_FILENO, TCIFLUSH)   // drop anything that slipped through
    hideScreens()
    return result ?? Result(auto: false, safety: false, took: 0)
}

func summary(_ m: Mode, _ r: Result) -> String {
    var parts = [m.title, duration(r.took)]
    if r.safety { parts.append("unlocked for safety") } else if r.auto { parts.append("unlocked by itself") }
    return "   \(accent)✓\(reset) \(parts[0])\(muted)" + parts.dropFirst().map { "  ·  \($0)" }.joined() + reset
}

enum Next { case again, menu, pick(Int), quit }

func afterPrompt() -> Next {
    write("\n   \(bold)↵\(reset) \(faint)again\(reset)   \(bold)m\(reset) \(faint)menu\(reset)   \(bold)q\(reset) \(faint)quit\(reset)")
    tcflush(STDIN_FILENO, TCIFLUSH)
    while true {
        guard let b = readKey(1000) else { continue }
        var next: Next?
        switch b {
        case [0x0A], [0x0D], [0x20]: next = .again
        case [0x6D], [0x1B, 0x5B, 0x41], [0x1B, 0x5B, 0x42]: next = .menu
        case [0x71], [0x1B], [0x03]: next = .quit
        default:
            if b.count == 1, b[0] >= 0x31, b[0] < 0x31 + UInt8(items.count) { next = .pick(Int(b[0] - 0x31)) }
        }
        if let next {
            write("\r\(E)K\(E)1A\r\(E)K")
            return next
        }
    }
}

// MARK: - run

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if preview {
    rawOn()
    let r = runSession(.keyboard, simulate: true)
    print("\n" + summary(.keyboard, r) + "  \(faint)(preview)\(reset)\n")
    quit()
}

if startMode == nil && !configureOnly && isatty(STDIN_FILENO) == 0 { usage() }
rawOn()

// `wipe configure` opens the exit-shortcut screen first, then lands on the menu
var pick: Int? = configureOnly
    ? items.firstIndex { if case .configure = $0.choice { return true }; return false }
    : startMode.flatMap { m in items.firstIndex { if case .mode(let x) = $0.choice { return x == m }; return false } }
var lastSel = 0
loop: while true {
    if pick == nil {
        guard let p = runMenu(lastSel) else { break loop }
        pick = p
    }
    let idx = pick!
    lastSel = idx
    pick = nil

    switch items[idx].choice {
    case .configure:
        configure()
        continue loop
    case .mode(let m):
        ensureTap()
        let result = runSession(m)
        print("\n" + summary(m, result))
        switch afterPrompt() {
        case .again: pick = idx
        case .menu: pick = nil
        case .pick(let p): pick = p
        case .quit: break loop
        }
    }
}
quit()
