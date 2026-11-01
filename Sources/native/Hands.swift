// What TAKO can do to a window on request from the server: fill its input, point at something, run a
// script in its app, reopen a document, and take on its look. Filling only ever pastes; it never
// posts Return and never clicks a send button: that is the owner's. General operation is in Operate.swift.
import ApplicationServices
import AppKit
import ScreenCaptureKit
import Vision
import WebKit

/// The side window's web view, which also takes files dropped on it, by path.
final class TakoWeb: WKWebView {
    weak var owner: Controller?
    // The panel never activates its app, so a press on it is often the "first" one. It must not be spent on nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return super.draggingEntered(sender)
        }
        evaluateJavaScript("setDropping(true)")
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        evaluateJavaScript("setDropping(false)")
        super.draggingExited(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        evaluateJavaScript("setDropping(false)")
        return owner?.takeFiles(sender) ?? false
    }
}

enum Hands {
    static func capture(windowID: Int, size: CGSize, scale: CGFloat, source: CGRect? = nil) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else { return nil }
            let config = SCStreamConfiguration()
            if let source { config.sourceRect = source }
            // The window's size now, not the one asked for: it may have just been resized, and the rest of the picture would come out black.
            let area = source?.size ?? window.frame.size
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        } catch {
            return nil
        }
    }

    /// The window as it looks with its own menus and pop-ups, which are separate windows; other apps don't get in the picture.
    static func captureLive(_ win: Win, scale: CGFloat, source: CGRect? = nil) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.processID == win.pid }
            guard !windows.isEmpty, let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: win.frame.midX, y: win.frame.midY)) }) ?? content.displays.first else { return nil }
            let area = source ?? CGRect(origin: .zero, size: win.frame.size)
            let config = SCStreamConfiguration()
            config.sourceRect = area.offsetBy(dx: win.frame.minX - display.frame.minX, dy: win.frame.minY - display.frame.minY)
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: windows), configuration: config)
        } catch {
            return nil
        }
    }

    /// Text and where it is, with the box in window coordinates (y down).
    static func recognize(_ image: CGImage, size: CGSize) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { o in
            guard let top = o.topCandidates(1).first else { return nil }
            let b = o.boundingBox
            return (top.string, CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height))
        }.sorted { abs($0.box.minY - $1.box.minY) < 6 ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY }
    }

    static func jpeg(_ image: CGImage, scale: CGFloat = 1, quality: CGFloat) -> String? {
        var picture = image
        if scale < 1, let context = CGContext(data: nil, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            picture = context.makeImage() ?? image
        }
        return NSBitmapImageRep(cgImage: picture).representation(using: .jpeg, properties: [.compressionFactor: quality])?.base64EncodedString()
    }

    static func normalize(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber }).lowercased()
    }
}

extension Controller {
    func takeFiles(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return attach(urls.map(\.path))
    }

    @discardableResult
    func attach(_ paths: [String]) -> Bool {
        guard !paths.isEmpty, let data = try? JSONSerialization.data(withJSONObject: paths),
              let json = String(data: data, encoding: .utf8) else { return false }
        web.evaluateJavaScript("addFiles(\(json))")
        return true
    }

