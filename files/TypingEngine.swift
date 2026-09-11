import AppKit
import Carbon.HIToolbox

/// Types a string into whatever app currently has keyboard focus, pacing the
/// keystrokes so they resemble a fast human typist rather than a paste.
final class TypingEngine {

    /// Stamped onto every event we post so our own keystrokes can be told apart
    /// from the user's when we listen for the abort key.
    static let eventSignature: Int64 = 0x4B59_5052 // "KYPR"

    struct Profile {
        /// Words per minute, counting a word as five characters.
        var wpm: Double = 40
        /// Spread of the lognormal delay. Higher is more erratic.
        var jitter: Double = 0.34
        /// Chance per character of hitting a neighbouring key first (0 to 0.3).
        var typoRate: Double = 0.20
        /// Chance per character of pausing as if thinking.
        var hesitationRate: Double = 0.03
    }

    /// What the engine types. A caller that knows about the target — say, that
    /// it is a code editor which indents by itself — can build the keystrokes
    /// itself instead of handing over a plain string.
    enum Stroke {
        case text(String)
        case key(CGKeyCode, CGEventFlags)
    }

    private let queue = DispatchQueue(label: "com.example.humantype.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    /// Called on the main queue when typing finishes or is aborted.
    var onFinish: ((_ aborted: Bool) -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func type(_ text: String, profile: Profile = Profile()) {
        type(Self.strokes(for: text), profile: profile)
    }

    func type(_ strokes: [Stroke], profile: Profile = Profile()) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        cancelled = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let aborted = self.run(strokes, profile: profile)
            self.lock.lock(); self.running = false; self.lock.unlock()
            DispatchQueue.main.async { self.onFinish?(aborted) }
        }
    }

    /// Plain text: every line break is a Return, everything else is typed.
    static func strokes(for text: String) -> [Stroke] {
        var out: [Stroke] = []
        var run = ""
        for character in text {
            if character == "\n" || character == "\r" {
                if !run.isEmpty { out.append(.text(run)); run = "" }
                out.append(.key(CGKeyCode(kVK_Return), []))
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty { out.append(.text(run)) }
        return out
    }

    // MARK: - Main loop

    private func run(_ strokes: [Stroke], profile: Profile) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return true }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let base = 60.0 / (profile.wpm * 5.0) // mean seconds between keystrokes
        var deadline = Date().timeIntervalSinceReferenceDate
        var sinceLastHesitation = 0

        for stroke in strokes {
            if isCancelled { return true }

            // A named key: Return, Tab, Shift+Tab. No typos on these — people
            // do not mistype Return — but they still take a beat.
            guard case .text(let chunk) = stroke else {
                guard case .key(let code, let flags) = stroke else { continue }
                deadline += delay(base: base, jitter: profile.jitter) * 2
                if code == CGKeyCode(kVK_Return) { deadline += Double.random(in: 0.10...0.28) }
                sleep(until: deadline)
                if isCancelled { return true }
                emit(keyCode: code, flags: flags, source: source)
                continue
            }

            for character in chunk {
            if isCancelled { return true }

            // Occasional mistake: wrong key, a beat, backspace, then the right one.
            if let wrong = Self.neighbour(of: character), Double.random(in: 0..<1) < profile.typoRate {
                deadline += delay(base: base, jitter: profile.jitter)
                sleep(until: deadline)
                emit(String(wrong), source: source)

                deadline += Double.random(in: 0.18...0.45) // noticing it
                sleep(until: deadline)
                emit(keyCode: CGKeyCode(kVK_Delete), source: source)

                deadline += Double.random(in: 0.08...0.20) // recovering
                sleep(until: deadline)
            }

            deadline += delay(base: base, jitter: profile.jitter) * Self.speedFactor(for: character)
            deadline += Self.trailingPause(after: character)

            sinceLastHesitation += 1
            if sinceLastHesitation > 15, Double.random(in: 0..<1) < profile.hesitationRate {
                deadline += Double.random(in: 0.3...0.8)
                sinceLastHesitation = 0
            }

            sleep(until: deadline)
            if isCancelled { return true }

            if character == "\n" || character == "\r" {
                emit(keyCode: CGKeyCode(kVK_Return), source: source)
            } else {
                emit(String(character), source: source)
            }
            }
        }
        return false
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func sleep(until deadline: TimeInterval) {
        let remaining = deadline - Date().timeIntervalSinceReferenceDate
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    // MARK: - Timing

    /// Lognormal around `base`. Real typing has a hard floor and a long tail of
    /// slow keystrokes, which a uniform distribution does not reproduce.
    private func delay(base: Double, jitter: Double) -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1)
        let u2 = Double.random(in: 0..<1)
        let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        let mu = log(base) - (jitter * jitter) / 2
        return min(max(exp(mu + jitter * z), base * 0.35), base * 6)
    }

    /// Letters go at full speed, digits take twice as long, everything else
    /// (punctuation, symbols, whitespace) three times as long.
    private static func speedFactor(for character: Character) -> Double {
        if character.isLetter { return 1 }
        if character.isNumber { return 2 }
        return 3
    }

    private static func trailingPause(after character: Character) -> Double {
        switch character {
        case ".", "?", "!":       return Double.random(in: 0.18...0.34)
        case ",", ";", ":":       return Double.random(in: 0.08...0.16)
        case "\n", "\r":          return Double.random(in: 0.20...0.40)
        default:                  return 0
        }
    }

    // MARK: - Event posting

    private func emit(_ text: String, source: CGEventSource) {
        var buffer = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        stamp(down); stamp(up)

        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Double.random(in: 0.008...0.022)) // key hold
        up.post(tap: .cghidEventTap)
    }

    private func emit(keyCode: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        if !flags.isEmpty { down.flags = flags; up.flags = flags }
        stamp(down); stamp(up)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Double.random(in: 0.010...0.030))
        up.post(tap: .cghidEventTap)
    }

    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventSignature)
    }

    // MARK: - Typos

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// A key physically next to `character` on a QWERTY board, preserving case.
    private static func neighbour(of character: Character) -> Character? {
        let lower = Character(character.lowercased())
        guard lower.isLetter else { return nil }
        for row in rows {
            guard let index = row.firstIndex(of: lower) else { continue }
            var candidates: [Character] = []
            if index > row.startIndex { candidates.append(row[row.index(before: index)]) }
            let next = row.index(after: index)
            if next < row.endIndex { candidates.append(row[next]) }
            guard let pick = candidates.randomElement() else { return nil }
            return character.isUppercase ? Character(pick.uppercased()) : pick
        }
        return nil
    }
}
