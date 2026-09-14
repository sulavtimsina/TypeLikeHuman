import AppKit
import Carbon.HIToolbox

/// `typehuman` — the same TypingEngine the menu bar app uses, driven from a
/// terminal so other tools can ask for text to be typed.
///
///     typehuman --delay 3 --wpm 45 < answer.txt
///     typehuman --text "hello there"
///
/// Text comes from `--text` or, with no such flag, from standard input. The
/// process stays alive until the typing finishes; SIGTERM/SIGINT abort it
/// mid-word, exactly like pressing Escape in the app.
///
/// Exit codes: 0 typed it all · 2 aborted · 3 secure input is on ·
/// 4 no Accessibility permission · 64 bad usage.
@main
struct TypeCLI {

    static let usage = """
    usage: typehuman [--text <string>] [--delay <seconds>] [--wpm <n>]
                     [--typos <0-0.3>] [--jitter <n>] [--hesitation <0-1>]

      --text        what to type; if omitted, it is read from stdin
      --delay       silent grace period before the first keystroke (default 3)
      --wpm         words per minute, a word being five characters (default 40)
      --typos       share of characters that get a neighbouring key first,
                    backspaced and corrected (default 0.2)
      --jitter      spread of the keystroke delay; higher is more erratic
      --hesitation  chance per character of a thinking pause
      --auto-close  whether the editor inserts the closing bracket, brace or
                    quote itself (default "on"). With it on, no closer is ever
                    typed: the cursor steps over the editor's own with Right, or
                    Down and End when a Return has moved it to its own line
      --speed-file  a file holding the words per minute to type at, re-read as
                    it types: write a new number into it and the run already in
                    progress changes pace. --wpm is the speed until it is read
      --dry-run     print the keystrokes it would send and exit, typing nothing
      --indent      how to handle indentation (default "editor"):
                      editor  type it the way a person does in an editor that
                              indents by itself: no leading spaces, and Tab or
                              Shift+Tab only where the level has to change
                      literal type every space and tab exactly as given, for
                              plain text fields that do nothing on Return

    Whatever has keyboard focus when the delay runs out receives the text, so
    click into the target field first. SIGTERM (or Ctrl-C) stops the typing.
    """