    /// The + in the panel. The open panel needs TAKO in front for a moment; the owner's app comes back after.
    func pickFiles() {
        let before = NSWorkspace.shared.frontmostApplication
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.prompt = "添加"
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] answer in
            before?.activate()
            guard let self else { return }
            self.side.makeKey()
            if answer == .OK { self.attach(open.urls.map(\.path)) }
        }
    }

    func openFile(_ path: String) {
        // A click on a file in the panel opens documents; nothing the model names gets to run.
        let url = URL(fileURLWithPath: path)
        let running: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "pkg", "mpkg", "dmg", "terminal", "scpt", "scptd", "applescript", "workflow", "py", "jar", "action"]
        if running.contains(url.pathExtension.lowercased()) || FileManager.default.isExecutableFile(atPath: path) && url.pathExtension.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func post(path: String, body: [String: Any]?, done: ((Data?) -> Void)? = nil) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = path
        guard let endpoint = parts.url else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 40)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in done?(data) }.resume()
    }

    func reportStuck(title: String) {
        let key = "\(target?.id ?? 0)|\(title)"
        guard key != lastReported else { return }
        lastReported = key
        post(path: "/stuck", body: ["app": appName, "bundle": bundle, "title": title, "id": "\(target?.id ?? 0)"])
    }

    // MARK: commands from the server

    func pollCommands() {
        post(path: "/native/next", body: nil) { [weak self] data in
            let command = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                if let id = command["id"] as? String {
                    Task { @MainActor in
                        let result = await self.run(command)
                        self.post(path: "/native/result", body: ["id": id, "result": result])
                    }
                }
                // A failed poll means the server is restarting: don't spin.
                DispatchQueue.main.asyncAfter(deadline: .now() + (data == nil ? 1 : 0.01)) { self.pollCommands() }
            }
        }
    }

    @MainActor
    func run(_ command: [String: Any]) async -> [String: Any] {
        let name = command["command"] as? String
        if name == "windows" { return listWindows() }
        if name == "endSteps" { endSteps(); return ["ok": true] }
        if name == "listenStop" { stopListening(); return ["ok": true] }
        if name == "closeDocument" { return await closeDocument(command["document"] as? String ?? "") }
        if name == "openDocument" { return openDocument(command["document"] as? String ?? "", in: command["app"] as? String) }
        guard let win = await resolve(command["window"] as? String) else {
            return ["ok": false, "error": (command["window"] as? String).map { "没找到窗口“\($0)”，它可能没打开" } ?? "TAKO 现在没有粘在窗口上"]
        }
        switch name {
        case "resolve": return ["ok": true, "id": win.id, "app": win.app, "bundle": win.bundle, "title": win.title, "stuck": win.id == target?.id]
        case "look": return await look(win)
        case "listenStart": return await startListening(win)
        case "titles": return await titles(win)
        case "fill": return await fill(win, text: command["text"] as? String ?? "", files: command["files"] as? [String] ?? [])
        case "point": return await point(win, at: command["text"] as? String ?? "")
        case "script": return await script(command["script"] as? String ?? "")
        case "openChat": return await openChat(command["name"] as? String ?? "", in: win)
        case "beginSteps": await beginSteps(win); return ["ok": true]
        case "step": return await step(command["step"] as? [String: Any] ?? [:], in: win, confirmed: command["confirmed"] as? Bool ?? false)
        default: return ["ok": false, "error": "unknown command"]
        }
    }

    // MARK: looking

    /// The file this window has open: the app says so, or the title names a file the app holds open.
    @MainActor
    func documentPath(_ win: Win) async -> String? {
        if win.bundle == "com.apple.finder" {
            // A Finder window only shows a folder's name; two folders can share it, so the path has to come from Finder.
            let title = currentTitle(id: win.id).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let result = await script("tell application \"Finder\"\nrepeat with w in Finder windows\nif name of w is \"\(title)\" then return POSIX path of (target of w as alias)\nend repeat\nend tell")
            let path = (result["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasPrefix("/") ? path : nil
        }
        if trusted, let window = axWindow(pid: win.pid, frame: win.frame) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
               let text = value as? String, let found = URL(string: text)?.path ?? Optional(text), found.hasPrefix("/") {
                return found
            }
        }
        let title = currentTitle(id: win.id)
        guard !title.isEmpty, title.contains(".") else { return nil }
        // A browser tab named after a website gets here too; lsof can take a while and the goo must keep moving.
        let pid = win.pid
        return await Task.detached { Controller.openFile(of: pid, named: title) }.value
    }

    nonisolated static func openFile(of pid: pid_t, named title: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)", "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        // lsof spells anything outside ASCII as \xHH.
        var bytes: [UInt8] = []
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x5C, i + 3 < data.endIndex, data[i + 1] == 0x78,
               let value = UInt8(String(decoding: data[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                bytes.append(value)
                i += 4
            } else {
                bytes.append(data[i])
                i += 1
            }
        }
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        return lines.first { $0.hasPrefix("n/") && $0.hasSuffix("/" + title) }.map { String($0.dropFirst()) }
    }

    // MARK: filling

    func frontTarget(_ win: Win) async {
        // The side window can hold the keyboard without being the active app: it has to let go first,
        // or what is typed for the other app lands in the panel.
        if side.isKeyWindow { side.resignKey() }
        NSRunningApplication(processIdentifier: win.pid)?.activate()
        if let window = axWindow(pid: win.pid, frame: win.frame) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        try? await Task.sleep(nanoseconds: 220_000_000)
    }

    /// Brings WeChat forward and reads what conversation it shows right now.
    @MainActor
    func titles(_ win: Win) async -> [String: Any] {
        await frontTarget(win)
        let found = await Controller.headerTitles(windowID: win.id, width: win.frame.width, previous: 0)
        return ["ok": found != nil, "lines": found?.lines ?? []]
    }

    func clickInput(of frame: CGRect) {
        // WeChat's text box fills the bottom of the chat pane; its send button and tools sit in the lowest 48 points.
        let back = cursor()
        click(at: CGPoint(x: frame.maxX - 200, y: frame.maxY - 76))
        CGWarpMouseCursorPosition(back)
    }

    /// Pastes into the window's input and leaves the cursor there. Nothing is sent.
    @MainActor
    func fill(_ win: Win, text: String, files: [String]) async -> [String: Any] {
        guard trusted else { return ["ok": false, "error": "没有辅助功能权限，填不进去"] }
        guard !blockedOwners.contains(win.app) else { return ["ok": false, "error": "这个应用不能操作"] }
        // A paste into a terminal can run what is pasted; these tools go step by step through operate_window, where the owner approves each one.
        guard !askFirstBundles.contains(win.bundle) else { return ["ok": false, "refused": true, "error": "\(win.app) 里不直接填，要用 operate_window 一步步来，用户 会逐步批准"] }
        let here = win.id == target?.id
        if here {
            goo.state = "working"
            enchant.setMood("working")
        } else {
            flash(win)
        }
        defer { web.evaluateJavaScript("gooState = ''") }
        let frame = win.frame
        let spot = CGPoint(x: frame.maxX - 200, y: frame.maxY - 76)
        // The limb gets there first; then the words land.
        if here {
            goo.reachGoal = win.isWeChat ? V(spot.x, spot.y) : V(frame.maxX - 60, frame.maxY - 70)
            goo.armArrived = false
        }
        await frontTarget(win)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid else {
            goo.reachGoal = nil
            return ["ok": false, "error": "\(win.app) 没能到最前面，没有填"]
        }
        if focusedSubrole(win.pid).subrole == "AXSecureTextField" {
            goo.reachGoal = nil
            return ["ok": false, "refused": true, "error": "这是密码框，密码由用户自己输入"]
        }
        if win.isWeChat {
            clickInput(of: frame)
            try? await Task.sleep(nanoseconds: 180_000_000)
        } else if let role = focusedRole(win.pid), !["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup", "AXScrollArea", "AXSearchField"].contains(role) {
            goo.reachGoal = nil
            if here { goo.fumble() }
            return ["ok": false, "error": "这个窗口的光标不在输入框里，先点一下输入框"]
        }
        try? await Task.sleep(nanoseconds: 260_000_000)
        await paste(text, files: files)
        if here {
            goo.spray(at: goo.reachGoal ?? goo.c, 4, speed: 90, along: V(0, 1))
            goo.reachGoal = nil
            goo.celebrate()
        }
        var seen = false
        if !text.isEmpty, win.isWeChat, let image = await Hands.capture(windowID: win.id, size: frame.size, scale: 2,
                source: CGRect(x: 0, y: frame.height - 200, width: frame.width, height: 200)) {
            let lines = await Task.detached { Hands.recognize(image, size: CGSize(width: frame.width, height: 200)) }.value
            let want = Hands.normalize(String(text.prefix(40)))
            let read = Hands.normalize(lines.map(\.text).joined())
            seen = !want.isEmpty && read.contains(String(want.prefix(6)))
        }
        return ["ok": true, "message": seen || !win.isWeChat || text.isEmpty ? "已填入，没有发送，等 用户 自己发。" : "已贴入输入框，没有发送；没从画面上认出这段字，请 用户 看一眼。"]
    }

    func focusedRole(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return nil }
        var role: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    // MARK: pointing

    @MainActor
    func point(_ win: Win, at text: String) async -> [String: Any] {
        let size = win.frame.size
        guard let image = await Hands.capture(windowID: win.id, size: size, scale: 2) else { return ["ok": false, "error": "窗口截不到"] }
        let lines = await Task.detached { Hands.recognize(image, size: size) }.value
        let want = Hands.normalize(text)
        guard !want.isEmpty else { return ["ok": false, "error": "没有要找的文字"] }
        let hit = lines.first { let line = Hands.normalize($0.text); return !line.isEmpty && (line.contains(want) || want.contains(line) && line.count >= 4) }
        guard let hit else { return ["ok": false, "error": "窗口上没找到这段文字"] }
        var box = hit.box
        // The picture is read a line at a time: when the words are only part of the line, narrow down to about where they sit.
        if let range = hit.text.range(of: text), hit.text.count > text.count {
            let total = CGFloat(hit.text.count), before = CGFloat(hit.text.distance(from: hit.text.startIndex, to: range.lowerBound))
            box = CGRect(x: box.minX + box.width * before / total - 4, y: box.minY, width: box.width * CGFloat(text.count) / total + 8, height: box.height)
        }
        let rect = box.offsetBy(dx: win.frame.minX, dy: win.frame.minY)
        guard win.id == target?.id else {
            flash(win)
            inkFlash.tap(at: CGPoint(x: rect.midX, y: rect.midY), over: win)
            return ["ok": true]
        }
        enchant.circle(rect)
        goo.reachGoal = V(rect.maxX + 14, rect.midY)
        goo.armArrived = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.goo.reachGoal = nil }
        return ["ok": true]
    }

    // MARK: documents

    /// Runs AppleScript with osascript, so a hung app can't freeze the goo. The server has checked what it talks to.
    func script(_ source: String) async -> [String: Any] {
        await Task.detached { () -> [String: Any] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            task.standardOutput = out
            task.standardError = err
            guard (try? task.run()) != nil else { return ["ok": false, "error": "osascript 启动失败"] }
            let killer = DispatchWorkItem { task.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 80, execute: killer)
            let output = out.fileHandleForReading.readDataToEndOfFile(), problem = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            killer.cancel()
            if task.terminationStatus == 0 { return ["ok": true, "output": String(decoding: output, as: UTF8.self)] }
            return ["ok": false, "error": String(decoding: problem, as: UTF8.self)]
        }.value
    }

    /// Closes the document so its file can be replaced. Refuses unless the window shows exactly this document, saved.
    @MainActor
    func closeDocument(_ path: String) async -> [String: Any] {
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Whichever window has it, whatever window the goo is on.
        guard let win = openWindows().first(where: { $0.title.contains(name) || name.hasPrefix($0.title + ".") }) else {
            // Held open with no window showing it: a tab at the back, or another app. Replacing it now would lose to its next save.
            if let holder = await Task.detached(operation: { Controller.holderOf(path) }).value { return ["ok": false, "error": "\(holder) 还开着 \(name)，先切到那个标签或关掉它，原文件没动"] }
            return ["ok": true]
        }
        let app = NSRunningApplication(processIdentifier: win.pid)?.bundleURL?.path
        if win.title.contains("*") || win.title.contains("未保存") || isEdited(win) { return ["ok": false, "error": "\(name) 有没保存的改动，先保存，原文件没动"] }
        await frontTarget(win)
        guard currentTitle(id: win.id).contains(name) || name.hasPrefix(currentTitle(id: win.id) + ".") else { return ["ok": false, "error": "窗口换了内容，没有替换"] }
        press(13, flags: .maskCommand)  // W
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let now = currentTitle(id: win.id)
            if !now.contains(name) && !name.hasPrefix(now + ".") || now.isEmpty { return ["ok": true, "app": app ?? ""] }
        }
        return ["ok": false, "error": "\(name) 没能关上，可能在等你确认保存，原文件没动"]
    }

    /// The app holding a file open, if any. lsof can take seconds, so never on the main thread.
    nonisolated static func holderOf(_ path: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-F", "c", "--", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }

    func isEdited(_ win: Win) -> Bool {
        guard trusted, let window = axWindow(pid: win.pid, frame: win.frame) else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXEdited" as CFString, &value) == .success && (value as? Bool) == true
    }

    func openDocument(_ path: String, in appPath: String?) -> [String: Any] {
        let file = URL(fileURLWithPath: path)
        if let appPath, !appPath.isEmpty {
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
        return ["ok": true]
    }

    // MARK: the panel takes after the window

    /// Reads the window's own material off its picture: paper, title bar, dark or light. Pixels stay in this function.
    func sampleSkin() {
        guard !skinBusy, let current = target, goo.mode == .attached || goo.mode == .open, CGPreflightScreenCaptureAccess() else { return }
        // Just resized for the panel: its picture may not have caught up yet.
        let settling = 0.5 - (CACurrentMediaTime() - ownMoveAt)
        if settling > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + settling) { [weak self] in self?.sampleSkin() }
            return
        }
        skinBusy = true
        let id = current.id, size = current.frame.size
        Task.detached { [weak self] in
            let image = await Hands.capture(windowID: id, size: size, scale: 0.5)
            let skin = image.flatMap { Skin(image: $0, height: size.height) }
            await MainActor.run {
                guard let self else { return }
                self.skinBusy = false
                guard let skin else { return }
                self.goo.onDark = skin.dark
                self.barHeight = skin.barHeight
                let color: ([Int]) -> String = { "[\($0[0]),\($0[1]),\($0[2])]" }
                self.web.evaluateJavaScript("setSkin({paper:\(color(skin.paper)),bar:\(color(skin.bar)),dark:\(skin.dark),barHeight:\(Int(skin.barHeight)),corner:11})")
            }
        }
    }
}

