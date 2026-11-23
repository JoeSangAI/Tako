// Whether Tako may interrupt the owner now. One place knows, and the hand-overs (Entrusted), the hints (Teaching), the
// body and its idle play all read `quiet` here. It is told rather than asking: the microphone and the cameras (CoreAudio,
// CoreMediaIO), the app in front, the Space, sleep and wake, and the owner's own input each send a notice. The one thing no
// notice covers, whether the app in front keeps the display awake (a film, a presentation), is looked at on those notices,
// right before an idle scene would start, and only while something is held now and then. Nothing here reads a window's
// contents: the front window's full-screen flag and frame are all it asks.
import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.pwr_mgt

final class Attention {
    unowned let host: Controller
    private(set) var muted = false, hidden = false
    private(set) var microphone = false, camera = false, keepsAwake = false
    private var keepsAwakeAt: CFTimeInterval = -100
    /// Away: no input for two minutes. `returned` is handed out once, to whoever asks first after they are back.
    private(set) var away = false
    private var returnedFor: Set<String> = []
    private var lastInput = CACurrentMediaTime()
    private var awayCheck: DispatchSourceTimer?, watch: DispatchSourceTimer?, settle: DispatchWorkItem?
    private var inputDevice = AudioDeviceID(0), cameras: [CMIODeviceID] = []
    private var started = false
    static let awayAfter: Double = 120
    /// Seconds since the owner last touched the keyboard or pointer. Any input: asking about one event type (the null
    /// event) answers for an event that never comes, so the owner looked away a second after every return.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    init(_ host: Controller) { self.host = host }

    var quiet: Bool { muted || hidden || automatic }
    /// The microphone (not Tako's own listening), a camera, or the app in front keeping the display awake.
    var automatic: Bool { AttentionPolicy.quiet(microphone: microphone, ownSpeech: host.speaking.usingMicrophone, camera: camera, power: keepsAwake) }

    /// The body may start something of its own: an idle scene, a glance at the window, reaching for the cursor. The display
    /// check is only made here, right before, when it is older than a few seconds.
    var allowsPlay: Bool {
        guard !muted, !hidden, !microphone || host.speaking.usingMicrophone, !camera else { return false }
        if !host.selfTest, CACurrentMediaTime() - keepsAwakeAt > 8 {
            let before = keepsAwake
            refreshKeepsAwake()
            if before != keepsAwake { DispatchQueue.main.async { [weak self] in self?.apply() } }
        }
        return !keepsAwake
    }

    func load() {
        guard !host.selfTest, let data = try? Data(contentsOf: takoHome.appendingPathComponent("quiet.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return }
        muted = state["muted"] ?? false; hidden = state["hidden"] ?? false
    }

    func start() {
        guard !host.selfTest, !started else { return }
        started = true
        load()
        listenToMicrophone()
        listenToCameras()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name != NSWorkspace.didActivateApplicationNotification { self.noteInput() }
                self.refreshKeepsAwake(); self.apply()
            }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.wentAway() }
        refreshKeepsAwake()
        apply()
        rewatch()
    }

    func setQuiet(muted newMute: Bool? = nil, hidden newHidden: Bool? = nil) {
        let wasHidden = hidden
        if let newMute { muted = newMute }
        if let newHidden { hidden = newHidden }
        if !host.selfTest, let data = try? JSONSerialization.data(withJSONObject: ["muted": muted, "hidden": hidden]) {
            let path = takoHome.appendingPathComponent("quiet.json")
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        refreshKeepsAwake()
        apply()
        if wasHidden && !hidden { host.gooPanel.orderFront(nil) }
    }

    /// Everything that follows from quiet changing: the tape over its mouth, a hint or a held-out promise put away.
    func apply() {
        guard let goo = host.goo else { return }
        let was = goo.silenced, now = quiet
        goo.silenced = now
        if now {
            host.teaching.hide()
            goo.handHovered = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            goo.drawHand()
            CATransaction.commit()
        }
        if was && !now { goo.oopsUntil = goo.clock + 0.5; goo.kick(30); host.entrusted.noteChatActivity() }
        if hidden { host.gooPanel.orderOut(nil) }
        if now && host.entrusted.offerID != nil { host.entrusted.offerID = nil; goo.takeHandBack("ignored") }
        if was != now { host.entrusted.wake() }
        host.wakeLoop()
        rewatch()
    }

    // MARK: the front app keeping the display awake

    /// Right before a decision that hangs on it: the display check again if it is more than a moment old.
    func freshen() {
        guard !host.selfTest, CACurrentMediaTime() - keepsAwakeAt > 2 else { return }
        let before = keepsAwake
        refreshKeepsAwake()
        if before != keepsAwake { apply() }
    }

    private func refreshKeepsAwake() {
        keepsAwakeAt = CACurrentMediaTime()
        keepsAwake = Self.hasPresentationAssertion()
    }

    static func hasPresentationAssertion() -> Bool {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let entries = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return entries.contains { process, assertions in
            assertions.contains { row in
                // On is 255 (kIOPMAssertionLevelOn), never 1: comparing with 1 meant this check answered no for every assertion.
                guard (row[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn) else { return false }
                let kind = row[kIOPMAssertionTypeKey as String] as? String ?? ""
                let name = row[kIOPMAssertionNameKey as String] as? String ?? ""
                return AttentionPolicy.sharesScreen(assertion: name) ||
                    (process.int32Value == pid && [kIOPMAssertPreventUserIdleDisplaySleep as String, kIOPMAssertionTypeNoDisplaySleep as String].contains(kind))
            }
        }
    }

    /// The display check has no notice of its own: while a promise is held it is made now and then (every few seconds while
    /// one is being held out, so its words go away if a presentation starts), and the held promises looked at again with it,
    /// for a title that changed without the app saying so. Nothing held, no timer at all.
    func rewatch() {
        let items = !(host.entrusted.items.isEmpty)
        let every: Double? = host.entrusted.offerID != nil || host.goo?.handHovered == true ? 3 : items ? 30 : nil
        watch?.cancel(); watch = nil
        if let every {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(Int(every * 200)))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let before = self.keepsAwake
                self.refreshKeepsAwake()
                if before != self.keepsAwake { self.apply() }
                self.host.entrusted.wake()
            }
            timer.resume()
            watch = timer
        }
        watchAway()
    }

