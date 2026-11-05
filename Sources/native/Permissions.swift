// The two switches Tako needs in System Settings. The owner is asked as rarely as the system allows (Joe 2026-11-04):
// each switch once, and nothing Tako can put right itself. Accessibility is checked the moment the list changes and every
// second until it is on; the system's own prompt comes once, on the first start, after that only the panel's card asks.
// The list changing while the system still says no means its record for Tako has gone stale (seen on a friend's Mac
// 2026-11-04): Tako clears its own record by itself, so the next switch-on takes. Screen Recording only counts in a process
// started after it was switched on: a fresh copy of Tako is asked, and once it says yes, Tako restarts itself when idle.
import ApplicationServices
import AppKit

let askedAccessibilityKey = "askedAccessibility"

extension Controller {
    /// At launch: the system's prompt on the first start only.
    func checkTrustAtLaunch() {
        let asked = UserDefaults.standard.bool(forKey: askedAccessibilityKey)
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !asked] as CFDictionary)
        if !trusted { UserDefaults.standard.set(true, forKey: askedAccessibilityKey) }
        log("accessibility trusted=\(trusted)")
        // The system tells everyone when the list of trusted apps changes; the timer covers a notice that never came.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // The new answer takes a moment to reach this process. Still no after that: the switch the owner moved didn't take.
            for delay in [0.2, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.recheckTrust() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.trusted, !self.repairedOnce else { return }
                self.repairedOnce = true
                self.repairAccessibility()
            }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.trustTicks += 1
            // Once on, a look every half minute is enough to notice it being switched off.
            if !self.trusted || self.trustTicks % 30 == 0 { self.recheckTrust() }
            if self.trusted, !self.canCapture, self.captureAsked, self.trustTicks % 2 == 0 { self.restartOnceScreenIsOn() }
        }
    }

    func recheckTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        log("accessibility trusted=\(now)")
        web?.evaluateJavaScript("setCanMove(\(now))")
        if now {
            makeRoom(animated: true)
            installPointing()
        }
    }

    /// The switch is on and the system still says no: clear Tako's own line in the list, then ask again, so one more switch-on takes.
    func repairAccessibility() {
        let id = Bundle.main.bundleIdentifier ?? "com.joesang.tako"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var cleared = false
        if (try? task.run()) != nil {
            task.waitUntilExit()
            cleared = task.terminationStatus == 0
        }
        log("accessibility repair cleared=\(cleared)")
        web?.evaluateJavaScript("setRepaired(\(cleared))")
        // The system's own prompt puts Tako back in the list, switched off, ready for the one switch-on.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    func openPrivacy(_ pane: String) {
        if let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(page) }
    }

    /// A fresh copy of Tako says whether Screen Recording is on now; if it is, restart into it, but never in the middle of a job.
    func restartOnceScreenIsOn() {
        guard !askingFresh, let binary = Bundle.main.executableURL else { return }
        askingFresh = true
        DispatchQueue.global().async { [weak self] in
            let task = Process(), out = Pipe()
            task.executableURL = binary
            task.arguments = ["--can-capture"]
            task.standardOutput = out
            task.standardError = FileHandle.nullDevice
            var yes = false
            if (try? task.run()) != nil {
                task.waitUntilExit()
                yes = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.hasPrefix("yes") == true
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.askingFresh = false
                guard yes, !self.canCapture, !self.operating, self.gesture == nil, self.listener == nil, !self.jobUnderWay() else { return }
                self.relaunch()
            }
        }
    }

    /// Screen Recording counts only for a process started after it was switched on: start this one again, where it was.
    func relaunch() {
        let script = """
        #!/bin/sh
        for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
        open "$2"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "relaunch", "\(getpid())", Bundle.main.bundleURL.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        log("relaunching for screen recording")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.quit() }
    }

    /// A job the owner started since this Tako began and not yet ended (asked.py keeps them): a restart would cut it off.
    func jobUnderWay() -> Bool {
        let file = takoHome.appendingPathComponent("asked.json")
        guard let data = try? Data(contentsOf: file), let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        let since = launchedAt.timeIntervalSince1970 - 5
        return jobs.contains { ($0["ended"] as? String) == "在做" && (($0["at"] as? Double) ?? 0) > since }
    }
}
