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
      --closers     what to do with a line that is only a closing bracket,
                    when its opener was typed in this run (default "type"):
                      type  type it, as written
                      skip  step over the one the editor auto-inserted with
                            Down then End, the way a person does, instead of
                            leaving a second copy behind
      --dismiss     how to get rid of an autocomplete popup before pressing
                    Return, Tab or Down, since those keys belong to the popup
                    while it is open (default "space"):
                      space   type a space, which closes the list and leaves
                              only trailing whitespace behind
                      escape  press Escape, surer but the page may act on it
                      none    press nothing
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
        var skipClosers = false
        var dismiss = "space"

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
            case "--closers":
                guard ["type", "skip"].contains(raw) else { fail("--closers wants type or skip") }
                skipClosers = raw == "skip"
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
            let strokes = indentMode == "literal"
                ? TypingEngine.strokes(for: body)
                : editorStrokes(for: body, skipAutoClosed: skipClosers, dismiss: dismiss)
            for stroke in strokes {
                switch stroke {
                case .text(let run):
                    print("type  \(run.debugDescription)")
                case .key(let code, let flags):
                    let name = code == CGKeyCode(kVK_Return) ? "Return"
                             : code == CGKeyCode(kVK_Tab) ? "Tab"
                             : code == CGKeyCode(kVK_DownArrow) ? "Down"
                             : code == CGKeyCode(kVK_End) ? "End"
                             : code == CGKeyCode(kVK_Escape) ? "Escape" : "key \(code)"
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

        let strokes = indentMode == "literal"
            ? TypingEngine.strokes(for: body)
            : editorStrokes(for: body)

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

    // MARK: - Typing into an editor that indents by itself

    /// Keystrokes for code, the way a person produces them in a real editor.
    ///
    /// Nobody types leading spaces in such an editor: you press Return, the
    /// editor indents for you, and you only reach for Tab or Shift+Tab when the
    /// level has to change. Typing the spaces as well is what stacks the two
    /// and walks the code to the right, a line at a time.
    ///
    /// So the indentation here is *relative*: the first line goes in wherever
    /// the cursor already is, and every line after it is placed by the
    /// difference between the level the code asks for and the level the editor
    /// will have given us — which is the previous line's level, plus one if that
    /// line ended in an opener like `{` or `:`. Nothing absolute is ever
    /// assumed, so the block lands correctly however deep the cursor started.
    ///
    /// A line that begins with a closer is left alone: `}` re-indents itself in
    /// every editor of this kind, and pressing Shift+Tab as well would take it
    /// one level too far.
    static func editorStrokes(for text: String,
                              skipAutoClosed: Bool = false,
                              dismiss: String = "space") -> [TypingEngine.Stroke] {
        let lines = text.components(separatedBy: "\n")
        let unit = indentUnit(of: lines)

        var strokes: [TypingEngine.Stroke] = []
        var baseWidth: Int? = nil     // indentation of the first line, treated as level 0
        var previousLevel = 0         // level of the last line we typed
        var previousOpened = false    // did it end in {, (, [ or : ?
        var started = false
        var openBrackets = 0          // openers typed here, so closers the editor
                                      // will have inserted for us
        var lastTyped = ""            // to tell whether a suggestion list is up

        for line in lines {
            let content = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            let blank = content.isEmpty

            if !started {
                if blank { continue }               // ignore leading blank lines
                started = true
                baseWidth = width(of: line, unit: unit)
                strokes.append(.text(content))
                previousLevel = 0
                previousOpened = opens(content)
                openBrackets += openerBalance(content)
                lastTyped = content
                continue
            }

            // A line that is nothing but a closer, whose opener we typed: the
            // editor already put that bracket in, so step past it rather than
            // type a second one. No Return either — the bracket is on the line
            // below already, so a Return would only leave a blank line behind.
            if skipAutoClosed, !blank, onlyClosers(content), openBrackets > 0 {
                append(dismissal: dismiss, after: lastTyped, to: &strokes)
                strokes.append(.key(CGKeyCode(kVK_DownArrow), []))
                strokes.append(.key(CGKeyCode(kVK_End), []))
                openBrackets -= 1
                previousLevel = max(0, (width(of: line, unit: unit) - (baseWidth ?? 0)) / unit)
                previousOpened = false
                lastTyped = content
                continue
            }

            append(dismissal: dismiss, after: lastTyped, to: &strokes)
            strokes.append(.key(CGKeyCode(kVK_Return), []))

            // Where the editor will have put the cursor after that Return.
            let given = previousLevel + (previousOpened ? 1 : 0)

            if blank {
                // A blank line keeps whatever the editor gave it; the next line
                // is measured from the same place.
                previousLevel = given
                previousOpened = false
                lastTyped = ""
                continue
            }

            let wanted = max(0, (width(of: line, unit: unit) - (baseWidth ?? 0)) / unit)
            let steps = wanted - given
            if steps != 0 && !closes(content) {
                for _ in 0..<abs(steps) {
                    strokes.append(.key(CGKeyCode(kVK_Tab), steps > 0 ? [] : [.maskShift]))
                }
            }
            strokes.append(.text(content))
            previousLevel = wanted
            previousOpened = opens(content)
            openBrackets += openerBalance(content)
            lastTyped = content
        }
        return strokes
    }

    /// An editor that completes as you type puts a suggestion list up whenever
    /// the caret sits at the end of a word — and while that list is open, Return
    /// inserts the highlighted suggestion instead of a line break, Tab accepts
    /// it, and Down walks the list. So the list has to go before any of those
    /// keys is pressed. A space closes it and costs only trailing whitespace,
    /// which no compiler minds.
    private static func append(dismissal: String,
                               after typed: String,
                               to strokes: inout [TypingEngine.Stroke]) {
        guard let last = typed.last, last.isLetter || last.isNumber || last == "_" else { return }
        switch dismissal {
        case "space":  strokes.append(.text(" "))
        case "escape": strokes.append(.key(CGKeyCode(kVK_Escape), []))
        default:       break
        }
    }

    /// Openers minus closers on a line, ignoring anything inside quotes.
    private static func openerBalance(_ content: String) -> Int {
        var balance = 0
        var quote: Character? = nil
        var previous: Character = " "
        for character in content {
            if let open = quote {
                if character == open && previous != "\\" { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" || character == "(" || character == "[" {
                balance += 1
            } else if character == "}" || character == ")" || character == "]" {
                balance -= 1
            }
            previous = character
        }
        return balance
    }

    private static func onlyClosers(_ content: String) -> Bool {
        let stripped = content.filter { !$0.isWhitespace }
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy { "})];,".contains($0) }
    }

    /// Leading whitespace as a column count, a tab counting as one unit.
    private static func width(of line: String, unit: Int) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += unit }
            else { break }
        }
        return columns
    }

    /// The step the text indents by: the smallest gap between the levels it
    /// uses, so four-space code and two-space code both come out right.
    private static func indentUnit(of lines: [String]) -> Int {
        var widths = Set<Int>()
        for line in lines {
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if content.isEmpty { continue }
            if line.first == "\t" { return 4 }      // tab-indented: one tab, one level
            widths.insert(line.count - content.count)
        }
        let sorted = widths.sorted()
        var unit = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) { unit = gcd(unit, b - a) }
        return unit > 0 ? unit : 4
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    private static func opens(_ content: String) -> Bool {
        guard let last = content.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "{" || last == "(" || last == "[" || last == ":"
    }

    private static func closes(_ content: String) -> Bool {
        guard let first = content.first else { return false }
        return first == "}" || first == ")" || first == "]"
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