    // MARK: microphone and cameras

    private func listenToMicrophone() {
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, DispatchQueue.main) { [weak self] _, _ in self?.followInputDevice() }
        followInputDevice()
    }

    private static var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private lazy var micChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }

    private func followInputDevice() {
        var input = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &input) == noErr else { return }
        if input != inputDevice {
            if inputDevice != 0 { AudioObjectRemovePropertyListenerBlock(inputDevice, &Self.running, DispatchQueue.main, micChanged) }
            inputDevice = input
            if input != 0 { AudioObjectAddPropertyListenerBlock(input, &Self.running, DispatchQueue.main, micChanged) }
        }
        devicesChanged()
    }

    private func listenToCameras() {
        var devices = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devices, DispatchQueue.main) { [weak self] _, _ in self?.followCameras() }
        followCameras()
    }

    private static var cameraRunning = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private lazy var cameraChanged: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }

    private func followCameras() {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var bytes: UInt32 = 0
        var found: [CMIODeviceID] = []
        if CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &bytes) == noErr, bytes > 0 {
            var list = [CMIODeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<CMIODeviceID>.size)
            var used: UInt32 = 0
            if list.withUnsafeMutableBytes({ CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, bytes, &used, $0.baseAddress!) }) == noErr { found = list }
        }
        for device in cameras where !found.contains(device) { CMIOObjectRemovePropertyListenerBlock(device, &Self.cameraRunning, DispatchQueue.main, cameraChanged) }
        for device in found where !cameras.contains(device) { CMIOObjectAddPropertyListenerBlock(device, &Self.cameraRunning, DispatchQueue.main, cameraChanged) }
        cameras = found
        devicesChanged()
    }

    /// A device starting or stopping: read after a moment, so Tako's own listening starting up is already counted as its own.
    private func devicesChanged() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = (self.microphone, self.camera)
            self.microphone = self.micRunning()
            self.camera = self.cameras.contains { Self.cameraIsRunning($0) }
            if before != (self.microphone, self.camera) { self.apply() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func micRunning() -> Bool {
        guard inputDevice != 0 else { return false }
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(inputDevice, &Self.running, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func cameraIsRunning(_ device: CMIODeviceID) -> Bool {
        var running: UInt32 = 0, count: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &cameraRunning, 0, nil, UInt32(MemoryLayout<UInt32>.size), &count, &running) == noErr && running != 0
    }

    // MARK: the window in front

    /// Full screen, or a borderless window covering a whole display (games, presentations), or nothing readable at all.
    func frontIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else { return true }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return true }
        let window = value as! AXUIElement
        return fullScreen(window, frame: host.axFrame(window))
    }

    func fullScreen(_ window: AXUIElement, frame: CGRect?) -> Bool {
        var full = host.fullScreenFlag(window) ?? false
        // Borderless games and presentations do not necessarily expose AXFullScreen.
        if let frame, let primary = NSScreen.screens.first {
            full = full || NSScreen.screens.contains { screen in
                let f = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
                return abs(frame.minX - f.minX) < 3 && abs(frame.minY - f.minY) < 3 && frame.width >= f.width - 3 && frame.height >= f.height - 3
            }
        }
        return full || frame == nil   // An inaccessible game/presentation is not evidence that it is safe to interrupt.
    }

    // MARK: away and back

    /// The owner's own input, as the event listeners see it.
    func noteInput() {
        lastInput = CACurrentMediaTime()
        guard away else { return }
        away = false
        returnedFor = ["entrusted", "teaching"]
        host.entrusted.wake()
        host.teaching.check()
        watchAway()
    }

    /// Back from being away, once for each who asks.
    func takeReturned(_ who: String) -> Bool { returnedFor.remove(who) != nil }

    private func wentAway() {
        guard !away else { return }
        away = true
        host.entrusted.wake()
        returnedFor = []
        awayCheck?.cancel(); awayCheck = nil
    }

    /// Being away is only worth knowing while there is something to hand back or a hint still to show today.
    private func watchAway() {
        let wanted = !host.entrusted.items.isEmpty || host.teaching.pendingToday
        guard wanted, !away else { awayCheck?.cancel(); awayCheck = nil; return }
        guard awayCheck == nil else { return }
        let idle = Self.idleSeconds()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, Self.awayAfter - idle), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.awayCheck?.cancel(); self.awayCheck = nil
            if Self.idleSeconds() >= Self.awayAfter { self.wentAway() }
            self.watchAway()
        }
        timer.resume()
        awayCheck = timer
    }
}
