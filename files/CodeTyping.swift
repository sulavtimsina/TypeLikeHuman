import AppKit
import Carbon.HIToolbox

/// Turns formatted source code into the keystrokes a person would actually
/// press in an editor that helps while you type.
///
/// Such an editor does two things for you, and both of them ruin a straight
/// replay of the text:
///
/// * **It indents.** Press Return and it inserts leading whitespace of its own.
///   Typing the text's spaces as well stacks the two, and because each line is
///   indented from the last, the error compounds — the code walks to the right
///   and lines that should dedent never come back.
/// * **It closes.** Type `(` and it inserts `)`, type `"` and it inserts the
///   closing quote, type `{` and Return and it lays out the whole block. Typing
///   the text's own closer then leaves a second one behind.
///
/// So neither the indentation nor the closing characters are typed here. They
/// are *read* from the text and turned into the keys a person presses instead:
/// Return, Tab, Shift+Tab, and Right or Down+End to step over a bracket that is
/// already there. What gets typed is only what a person types — the code itself.
struct CodeTyper {

    enum Indent { case editor, literal }
    enum Dismiss { case space, escape, nothing }

    struct Options {
        /// Does the target indent by itself when Return is pressed?
        var indent: Indent = .editor
        /// Does it insert the closing bracket, brace or quote for you?
        var autoClose = true
        /// How to get rid of a suggestion list, which owns Return while it is up.
        var dismiss: Dismiss = .space
    }

    static func strokes(for code: String, options: Options = Options()) -> [TypingEngine.Stroke] {
        if options.indent == .literal && !options.autoClose {
            return TypingEngine.strokes(for: code)   // byte for byte, for plain fields
        }
        var typer = CodeTyper(options: options)
        typer.build(code)
        return typer.strokes
    }

    // MARK: - State

    /// A bracket or quote we typed, and therefore one the editor has closed for
    /// us. The line matters: a pair opened earlier has had its closer pushed
    /// onto a line of its own by the Returns since, while one opened on this
    /// line is still sitting just right of the cursor.
    private struct Open {
        let character: Character
        let line: Int
    }

    private let options: Options
    private var strokes: [TypingEngine.Stroke] = []
    private var pending = ""            // characters not yet handed over
    private var open: [Open] = []
    private var endsOnWord = false      // is a suggestion list likely up?

    private init(options: Options) {
        self.options = options
    }

    // MARK: - Emitting

    private mutating func flush() {
        if !pending.isEmpty { strokes.append(.text(pending)); pending = "" }
    }

    private mutating func type(_ character: Character) {
        pending.append(character)
        endsOnWord = character.isLetter || character.isNumber || character == "_"
    }

    private mutating func press(_ key: Int, _ flags: CGEventFlags = []) {
        flush()
        strokes.append(.key(CGKeyCode(key), flags))
        endsOnWord = false
    }

    /// While a suggestion list is open it owns Return, Tab and Down, so it has
    /// to go first. A space closes it and costs only trailing whitespace.
    private mutating func dismissSuggestions() {
        guard endsOnWord else { return }
        switch options.dismiss {
        case .space:   type(" ")
        case .escape:  press(kVK_Escape)
        case .nothing: break
        }
        endsOnWord = false
    }

    /// Move out over a closer the editor put in for us.
    private mutating func stepOver(_ entry: Open, openedOnThisLine: Bool) {
        if openedOnThisLine {
            press(kVK_RightArrow)          // it is immediately right of the cursor
        } else {
            dismissSuggestions()
            press(kVK_DownArrow)           // Return has moved it to its own line
            press(kVK_End)
        }
    }

    // MARK: - Building

