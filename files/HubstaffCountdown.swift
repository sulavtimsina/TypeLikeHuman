import AppKit

/// A second menu bar item showing "10". Clicking it starts a ten minute
/// countdown; the number drops once a minute, and when it reaches 0 the
/// Hubstaff timer is stopped through Hubstaff's scripted control CLI
/// (https://support.hubstaff.com/what-is-scripted-control/). Clicking
/// again while the countdown is running cancels it.
///
/// The CLI lives inside the Hubstaff app bundle, so this works on any
/// machine that has Hubstaff installed — nothing to configure per laptop.
/// The first time the CLI runs, Hubstaff shows a dialog asking to allow
/// scripted control; choose "Always allow" once and it never asks again.
final class HubstaffCountdown {

    private let totalMinutes = 10

    private var statusItem: NSStatusItem
    private var timer: Timer?
    private var endDate: Date?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\(totalMinutes)"
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.target = self
    }

    @objc private func clicked() {
        timer == nil ? start() : cancel()
    }

    private func start() {
        endDate = Date().addingTimeInterval(TimeInterval(totalMinutes * 60))
        show(totalMinutes)
        // A one second cadence keeps the display honest even if the Mac
        // sleeps mid-countdown: minutes are recomputed from the end date,
        // not counted down blindly.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        show(totalMinutes)
    }

    private func tick() {
        guard let endDate else { return }
        let remaining = endDate.timeIntervalSinceNow
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            self.endDate = nil
            show(0)
            stopHubstaffTimer()
            // Leave the 0 visible for a beat, then rearm.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.timer == nil else { return }
                self.show(self.totalMinutes)
            }
        } else {
            show(Int(ceil(remaining / 60)))
        }
    }

    private func show(_ minutes: Int) {
        statusItem.button?.title = "\(minutes)"
    }

    // MARK: - Hubstaff

    private func stopHubstaffTimer() {
        // Nothing to stop when Hubstaff itself isn't running; without
        // --autostart the CLI would just fail against a dead app anyway.
        let hubstaffRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == "Hubstaff.app" || $0.localizedName == "Hubstaff"
        }
        guard hubstaffRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cli = Self.findCLI() else {
                DispatchQueue.main.async { self?.alertCLIMissing() }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["stop"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// The CLI ships inside the app bundle. Check the usual install spots
    /// first, then ask Spotlight, so a Hubstaff installed anywhere is found.
    private static func findCLI() -> String? {
        var bundles = [
            "/Applications/Hubstaff.app",
            NSHomeDirectory() + "/Applications/Hubstaff.app",
        ]
        let mdfind = Process()
        mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        mdfind.arguments = ["kMDItemFSName == 'Hubstaff.app'"]
        let pipe = Pipe()
        mdfind.standardOutput = pipe
        if (try? mdfind.run()) != nil {
            mdfind.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            bundles += output.split(separator: "\n").map(String.init)
        }
        for bundle in bundles {
            let cli = bundle + "/Contents/MacOS/HubstaffCLI"
            if FileManager.default.isExecutableFile(atPath: cli) { return cli }
        }
        return nil
    }

    private func alertCLIMissing() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hubstaff CLI not found"
        alert.informativeText = "Hubstaff is running but HubstaffCLI wasn't found inside its app bundle, so the timer couldn't be stopped."
        alert.runModal()
    }
}