struct Skin {
    var paper: [Int], bar: [Int], dark: Bool, barHeight: CGFloat

    init?(image: CGImage, height: CGFloat) {
        let w = image.width, h = image.height
        guard w > 40, h > 40, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Row 0 of the bitmap is the top of the picture: this context stores rows top-down.
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let at = (y * w + x) * 4
            return [Int(raw[at]), Int(raw[at + 1]), Int(raw[at + 2])]
        }
        /// The commonest colour in a run of pixels, near enough.
        func commonest(_ points: [(Int, Int)]) -> [Int] {
            var counts: [Int: (Int, [Int])] = [:]
            for (x, y) in points {
                let c = pixel(x, y)
                let key = (c[0] / 6) << 16 | (c[1] / 6) << 8 | (c[2] / 6)
                counts[key] = ((counts[key]?.0 ?? 0) + 1, c)
            }
            return counts.values.max { $0.0 < $1.0 }?.1 ?? [250, 250, 250]
        }
        func far(_ a: [Int], _ b: [Int]) -> Bool { abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > 15 }
        // Only the far right of the window: that is what the panel will sit against.
        let columns = Array(stride(from: w * 3 / 4, to: w - 8, by: max(1, w / 120)))
        let barRow = max(4, Int(CGFloat(h) * 8 / height))
        let top = commonest(columns.map { ($0, barRow) })
        // The title bar ends where the row's commonest colour stops being the bar's.
        var end = 0
        for y in stride(from: barRow, to: min(h, Int(CGFloat(h) * 96 / height)), by: 1) {
            if far(commonest(columns.map { ($0, y) }), top) { end = y; break }
        }
        let measured = CGFloat(end) * height / CGFloat(h)
        barHeight = measured >= 30 ? min(88, measured) : 52
        var body: [(Int, Int)] = []
        for x in stride(from: w - 2 - w / 40, to: w - 2, by: 1) {
            for y in stride(from: h / 5, to: h - 8, by: max(1, h / 60)) { body.append((x, y)) }
        }
        paper = Skin.calm(commonest(body))
        bar = Skin.calm(top)
        let light = (paper[0] * 299 + paper[1] * 587 + paper[2] * 114) / 1000
        dark = light < 120
        // Dark paper must stay readable: the panel never goes as bright as mid-grey on a dark window, or the reverse.
        if !dark && light < 200 { paper = [244, 244, 243]; bar = paper }
        if dark && light > 70 { paper = [38, 38, 40]; bar = paper }
        // A bar much lighter or darker than the paper (Docker's blue) would lose the text on it.
        let barLight = (bar[0] * 299 + bar[1] * 587 + bar[2] * 114) / 1000
        if abs(barLight - (paper[0] * 299 + paper[1] * 587 + paper[2] * 114) / 1000) > 28 { bar = paper }
    }

    /// A panel can take a window's greys and soft tints, not its loud colours.
    static func calm(_ c: [Int]) -> [Int] {
        let high = c.max() ?? 0, low = c.min() ?? 0
        guard high - low > 26 else { return c }
        let grey = (c[0] + c[1] + c[2]) / 3
        return c.map { grey + ($0 - grey) * 2 / 10 }
    }
}