    static func main() {
        var profile = TypingEngine.Profile()
        var delay = 3.0
        var text: String?
        var indentMode = "editor"
        var dryRun = false
        var autoClose = true
        var dismiss = "space"
        var speedPath: String?

        // ---- arguments ----
        var args = Array(CommandLine.arguments.dropFirst())
        while let flag = args.first {
            args.removeFirst()
            if flag == "-h" || flag == "--help" {
                print(usage)
                exit(0)
            }
            if flag == "--dry-run" { dryRun = true; continue }
            guard let raw = args.first else { fail("\(flag) needs a value") }
            args.removeFirst()

            switch flag {
            case "--text":        text = raw
            case "--delay":       delay = number(raw, flag, min: 0, max: 600)
            case "--wpm":         profile.wpm = number(raw, flag, min: 5, max: 200)
            case "--typos":       profile.typoRate = number(raw, flag, min: 0, max: 0.3)
            case "--jitter":      profile.jitter = number(raw, flag, min: 0, max: 2)
            case "--hesitation":  profile.hesitationRate = number(raw, flag, min: 0, max: 1)
            case "--indent":
                guard ["editor", "literal"].contains(raw) else { fail("--indent wants editor or literal") }
                indentMode = raw
            case "--auto-close":
                guard ["on", "off"].contains(raw) else { fail("--auto-close wants on or off") }
                autoClose = raw == "on"
            case "--closers":   // what this was called before --auto-close
                guard ["type", "skip"].contains(raw) else { fail("--closers wants type or skip") }
                autoClose = raw == "skip"
            case "--speed-file":  speedPath = raw
            case "--dismiss":
                guard ["space", "escape", "none"].contains(raw) else {
                    fail("--dismiss wants space, escape or none")
                }
                dismiss = raw
            default:              fail("unknown option \(flag)")
            }
        }

        let body = text ?? readStdin()
        guard !body.isEmpty else { fail("nothing to type") }

        if dryRun {
            let strokes = CodeTyper.strokes(for: body, options: CodeTyper.Options(
                indent: indentMode == "literal" ? .literal : .editor,
                autoClose: autoClose,
                dismiss: dismiss == "escape" ? .escape : (dismiss == "none" ? .nothing : .space)
            ))
            for stroke in strokes {
                switch stroke {
                case .text(let run):
                    print("type  \(run.debugDescription)")
                case .key(let code, let flags):
                    let name = code == CGKeyCode(kVK_Return) ? "Return"
                             : code == CGKeyCode(kVK_Tab) ? "Tab"
                             : code == CGKeyCode(kVK_DownArrow) ? "Down"
                             : code == CGKeyCode(kVK_End) ? "End"
                             : code == CGKeyCode(kVK_Escape) ? "Escape"
                             : code == CGKeyCode(kVK_RightArrow) ? "Right" : "key \(code)"
                    print("press \(flags.contains(.maskShift) ? "Shift+" : "")\(name)")
                }
            }
            exit(0)
        }

        // Accessibility is a property of this process, so check it now and save
        // the caller the wait. Secure input depends on what is focused, which is
        // exactly what the grace period is for changing, so that one is checked
        // at the last moment instead.
        guard AXIsProcessTrusted() else {
            complain("""
            no Accessibility permission, so keystrokes would go nowhere.
            Grant it to whichever app runs this (Terminal, iTerm, VS Code, …) in
            System Settings → Privacy & Security → Accessibility, then restart it.
            """)
            exit(4)
        }

        // ---- type it ----
        let engine = TypingEngine()
        engine.onFinish = { aborted in exit(aborted ? 2 : 0) }
        if let path = speedPath {
            let speed = SpeedFile(path: path)
            engine.pace = { speed.wpm() }
        }

        // SIGTERM/SIGINT must also work during the grace period, so the delay
        // is a main queue timer rather than a sleep: the signal handler and the
        // timer both land on the main queue, in order, never at once.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                aborted = true
                engine.cancel()
                if !engine.isRunning { exit(2) }   // still in the grace period
            }
            source.resume()
            signalSources.append(source)
        }

        let strokes = CodeTyper.strokes(for: body, options: CodeTyper.Options(
            indent: indentMode == "literal" ? .literal : .editor,
            autoClose: autoClose,
            dismiss: dismiss == "escape" ? .escape : (dismiss == "none" ? .nothing : .space)
        ))

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            if aborted { exit(2) }
            if IsSecureEventInputEnabled() {
                complain("secure input is on for the focused app, so macOS would drop every "
                       + "keystroke. In Terminal that is Terminal \u{25B8} Secure Keyboard Entry; "
                       + "a focused password field does the same.")
                exit(3)
            }
            engine.type(strokes, profile: profile)
        }
        RunLoop.main.run()   // onFinish is delivered on the main queue and exits
    }

    /// The words per minute, read from a file as the typing goes out so that
    /// whoever started this can speed it up or slow it down without stopping it.
    /// Re-read at most five times a second; anything unreadable or out of range
    /// leaves the speed where it was.
    private final class SpeedFile {
        private let url: URL
        private let lock = NSLock()
        private var value: Double?
        private var lastRead = Date.distantPast

        init(path: String) { url = URL(fileURLWithPath: path) }

        func wpm() -> Double? {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            if now.timeIntervalSince(lastRead) < 0.2 { return value }
            lastRead = now
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number >= 5, number <= 400
            else { return value }
            value = number
            return value
        }
    }

    /// Held for the process lifetime; a released DispatchSource stops firing.
    private static var signalSources: [DispatchSourceSignal] = []
    private static var aborted = false

    private static func readStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func number(_ raw: String, _ flag: String, min lo: Double, max hi: Double) -> Double {
        guard let value = Double(raw), value >= lo, value <= hi else {
            fail("\(flag) wants a number between \(lo) and \(hi), got \(raw)")
        }
        return value
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data("typehuman: \(message)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        complain(message)
        exit(64)
    }
}
