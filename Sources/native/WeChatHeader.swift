// Which conversation WeChat is showing, read off the top strip of its window.
import AppKit
import ScreenCaptureKit
import Vision

extension Controller {
    // MARK: which conversation is open
    //
    // WeChat exposes nothing through Accessibility, so the only thing read is the top strip of its
    // window, on this Mac, and only the title in it leaves this function. The chat itself is never captured
    // unless the owner asks it to look.
    func readHeaderIfDue() {
        // Any other window: its title is all that changes, and the system already tells us that.
        if !isWeChat, (goo.mode == .attached || goo.mode == .open), let id = target?.id, ticks % 120 == 0,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first {
            reportStuck(title: info[kCGWindowName as String] as? String ?? "")
        }
        // The title only changes while WeChat is in use; but always read once right after sticking on.
        guard isWeChat, goo.mode == .attached || goo.mode == .open, !headerBusy, let current = target,
              lastBand == 0 || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        if !canCapture {
            canCapture = CGPreflightScreenCaptureAccess()
            if !canCapture {
                if !captureAsked {
                    captureAsked = true
                    log("screen capture trusted=false")
                    _ = CGRequestScreenCaptureAccess()
                    web.evaluateJavaScript("setCanRead(false)")
                }
                return
            }
            log("screen capture trusted=true")
            web.evaluateJavaScript("setCanRead(true)")
        }
        headerBusy = true
        let id = current.id, width = current.frame.width
        Task.detached { [weak self] in
            let titles = await Controller.headerTitles(windowID: id, width: width, previous: self?.lastBand ?? 0)
            await MainActor.run {
                guard let self else { return }
                self.headerBusy = false
                if let titles {
                    self.lastBand = titles.band
                    self.log("header changed, \(titles.lines.count) lines")
                    if !titles.lines.isEmpty { self.sendHeader(titles.lines) }
                }
            }
        }
    }

    static func headerTitles(windowID: Int, width: CGFloat, previous: Int) async -> (band: Int, lines: [String])? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: width, height: 62)
            config.width = Int(width * 2)
            config.height = 124
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard let bytes = image.dataProvider?.data as Data? else { return nil }
            // Data's own hash only looks at its first bytes, which never change here: hash all of it.
            let band = bytes.withUnsafeBytes { raw -> Int in
                var value: UInt64 = 14695981039346656037
                for byte in raw { value = (value ^ UInt64(byte)) &* 1099511628211 }
                return Int(truncatingIfNeeded: value)
            }
            if band == previous { return nil }   // nothing changed up there: no need to read it again

            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results ?? []).compactMap { o in
                o.topCandidates(1).first.map { (x: o.boundingBox.minX, right: o.boundingBox.maxX, text: $0.string) }
            }
            // Everything left of the end of the search box is the chat list, not the title.
            let listEnd = found.first(where: { $0.text.contains("搜索") })?.right ?? 0
            let lines = found.filter { $0.x > listEnd && !$0.text.contains("搜索") }
                .sorted { $0.text.count > $1.text.count }.map(\.text)
            return (band, lines)
        } catch {
            return nil
        }
    }

    func sendHeader(_ lines: [String]) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/current"
        guard let endpoint = parts.url, let body = try? JSONSerialization.data(withJSONObject: ["titles": lines]) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    func setWatching(_ on: Bool) {
        if !on { listener?.stop(); listener = nil }  // peeled off, it stops listening too; the server files what it heard
        if on { lastBand = 0 }   // stuck back on: read the title again straight away
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/watching"
        guard let endpoint = parts.url else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"on\":\(on)}".utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
}
