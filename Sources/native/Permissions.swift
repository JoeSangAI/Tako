// The two switches Tako needs in System Settings. The owner is asked as rarely as the system allows (Joe 2026-11-04):
// each switch once, and nothing Tako can put right itself. Accessibility is checked the moment the list changes and every
// second until it is on; the system's own prompt comes once, on the first start, after that only the panel's card asks.
// The list changing while the system still says no means its record for Tako has gone stale (seen on a friend's Mac
// 2026-11-04): Tako clears its own record by itself, so the next switch-on takes. Screen Recording only counts in a process
// started after it was switched on: a fresh copy of Tako is asked, and once it says yes, Tako restarts itself when idle.
//
// The system ties each switch to the app's designated requirement, not its name. A Tako signed with the same certificate keeps
// its switches across versions; one built ad hoc is a new app to the system every time it is built, and the switch still
// showing on belongs to the old build (GitHub issue 2, 2026-11-07). So the requirement each switch was last on under is kept:
// off now under another one, or off in an ad-hoc build, means the record is stale, and Tako clears it once for this build.
import ApplicationServices
import AppKit
import Security

let askedAccessibilityKey = "askedAccessibility"

/// Who the system takes this Tako to be: the requirement its switches are tied to, and whether it was signed ad hoc.
func signingIdentity() -> (requirement: String, adhoc: Bool) {
    var code: SecCode?, staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return ("", true) }
    var requirement: SecRequirement?, text: CFString?, info: CFDictionary?
    if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement { SecRequirementCopyString(requirement, [], &text) }
    SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    return ((text as String?) ?? "", flags & 0x2 != 0)  // 0x2: kSecCodeSignatureAdhoc
}

extension Controller {
    /// At launch: the system's prompt on the first start only.
    func checkTrustAtLaunch() {
        (signedAs, adhocSigned) = signingIdentity()
        let asked = UserDefaults.standard.bool(forKey: askedAccessibilityKey)
        trusted = AXIsProcessTrusted()
        log("accessibility trusted=\(trusted) signing=\(adhocSigned ? "adhoc" : "certificate")\(trusted ? "" : " record=\(staleRecord("accessibility") ? "stale" : "current")")")
        if trusted {
            remember("accessibility")
        } else if staleRecord("accessibility"), repairOnce("accessibility") {
            repairedOnce = true    // the list changes when the record goes: that notice must not clear it a second time
            repairAccessibility()  // the switch on screen belongs to another build: clear it, so one switch-on takes
        } else {
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !asked] as CFDictionary)
        }
        if !trusted { UserDefaults.standard.set(true, forKey: askedAccessibilityKey) }
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
            remember("accessibility")
            makeRoom(animated: true)
            installPointing()
        }
    }

    /// Every couple of seconds until Screen Recording is on. The first no says which of three it is: the record belongs to another
    /// build (`identity`), or it is simply off (`off`); a fresh process saying yes later makes it `restart`.
    func checkCapture() {
        canCapture = CGPreflightScreenCaptureAccess()
        if canCapture {
            log("screen capture trusted=true")
            remember("screen")
            screenWhy = ""
            web.evaluateJavaScript("setCanRead(true)")
            tellPermissions()
            return
        }
        guard trusted, !captureAsked else { return }
        captureAsked = true
        let stale = staleRecord("screen")
        screenWhy = stale ? "identity" : "off"
        log("screen capture trusted=false signing=\(adhocSigned ? "adhoc" : "certificate") record=\(stale ? "stale" : "current")")
        if stale, repairOnce("screen") {
            repairScreen()
        } else if !UserDefaults.standard.bool(forKey: "askedScreenCapture") {
            // The system's prompt once ever; after that the panel's card asks, with a restart in it.
            UserDefaults.standard.set(true, forKey: "askedScreenCapture")
            _ = CGRequestScreenCaptureAccess()
        }
        tellPermissions()
    }

    /// The panel's card says which it is, and so does panel.log: that is where to look when the switch is on and the card stays.
    func tellPermissions() {
        func js(_ value: Bool?) -> String { value.map { "\($0)" } ?? "null" }
        web?.evaluateJavaScript("setPermissionState({screen: '\(screenWhy)', adhoc: \(adhocSigned), screenRepaired: \(js(screenRepaired)), accessRepaired: \(js(accessRepaired))})")
    }

    // MARK: whose switch it is

    /// The switch was on under this very requirement: a later build signed the same way keeps it.
    func remember(_ which: String) {
        guard !signedAs.isEmpty else { return }
        UserDefaults.standard.set(signedAs, forKey: "grantedUnder.\(which)")
    }

    /// Off, and the record the system holds is for some other build: on under another requirement before, or this build is ad hoc,
    /// which the system knows by its exact bytes, so nothing it was given before can be for this one.
    func staleRecord(_ which: String) -> Bool {
        let was = UserDefaults.standard.string(forKey: "grantedUnder.\(which)")
        return !signedAs.isEmpty && was != signedAs && (was != nil || adhocSigned)
    }

    /// Clearing is done once per build: after that the record is this build's own, and an off switch really is off.
    func repairOnce(_ which: String) -> Bool {
        let key = "repairedFor.\(which)"
        guard UserDefaults.standard.string(forKey: key) != signedAs else { return false }
        UserDefaults.standard.set(signedAs, forKey: key)
        return true
    }

    /// Only Tako's own line in the list, never anyone else's. Works without an administrator (tried 2026-11-07, macOS 15).
    func clearRecord(_ service: String) -> Bool {
        let id = Bundle.main.bundleIdentifier ?? "com.joesang.tako"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// The switch is on and the system still says no: clear Tako's own line in the list, then ask again, so one more switch-on takes.
    func repairAccessibility() {
        let cleared = clearRecord("Accessibility")
        log("accessibility repair cleared=\(cleared)")
        accessRepaired = cleared
        web?.evaluateJavaScript("setRepaired(\(cleared))")
        tellPermissions()
        // The system's own prompt puts Tako back in the list, switched off, ready for the one switch-on.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    /// The same for Screen Recording. The system's request puts this build back in the list, switched off.
    func repairScreen() {
        let cleared = clearRecord("ScreenCapture")
        log("screen capture repair cleared=\(cleared)")
        screenRepaired = cleared
        UserDefaults.standard.set(true, forKey: "askedScreenCapture")
        _ = CGRequestScreenCaptureAccess()
        tellPermissions()
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
                if self.screenFresh != yes {
                    // Asked by this Tako, the answer is this Tako's: one asked from Terminal answers for Terminal.
                    self.screenFresh = yes
                    self.log("screen capture fresh process=\(yes ? "yes" : "no")")
                }
                guard !self.canCapture else { return }
                let why = yes ? "restart" : (self.screenWhy == "restart" ? "off" : self.screenWhy)
                if why != self.screenWhy { self.screenWhy = why; self.tellPermissions() }
                guard yes, !self.operating, self.gesture == nil, self.listener == nil, !self.jobUnderWay() else { return }
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
