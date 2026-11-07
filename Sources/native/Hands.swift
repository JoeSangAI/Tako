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

    /// ScreenCaptureKit never answers for a minimized window or a hidden app's (seen 2026-11-02), and the whole tool call would wait for it.
    static func shot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async -> CGImage? {
        await withCheckedContinuation { (done: CheckedContinuation<CGImage?, Never>) in
            let lock = NSLock()
            var answered = false
            let answer: (CGImage?) -> Void = { image in
                lock.lock()
                defer { lock.unlock() }
                guard !answered else { return }
                answered = true
                done.resume(returning: image)
            }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in answer(image) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { answer(nil) }
        }
    }

    /// The window as it looks with its own menus and pop-ups, which are separate windows; other apps don't get in the picture.
    static func captureLive(_ win: Win, scale: CGFloat, source: CGRect? = nil) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let only = content.windows.first(where: { Int($0.windowID) == win.id }), !only.isOnScreen {
                // On another desktop or hidden: this window alone can still be drawn.
                let area = source ?? CGRect(origin: .zero, size: win.frame.size)
                let config = SCStreamConfiguration()
                config.sourceRect = area
                config.width = Int(area.width * scale)
                config.height = Int(area.height * scale)
                config.showsCursor = false
                return await shot(SCContentFilter(desktopIndependentWindow: only), config)
            }
            // Its own menus and sheets, not the app's other windows, which may lie in front of this one.
            let windows = content.windows.filter {
                $0.owningApplication?.processID == win.pid && $0.isOnScreen && (Int($0.windowID) == win.id || $0.windowLayer != 0 || win.frame.contains($0.frame) && $0.frame.size != win.frame.size)
            }
            guard !windows.isEmpty, let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: win.frame.midX, y: win.frame.midY)) }) ?? content.displays.first else { return nil }
            let area = source ?? CGRect(origin: .zero, size: win.frame.size)
            let config = SCStreamConfiguration()
            config.sourceRect = area.offsetBy(dx: win.frame.minX - display.frame.minX, dy: win.frame.minY - display.frame.minY)
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
            config.showsCursor = false
            return await shot(SCContentFilter(display: display, including: windows), config)
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

    /// Where these words are among lines read off a picture: inside one line, or running over a few. `forgiving` lets about one character in five differ, never a number.
    static func place(of text: String, in lines: [(text: String, box: CGRect)], forgiving: Bool = false) -> CGRect? {
        let want = normalize(text)
        guard !want.isEmpty else { return nil }
        let plain = lines.map { normalize($0.text) }
        // Ending as early and starting as late as it can: the ring goes round these words, not the lines above them.
        for end in lines.indices {
            var joined = "", box = lines[end].box
            for start in stride(from: end, through: max(0, end - 5), by: -1) {
                joined = plain[start] + joined
                box = box.union(lines[start].box)
                guard forgiving ? (want.count >= 4 && closeEnough(want, within: joined)) : joined.contains(want) else { continue }
                // One line and only part of it: narrow down to about where the words sit.
                if start == end, let range = lines[end].text.range(of: text), lines[end].text.count > text.count {
                    let total = CGFloat(lines[end].text.count), before = CGFloat(lines[end].text.distance(from: lines[end].text.startIndex, to: range.lowerBound))
                    return CGRect(x: box.minX + box.width * before / total - 4, y: box.minY, width: box.width * CGFloat(text.count) / total + 8, height: box.height)
                }
                return box
            }
        }
        // Asked about a whole passage, and the picture shows a line of it.
        return forgiving ? nil : zip(plain, lines).filter { $0.0.count >= 4 && want.contains($0.0) }.max { $0.0.count < $1.0.count }?.1.box
    }

    /// Whether the words appear somewhere in the text with few enough differences (the smallest edit distance to any stretch of it), their numbers intact.
    static func closeEnough(_ want: String, within text: String) -> Bool {
        let digits = { (words: String) in words.filter(\.isNumber) }
        guard digits(text).contains(digits(want)) || digits(want).isEmpty else { return false }
        let a = Array(want), b = Array(text)
        var column = Array(0...a.count)
        var best = column[a.count]
        for character in b {
            var previous = column[0]
            column[0] = 0
            for i in 1...a.count {
                let held = column[i]
                column[i] = min(held + 1, column[i - 1] + 1, previous + (a[i - 1] == character ? 0 : 1))
                previous = held
            }
            best = min(best, column[a.count])
        }
        return best * 5 <= a.count
    }

    /// The lines most like what was asked for, for saying what is there instead.
    static func nearest(to want: String, in lines: [(text: String, box: CGRect)]) -> [String] {
        let wanted = Set(want)
        let scored: [(text: String, shared: Int)] = lines.map { ($0.text, Set(normalize($0.text)).intersection(wanted).count) }
        let likely = scored.filter { $0.shared * 2 >= min(wanted.count, 8) }.sorted { $0.shared > $1.shared }
        return likely.prefix(3).map { String($0.text.prefix(40)) }
    }

    /// A chat by its full name or its short one: 小林 is 小林-市场 助理, because the name stops at a break there, but it is not 小林妈妈.
    static func sameChat(_ want: String, _ line: String) -> Bool {
        if !normalize(want).isEmpty, normalize(want) == normalize(line) { return true }
        let tidy = { (text: String) in text.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespaces) }
        let start = tidy(want), whole = tidy(line)
        guard !start.isEmpty, whole.hasPrefix(start), let next = whole.dropFirst(start.count).first else { return false }
        return !(next.isLetter || next.isNumber)
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
        if name == "followDone" { followDone(); return ["ok": true] }
        if name == "listenStop" { stopListening(); return ["ok": true] }
        if name == "closeDocument" { return await closeDocument(command["document"] as? String ?? "", onlyIfHeld: command["held"] as? Bool ?? false) }
        if name == "openDocument" { return openDocument(command["document"] as? String ?? "", in: command["app"] as? String) }
        guard let win = await resolve(command["window"] as? String) else {
            return ["ok": false, "error": (command["window"] as? String).map { "没找到窗口“\($0)”，它可能没打开" } ?? "TAKO 现在没有粘在窗口上"]
        }
        switch name {
        case "about": return await about(win)
        case "resolve":
            let frame = ["x": win.frame.minX, "y": win.frame.minY, "w": win.frame.width, "h": win.frame.height]
            return ["ok": true, "id": win.id, "app": win.app, "bundle": win.bundle, "title": win.title, "frame": frame, "stuck": win.id == target?.id]
        case "look": return await look(win)
        case "listenStart": return await startListening(win)
        case "titles": return await titles(win)
        case "fill": return await fill(win, text: command["text"] as? String ?? "", files: command["files"] as? [String] ?? [])
        case "point": return await point(win, at: command["text"] as? String ?? "")
        case "script": return await script(command["script"] as? String ?? "", to: command["bundle"] as? String, within: command["within"] as? Double ?? 80)
        case "closeFileChooser": return closeFileChooser(win)
        case "openChat": return await openChat(command["name"] as? String ?? "", in: win)
        case "isBack":
            // Their words going into the panel: the input box is about to be clicked out from under them.
            let typing = side.isKeyWindow && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 3
            return ["ok": ownerIsAway(from: win) && !typing, "front": isFront(win) && !coveredByItsOwn(win), "app": win.app]
        case "followTo": return followTo(win)
        case "bringForward":
            // Only ever for a button the owner pressed: everything else works without being in front.
            if side.isKeyWindow { side.resignKey() }
            NSRunningApplication(processIdentifier: win.pid)?.activate()
            if let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["ok": true]
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
            // By where it sits too: two windows can show folders of one name. Short: the first time this is the system asking the owner, and nothing waits for that.
            let result = await script("tell application \"Finder\"\nrepeat with i from 1 to count of Finder windows\nset w to Finder window i\nset b to bounds of w\nif name of w is \"\(title)\" and item 1 of b is \(Int(win.frame.minX)) and item 2 of b is \(Int(win.frame.minY)) then return POSIX path of (target of w as alias)\nend repeat\nend tell", within: 3)
            let path = (result["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return path }
            // Finder said no (nobody has allowed Tako to ask it). Spotlight knows folders by name without that, and what the window lists tells apart folders of one name.
            let listed = Controller.finderRows(win, axWindow(pid: win.pid, frame: win.frame, id: win.id)).map(\.name)
            return await Task.detached { Controller.onlyFolder(named: title, listing: listed) }.value
        }
        if trusted, let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
               let text = value as? String, let found = URL(string: text)?.path ?? Optional(text), found.hasPrefix("/") {
                return found
            }
        }
        // WPS says "[只读]" in front of a file it opened read-only; the name of the file is what's after it.
        let title = currentTitle(id: win.id).replacingOccurrences(of: "[只读]", with: "")
        guard !title.isEmpty, title.contains(".") else { return nil }
        // A browser tab named after a website gets here too; lsof can take a while and the goo must keep moving.
        let pid = win.pid
        return await Task.detached { Controller.openFile(of: pid, named: title) }.value
    }

    /// What a Finder window lists, and which of that the owner has selected; the sidebar is the outline before it. Asked of Accessibility: it needs no permission beyond that and never disturbs them.
    static func finderRows(_ win: Win, _ window: AXUIElement?) -> [(name: String, selected: Bool)] {
        guard let window else { return [] }
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var found: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func name(of element: AXUIElement, _ depth: Int = 0) -> String? {
            if ["AXStaticText", "AXTextField"].contains(value(element, kAXRoleAttribute) as? String ?? ""), let text = value(element, kAXValueAttribute) as? String, !text.isEmpty { return text }
            guard depth < 4 else { return nil }
            return children(element).lazy.compactMap { name(of: $0, depth + 1) }.first
        }
        var content: AXUIElement?, visited = 0
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 10, visited < 400 else { return }
            visited += 1
            if ["AXOutline", "AXTable", "AXList"].contains(value(element, kAXRoleAttribute) as? String ?? "") { content = element; return }
            children(element).forEach { walk($0, depth + 1) }
        }
        walk(window, 0)
        guard let content else { return [] }
        return children(content).prefix(400).compactMap { row in
            // Rows opened out under a folder are that folder's, not this one's.
            guard ["AXRow", "AXImage", "AXGroup"].contains(value(row, kAXRoleAttribute) as? String ?? ""), (value(row, "AXDisclosureLevel") as? Int ?? 0) == 0, let found = name(of: row) else { return nil }
            return (found, value(row, kAXSelectedAttribute) as? Bool ?? false)
        }
    }

    /// The folder behind a Finder window, and what is selected in it. Anything else has nothing to say here.
    @MainActor
    func about(_ win: Win) async -> [String: Any] {
        guard win.bundle == "com.apple.finder" else { return ["ok": true] }
        var result: [String: Any] = ["ok": true]
        if let folder = await documentPath(win) { result["folder"] = folder }
        result["selected"] = Controller.finderRows(win, axWindow(pid: win.pid, frame: win.frame, id: win.id)).filter(\.selected).map(\.name)
        return result
    }

    nonisolated static func onlyFolder(named quoted: String, listing listed: [String] = []) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemFSName == \"\(quoted)\" && kMDItemContentType == \"public.folder\""]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let found = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        if found.count < 2 { return found.first }
        // Several by that name: the one holding what the window lists (nearly: Finder can hide an extension). Nothing listed, or more than one fits, is no answer.
        guard !listed.isEmpty else { return nil }
        let some = listed.prefix(30)
        let fits = found.filter { path in some.filter { FileManager.default.fileExists(atPath: path + "/" + $0) }.count * 5 >= some.count * 4 }
        return fits.count == 1 ? fits[0] : nil
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

    /// Reads what conversation WeChat shows right now, off a picture of its window.
    @MainActor
    func titles(_ win: Win) async -> [String: Any] {
        let found = await Controller.headerTitles(windowID: win.id, width: win.frame.width, previous: 0, listEnd: listEnd)
        // The reader's second guesses too: the fill decides which chat is open the same way the panel follows it.
        return ["ok": found != nil, "lines": found?.lines ?? [], "others": found?.others ?? []]
    }

    func clickInput(of frame: CGRect) {
        // WeChat's text box fills the bottom of the chat pane; its send button and tools sit in the lowest 48 points.
        let back = cursor()
        click(at: CGPoint(x: frame.maxX - 200, y: frame.maxY - 76))
        CGWarpMouseCursorPosition(back)
    }

    /// Into the window's input, the cursor left there; nothing is sent. Words go in behind the owner's back where the app allows it.
    /// WeChat's input and handing over files take the real pointer and clipboard, so they wait for the owner to be back.
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
        if isPasswordField(of: win) {
            goo.reachGoal = nil
            return ["ok": false, "refused": true, "error": "这是密码框，密码由用户自己输入"]
        }
        if !win.isWeChat, typingInto[win.id] == nil, let role = focusedRole(win.pid), !["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup", "AXScrollArea", "AXSearchField"].contains(role) {
            goo.reachGoal = nil
            if here { goo.fumble() }
            return ["ok": false, "error": "这个窗口的光标不在输入框里，先点一下输入框"]
        }
        await letTheOwnerFinishTyping(in: win)
        var inserted = false
        if !win.isWeChat, files.isEmpty { inserted = await insertBehindTheOwner(text, in: win) }
        // Nothing but the page itself has the keyboard: the words would go nowhere, in front or not, and saying they went in is the one thing this must not do.
        if !inserted, !win.isWeChat, files.isEmpty, typingInto[win.id] == nil, [nil, "AXWebArea"].contains(focusedRole(win.pid)) {
            goo.reachGoal = nil
            if here { goo.fumble() }
            return ["ok": false, "error": "这个窗口的光标不在输入框里，没有填。先用 operate_window 点一下输入框，再填一次"]
        }
        if !inserted {
            guard await ownerSettles(on: win) else {
                goo.reachGoal = nil
                return waitForFront(win)
            }
            await withRealPointer {
                if win.isWeChat {
                    clickInput(of: frame)
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
                try? await Task.sleep(nanoseconds: 260_000_000)
                await paste(text, files: files)
            }
        }
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
        let want = Hands.normalize(text)
        guard !want.isEmpty else { return ["ok": false, "error": "没有要找的文字"] }
        guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "error": "没有屏幕录制权限，看不到窗口"] }
        let size = win.frame.size
        func onThePicture() async -> [(text: String, box: CGRect)] {
            guard let image = await Hands.captureLive(win, scale: 2) else { return [] }
            return await Task.detached { Hands.recognize(image, size: size) }.value
        }
        var lines = await onThePicture()
        var box = Hands.place(of: text, in: lines)
        // Not on the picture: a page knows the words it holds further down, and can bring them into view without touching the owner's pointer.
        var heldBack = false
        if box == nil, trusted, let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) {
            await askForAccessibleContent(win)
            let origin = win.frame.origin
            var inPage = await Task.detached(operation: { Controller.wordsInPage(text, under: window) }).value
            // Asked for the first time, Chrome hands over the page's frame before its words.
            if drawsLikeChrome(win.pid) {
                for _ in 0..<4 where inPage == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    inPage = await Task.detached(operation: { Controller.wordsInPage(text, under: window) }).value
                }
            }
            if let found = inPage {
                let view = found.page ?? CGRect(origin: origin, size: size)
                let shown = { (place: CGRect) in place.height >= 1 && view.contains(CGPoint(x: place.midX, y: place.midY)) }
                // A run taller than the page comes up a stretch at a time: asking again goes further, and so does scrolling.
                for _ in 0..<10 where !shown(Controller.bounds(of: found)) {
                    AXUIElementPerformAction(found.element, "AXScrollToVisible" as CFString)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    let now = Controller.bounds(of: found)
                    if shown(now) { break }
                    _ = await scrollBehindTheOwner(at: CGPoint(x: view.midX, y: view.midY), lines: now.midY > view.midY ? -10 : 10, in: win)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                let place = Controller.bounds(of: found)
                if shown(place) {
                    lines = await onThePicture()
                    box = found.exact ? place.offsetBy(dx: -origin.x, dy: -origin.y) : Hands.place(of: text, in: lines) ?? place.offsetBy(dx: -origin.x, dy: -origin.y)
                } else {
                    heldBack = true
                }
            }
        }
        if heldBack { return ["ok": false, "error": "页面里有这段字，但滚不到它那里，没有标。用文字告诉 用户 它在页面的哪一部分"] }
        // The model read this off the same picture and may have put a misread character right.
        box = box ?? Hands.place(of: text, in: lines, forgiving: true)
        guard let box else {
            if lines.isEmpty { return ["ok": false, "error": "这个窗口现在截不到，没有标"] }
            let near = Hands.nearest(to: want, in: lines).map { "“\($0)”" }.joined(separator: "、")
            return ["ok": false, "error": "这段字不在这个窗口里，没有标" + (near.isEmpty ? "。" : "。最接近的是 \(near)，要标的是其中一句就照原样再标一次；都不是就") + "用文字告诉 用户 在哪"]
        }
        let rect = box.offsetBy(dx: win.frame.minX, dy: win.frame.minY)
        guard win.id == target?.id else {
            flash(win)
            inkFlash.tap(at: CGPoint(x: rect.midX, y: rect.midY), over: win)
            return ["ok": true, "seen": isFront(win), "at": [box.minX, box.minY, box.width, box.height]]
        }
        enchant.circle(rect)
        goo.reachGoal = V(rect.maxX + 14, rect.midY)
        goo.armArrived = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.goo.reachGoal = nil }
        return ["ok": true, "seen": isFront(win), "at": [box.minX, box.minY, box.width, box.height]]
    }

    /// The first run of a page's text holding these words, wherever on the page it is. A page splits a sentence at every link and bold word, so a few runs in a row count as one.
    nonisolated static func wordsInPage(_ text: String, under window: AXUIElement) -> (element: AXUIElement, location: Int, length: Int, exact: Bool, page: CGRect?)? {
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var found: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
        }
        let want = Hands.normalize(text)
        var runs: [(element: AXUIElement, raw: String, plain: String)] = [], visited = 0, page: CGRect?
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 40, visited < 6000 else { return }
            visited += 1
            let role = value(element, kAXRoleAttribute) as? String
            if role == "AXWebArea", page == nil {
                var at = CGPoint.zero, dimension = CGSize.zero
                if let position = value(element, kAXPositionAttribute), let extent = value(element, kAXSizeAttribute) {
                    AXValueGetValue(position as! AXValue, .cgPoint, &at)
                    AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
                    page = CGRect(origin: at, size: dimension)
                }
            }
            if role == "AXStaticText", let raw = value(element, kAXValueAttribute) as? String {
                let plain = Hands.normalize(raw)
                if !plain.isEmpty { runs.append((element, raw, plain)) }
            }
            (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).forEach { walk($0, depth + 1) }
        }
        walk(window, 0)
        for end in runs.indices {
            var joined = ""
            for start in stride(from: end, through: max(0, end - 7), by: -1) {
                joined = runs[start].plain + joined
                guard joined.contains(want) else { continue }
                let run = runs[start]
                // Asked of the words themselves where the text says them just so: nothing narrower to go on otherwise than the whole run.
                if start == end, let range = run.raw.range(of: text, options: .caseInsensitive) {
                    return (run.element, run.raw.utf16.distance(from: run.raw.startIndex, to: range.lowerBound), text.utf16.count, true, page)
                }
                return (run.element, 0, run.raw.utf16.count, false, page)
            }
        }
        return nil
    }

    /// Where these characters really are. A run's own frame won't say: Chrome cuts it down to what shows of it, so a long paragraph with its first lines on screen
    /// looks on screen whatever part of it is meant, and what is out of view lies flat against the page's edge (both seen 2026-11-02).
    nonisolated static func bounds(of found: (element: AXUIElement, location: Int, length: Int, exact: Bool, page: CGRect?)) -> CGRect {
        var range = CFRange(location: found.location, length: found.length), answer: CFTypeRef?, box = CGRect.zero
        if let asked = AXValueCreate(.cfRange, &range),
           AXUIElementCopyParameterizedAttributeValue(found.element, kAXBoundsForRangeParameterizedAttribute as CFString, asked, &answer) == .success, let answer {
            AXValueGetValue(answer as! AXValue, .cgRect, &box)
            if box.height >= 1 { return box }
        }
        var position: CFTypeRef?, extent: CFTypeRef?
        var at = CGPoint.zero, dimension = CGSize.zero
        guard AXUIElementCopyAttributeValue(found.element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(found.element, kAXSizeAttribute as CFString, &extent) == .success else { return .zero }
        AXValueGetValue(position as! AXValue, .cgPoint, &at)
        AXValueGetValue(extent as! AXValue, .cgSize, &dimension)
        return CGRect(origin: at, size: dimension)
    }

    // MARK: documents

    /// Runs AppleScript with osascript, so a hung app can't freeze the goo. The server has checked what it talks to.
    /// The first script to an app stops at the system asking the owner whether TAKO may control it, and nothing comes back until they answer
    /// (Chrome, 2026-11-04: the job waited the full limit and gave up). So that is checked first: the question goes up on its own and the job hears at once.
    func script(_ source: String, to bundle: String? = nil, within limit: Double = 80) async -> [String: Any] {
        await Task.detached { () -> [String: Any] in
            if let bundle {
                switch Controller.mayControl(bundle, asking: false) {
                case OSStatus(errAEEventWouldRequireUserConsent):
                    Controller.askToControl(bundle)
                    return ["ok": false, "consent": true, "error": "系统正在问能不能让 TAKO 控制这个应用，点了允许才行"]
                case OSStatus(errAEEventNotPermitted):
                    return ["ok": false, "denied": true, "error": "系统设置里没允许 TAKO 控制这个应用（隐私与安全性 › 自动化）"]
                default: break
                }
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // A file handed to a page goes in pieces of about 2 MB, more than one argument may hold: those come in on standard input.
            let large = source.utf8.count > 100_000
            task.arguments = large ? [] : ["-e", source]
            let out = Pipe(), err = Pipe(), input = Pipe()
            task.standardOutput = out
            task.standardError = err
            if large { task.standardInput = input }
            guard (try? task.run()) != nil else { return ["ok": false, "error": "osascript 启动失败"] }
            if large {
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
            }
            let killer = DispatchWorkItem { task.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
            let output = out.fileHandleForReading.readDataToEndOfFile(), problem = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            killer.cancel()
            if task.terminationStatus == 0 { return ["ok": true, "output": String(decoding: output, as: UTF8.self)] }
            return ["ok": false, "error": String(decoding: problem, as: UTF8.self)]
        }.value
    }

    /// The system's file chooser over a browser window (an upload button was clicked) can't be worked behind the owner's back, and
    /// Tako hands the page its files another way. It is closed with its own Cancel button, so nothing is chosen.
    @MainActor
    func closeFileChooser(_ win: Win) -> [String: Any] {
        func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil }
        func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        let choose = ["打开", "Open", "选取", "Choose", "上传", "Upload", "选择", "Select"]
        // A chooser: a sheet or dialog with a Cancel button and one to open what is chosen. Nothing else on the window is touched.
        func isChooser(_ e: AXUIElement) -> AXUIElement? {
            guard let cancel = attribute(e, kAXCancelButtonAttribute) else { return nil }
            var queue = children(e), looked = 0
            while !queue.isEmpty, looked < 400 {
                let next = queue.removeFirst()
                looked += 1
                if (attribute(next, kAXRoleAttribute) as? String) == kAXButtonRole, let title = attribute(next, kAXTitleAttribute) as? String, choose.contains(title) {
                    return (cancel as! AXUIElement)  // swiftlint:disable:this force_cast
                }
                queue += children(next)
            }
            return nil
        }
        var found: [AXUIElement] = []
        if let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) {
            found += children(window).filter { (attribute($0, kAXRoleAttribute) as? String) == "AXSheet" }
        }
        found += (attribute(AXUIElementCreateApplication(win.pid), kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (attribute($0, kAXSubroleAttribute) as? String) == "AXDialog" && ["打开", "Open"].contains(attribute($0, kAXTitleAttribute) as? String ?? "")
        }
        var closed = 0
        for chooser in found {
            if let cancel = isChooser(chooser), AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success { closed += 1 }
        }
        if closed > 0 { log("closed \(closed) file chooser(s) on \(win.app)") }
        return ["ok": true, "closed": closed]
    }

    nonisolated static func mayControl(_ bundle: String, asking: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundle.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return OSStatus(paramErr) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
    }

    nonisolated(unsafe) static var asking = Set<String>()
    static let askingLock = NSLock()
    /// Puts the system's question up once and waits for it off to the side; the next script finds the answer.
    nonisolated static func askToControl(_ bundle: String) {
        guard askingLock.withLock({ asking.insert(bundle).inserted }) else { return }
        DispatchQueue.global().async {
            _ = mayControl(bundle, asking: true)
            askingLock.withLock { _ = asking.remove(bundle) }
        }
    }

    /// Closes the document so its file can be replaced. Refuses unless the window shows exactly this document, saved.
    /// The app holding the file says which document it is and whether it has really gone: a title can't, with a copy of the same name in the next tab (seen 2026-11-02).
    @MainActor
    func closeDocument(_ path: String, onlyIfHeld: Bool = false) async -> [String: Any] {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let holder = await Task.detached(operation: { Controller.holderOf(path) }).value
        if holder == nil && onlyIfHeld { return ["ok": true] }
        let holding = holder.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        func showing(_ title: String) -> Bool { title.contains(name) || name.hasPrefix(title + ".") }
        func window() -> Win? { openWindows().first { (holding == nil || $0.pid == holding?.processIdentifier) && showing($0.title) } }
        // A tab at the back can't be closed with a key: asking the app to open it brings that very tab up.
        if let appURL = holding?.bundleURL {
            let quietly = NSWorkspace.OpenConfiguration()
            quietly.activates = false
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: quietly, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 800_000_000)
            for _ in 0..<12 where window() == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard let win = window() else {
            // Held open with no window showing it. Replacing it now would lose to its next save.
            if let holder { return ["ok": false, "error": "\(holder.name) 还开着 \(name)，先切到那个标签或关掉它，原文件没动"] }
            return ["ok": true]
        }
        let app = NSRunningApplication(processIdentifier: win.pid)?.bundleURL?.path
        if win.title.contains("*") || win.title.contains("未保存") || isEdited(win) { return ["ok": false, "error": "\(name) 有没保存的改动，先保存，原文件没动"] }
        guard keysLandIn(win) else { return waitForFront(win) }
        guard showing(currentTitle(id: win.id)) else { return ["ok": false, "error": "窗口换了内容，没有替换"] }
        press(13, flags: .maskCommand, to: win.pid)  // W
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if holder != nil {
                if await Task.detached(operation: { Controller.holderOf(path) }).value == nil { return ["ok": true, "app": app ?? ""] }
            } else {
                let now = currentTitle(id: win.id)
                if !showing(now) || now.isEmpty { return ["ok": true, "app": app ?? ""] }
            }
        }
        // It may still go a moment from now: `closing` tells the other side to bring it back rather than leave the owner without their document.
        return ["ok": false, "closing": true, "app": app ?? "", "error": "\(name) 没能关上，可能在等你确认保存，原文件没动"]
    }

    /// The app holding a file open, if any. lsof can take seconds, so never on the main thread.
    nonisolated static func holderOf(_ path: String) -> (pid: pid_t, name: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-F", "pc", "--", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let pid = lines.first(where: { $0.hasPrefix("p") }).flatMap({ pid_t($0.dropFirst()) }), let name = lines.first(where: { $0.hasPrefix("c") }) else { return nil }
        return (pid, String(name.dropFirst()))
    }

    func isEdited(_ win: Win) -> Bool {
        guard trusted, let window = axWindow(pid: win.pid, frame: win.frame, id: win.id) else { return false }
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