    private mutating func build(_ code: String) {
        let lines = code.components(separatedBy: "\n")
        let unit = Self.indentUnit(of: lines)
        var base = 0
        var started = false
        var previousLevel = 0        // level of the last line typed
        var previousOpened = false   // did it end in an opener?

        for (index, line) in lines.enumerated() {
            let content = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            let blank = content.isEmpty

            if !started {
                if blank { continue }                 // ignore leading blank lines
                started = true
                base = Self.width(of: line, unit: unit)
                write(content, line: index)
                previousLevel = 0
                previousOpened = Self.opens(content)
                continue
            }

            let wanted = options.indent == .editor
                ? max(0, (Self.width(of: line, unit: unit) - base) / unit)
                : 0

            // A line that starts with a closer we are holding open: the editor's
            // copy of it is sitting on the next line, so step down onto it
            // rather than press Return and type a second one. What follows it on
            // the line — `else {`, `while (x);` — is then typed as usual.
            if options.autoClose, !blank,
               let first = content.first, Self.isCloser(first),
               let entry = open.last, Self.matches(entry.character, first), entry.line < index {
                open.removeLast()
                stepOver(entry, openedOnThisLine: false)
                previousLevel = wanted
                let rest = String(content.dropFirst())
                if !rest.isEmpty { write(rest, line: index) }
                previousOpened = Self.opens(content)
                continue
            }

            dismissSuggestions()
            press(kVK_Return)

            // Where the editor will have left the cursor.
            let given = previousLevel + (previousOpened ? 1 : 0)

            if blank {
                previousLevel = given
                previousOpened = false
                continue
            }

            if options.indent == .editor {
                let steps = wanted - given
                // A line beginning with a closer is left alone: `}` re-indents
                // itself, and a Shift+Tab as well would take it one level too far.
                if steps != 0 && !Self.isCloser(content.first!) {
                    for _ in 0..<abs(steps) { press(kVK_Tab, steps > 0 ? [] : [.maskShift]) }
                }
                previousLevel = wanted
            } else {
                pending += String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            }

            write(content, line: index)
            previousOpened = Self.opens(content)
        }
        flush()
    }

    /// One line of code, character by character. Brackets and quotes the editor
    /// has already closed are stepped over instead of typed; everything inside a
    /// string or a comment is typed as it stands, since editors do not close
    /// brackets in there.
    private mutating func write(_ content: String, line index: Int) {
        var state = State.code
        let characters = Array(content)
        var position = 0

        while position < characters.count {
            let character = characters[position]
            let next = position + 1 < characters.count ? characters[position + 1] : nil

            switch state {
            case .code:
                if character == "/", next == "/" { state = .lineComment }
                else if character == "#" { state = .lineComment }
                else if character == "/", next == "*" { state = .blockComment }
                else if character == "\"" || character == "'" {
                    type(character)
                    if options.autoClose { open.append(Open(character: character, line: index)) }
                    state = .string(character)
                    position += 1
                    continue
                } else if Self.isOpener(character) {
                    type(character)
                    if options.autoClose { open.append(Open(character: character, line: index)) }
                    position += 1
                    continue
                } else if Self.isCloser(character), options.autoClose,
                          let entry = open.last, Self.matches(entry.character, character) {
                    open.removeLast()
                    stepOver(entry, openedOnThisLine: entry.line == index)
                    position += 1
                    continue
                }

            case .string(let quote):
                if character == "\\", next != nil {        // an escape: both characters stand
                    type(character)
                    type(characters[position + 1])
                    position += 2
                    continue
                }
                if character == quote {
                    if options.autoClose, let entry = open.last, entry.character == quote {
                        open.removeLast()
                        stepOver(entry, openedOnThisLine: entry.line == index)
                    } else {
                        type(character)
                    }
                    state = .code
                    position += 1
                    continue
                }

            case .blockComment:
                if character == "*", next == "/" {
                    type(character)
                    type("/")
                    state = .code
                    position += 2
                    continue
                }

            case .lineComment:
                break                                      // to the end of the line
            }

            type(character)
            position += 1
        }
    }

    private enum State {
        case code
        case string(Character)
        case lineComment
        case blockComment
    }

    // MARK: - Reading the text

    /// Leading whitespace as a column count, a tab counting as one unit.
    static func width(of line: String, unit: Int) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += unit }
            else { break }
        }
        return columns
    }

    /// The step the text indents by — the smallest gap between the levels it
    /// uses — so two-space code is not turned into four.
    static func indentUnit(of lines: [String]) -> Int {
        var widths = Set<Int>()
        for line in lines {
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if content.isEmpty { continue }
            if line.first == "\t" { return 4 }            // tab indented: one tab, one level
            widths.insert(line.count - content.count)
        }
        let sorted = widths.sorted()
        var unit = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) { unit = gcd(unit, b - a) }
        return unit > 0 ? unit : 4
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Will the editor add a level after this line?
    static func opens(_ content: String) -> Bool {
        guard let last = content.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "{" || last == "(" || last == "[" || last == ":"
    }

    static func isOpener(_ character: Character) -> Bool {
        character == "{" || character == "(" || character == "["
    }

    static func isCloser(_ character: Character) -> Bool {
        character == "}" || character == ")" || character == "]"
    }

    static func matches(_ opener: Character, _ closer: Character) -> Bool {
        switch (opener, closer) {
        case ("{", "}"), ("(", ")"), ("[", "]"): return true
        case let (a, b) where a == b: return true          // quotes
        default: return false
        }
    }
}
