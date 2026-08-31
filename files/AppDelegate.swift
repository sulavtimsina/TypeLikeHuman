import AppKit
import Carbon.HIToolbox

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private let engine = TypingEngine()
    private var profile = TypingEngine.Profile()

    private var countdownTimer: Timer?
    private var abortMonitor: Any?
    private var hubstaffCountdown: HubstaffCountdown?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("keyboard")
        hubstaffCountdown = HubstaffCountdown()
        buildMenu()
        installClickHandler()
        requestAccessibilityIfNeeded()
    }

    /// Left click types the clipboard straight away; right click opens the menu.
    private func installClickHandler() {
        guard let button = statusItem.button else { return }
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(iconClicked)
        button.target = self
    }

    @objc private func iconClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // back to click handling once the menu closes
        } else {
            typeClipboard()
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let speed = NSMenu()
        for wpm in [30.0, 40.0, 50.0, 60.0, 70.0] {
            let item = NSMenuItem(title: "\(Int(wpm)) wpm", action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.representedObject = wpm
            item.state = (wpm == profile.wpm) ? .on : .off
            item.target = self
            speed.addItem(item)
        }
        let speedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        speedItem.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Speed")
        speedItem.submenu = speed
        menu.addItem(speedItem)

        let typos = NSMenu()
        for percent in [0, 5, 10, 15, 20, 30] {
            let title = percent == 0 ? "None (100% correct)" : "\(percent)% of characters"
            let item = NSMenuItem(title: title, action: #selector(setTypoRate(_:)), keyEquivalent: "")
            item.representedObject = Double(percent) / 100.0
            item.state = abs(profile.typoRate - Double(percent) / 100.0) < 0.001 ? .on : .off
            item.target = self
            typos.addItem(item)
        }
        let typosItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        typosItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Mistakes")
        typosItem.submenu = typos
        menu.addItem(typosItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        for item in menu.items where item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        self.menu = menu
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let wpm = sender.representedObject as? Double else { return }
        profile.wpm = wpm
        buildMenu()
    }

    @objc private func setTypoRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        profile.typoRate = rate
        buildMenu()
    }

    // MARK: - Sources

    @objc private func typeClipboard() {
        // Empty clipboard: do nothing, quietly.
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        begin(text)
    }

    // MARK: - Run

    private func begin(_ text: String) {
        guard hasAccessibility() else { requestAccessibilityIfNeeded(); return }

        // Password field or secure terminal active: macOS would drop the events, so do nothing.
        if IsSecureEventInputEnabled() { return }

        statusItem.button?.action = #selector(abort) // clicking the icon now aborts

        // Silent five second grace period so you can click into the target field.
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.countdownTimer = nil
            self.startAbortMonitor()
            self.engine.type(text, profile: self.profile)
        }

        engine.onFinish = { [weak self] _ in self?.reset() }
    }

    @objc private func abort() {
        countdownTimer?.invalidate()
        engine.cancel()
        reset()
    }

    private func reset() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        stopAbortMonitor()
        setTitle("")
        setIcon("keyboard")
        installClickHandler()
        buildMenu()
    }

    /// Esc stops it. Our own synthetic keystrokes carry a signature so they
    /// never trigger this.
    private func startAbortMonitor() {
        abortMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            guard userData != TypingEngine.eventSignature else { return }
            if event.keyCode == UInt16(kVK_Escape) { self?.abort() }
        }
    }

    private func stopAbortMonitor() {
        if let monitor = abortMonitor { NSEvent.removeMonitor(monitor) }
        abortMonitor = nil
    }

    // MARK: - Chrome

    private func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fancy Keyboard")
    }

    private func setTitle(_ text: String) {
        statusItem.button?.title = text
    }

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    // MARK: - Permission

    private func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    private func requestAccessibilityIfNeeded() {
        guard !hasAccessibility() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
