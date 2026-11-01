import AppKit
import Security
import CryptoKit
import UserNotifications

/// New versions, the way an app should get them. Each release publishes a small latest.json next to its zip;
/// Tako reads it now and then, says so once, and swaps itself only when the owner presses the button.
/// Nothing is installed unless it carries the same signature as the running app, which is what keeps
/// the system permissions across updates and keeps anyone else's build out.
final class Updater: NSObject, UNUserNotificationCenterDelegate {
    static let feed = ProcessInfo.processInfo.environment["TAKO_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? URL(string: "https://github.com/JoeSangAI/Tako/releases/latest/download/latest.json")!
    static let checkEvery: TimeInterval = 6 * 3600

    /// `python` is set on the small package: everything but the Python, usable only where that same Python is already installed.
    struct Package { let url: URL, sha256: String, python: String? }
    struct Release { let version: String, notes: String, whole: Package, small: Package? }

    weak var owner: Controller?
    private var latest: Release?
    private var shown: [String: Any]?   // what the panel should show; survives the page reloading
    private var snoozed = false
    private var progress: NSKeyValueObservation?
    private var fetching = false
    private var ready: String?          // the version already fetched, checked and waiting to be swapped in
    private var pressed = false         // the owner has asked and is watching
    private let folder = takoHome.appendingPathComponent("update")
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var menuTitle: String { latest.map { "更新到 \($0.version)…" } ?? "检查更新…" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    // ---- when ----
    func start() {
        UNUserNotificationCenter.current().delegate = self
        announceIfJustUpdated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(quietly: true) }
        Timer.scheduledTimer(withTimeInterval: Updater.checkEvery, repeats: true) { [weak self] _ in self?.check(quietly: true) }
    }

    func panelLoaded() { send() }

    /// The menu item. With something waiting it shows it; otherwise it asks now and reports either way.
    func showOrCheck() {
        snoozed = false
        if latest != nil { offer(); openPanel() } else { check(quietly: false) }
    }

    func check(quietly: Bool) {
        // GitHub caches the "latest" redirect for minutes; a fresh query string asks past it.
        var parts = URLComponents(url: Updater.feed, resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
        var request = URLRequest(url: parts?.url ?? Updater.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Tako/\(Updater.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async { self?.heard(data, ok: (response as? HTTPURLResponse)?.statusCode == 200, quietly: quietly) }
        }.resume()
    }

    private func heard(_ data: Data?, ok: Bool, quietly: Bool) {
        guard ok, let data, let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = found["version"] as? String, let zipText = found["zip"] as? String, let zip = URL(string: zipText),
              Updater.allowed(zip), let sha = found["sha256"] as? String else {
            // A check that fails says nothing unless someone asked; the next one is hours away anyway.
            if !quietly { show(["state": "available", "version": Updater.current, "notes": "", "error": "现在连不上更新服务器，稍后再试。"]); openPanel() }
            return
        }
        guard Updater.isNewer(version, than: Updater.current) else {
            latest = nil
            if !quietly { show(["state": "current", "version": Updater.current]); openPanel() }
            return
        }
        var small: Package?
        if let patch = found["patch"] as? [String: Any], let text = patch["zip"] as? String, let url = URL(string: text), Updater.allowed(url),
           let hash = patch["sha256"] as? String, let python = patch["python"] as? String {
            small = Package(url: url, sha256: hash, python: python)
        }
        let release = Release(version: version, notes: found["notes"] as? String ?? "", whole: Package(url: zip, sha256: sha, python: nil), small: small)
        latest = release
        offer()
        fetch(release)
        NSApp.dockTile.badgeLabel = "1"
        notifyOnce(version)
        if !quietly { openPanel() }
    }

    private static func allowed(_ url: URL) -> Bool { url.scheme == "https" || url.host == "127.0.0.1" }

    private static var pythonID: String? {
        Bundle.main.url(forResource: "python", withExtension: "id").flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- telling the owner ----
    private func offer(error: String? = nil) {
        guard let latest, !snoozed || error != nil else { return }
        var state: [String: Any] = ["state": "available", "version": latest.version, "notes": latest.notes]
        if let error { state["error"] = error }
        show(state)
    }

    private func show(_ state: [String: Any]?) {
        shown = state
        send()
    }

    private func send() {
        guard let web = owner?.web else { return }
        let json = shown.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        web.evaluateJavaScript("window.setUpdate && setUpdate(\(json))")
    }

    private func openPanel() {
        guard let owner else { return }
        if owner.sideOpen { return }
        owner.summon()
    }

    private func notifyOnce(_ version: String) {
        let key = "notifiedVersion"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "Tako \(version) 可以更新了"
            content.body = "打开看看新版本多了什么，一键就能换上。"
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.showOrCheck() }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// After a swap the new version opens once with what changed in it.
    private func announceIfJustUpdated() {
        let key = "lastRunVersion"
        let before = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(Updater.current, forKey: key)
        NSApp.dockTile.badgeLabel = nil
        guard let before else {
            // The very first launch: go to whatever is in front, so the first thing seen is what to do next.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openPanel() }
            return
        }
        guard Updater.isNewer(Updater.current, than: before) else { return }
        show(["state": "updated", "version": Updater.current, "notes": Updater.changes(since: before)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.openPanel() }
    }

    /// The sections of the bundled CHANGELOG.md newer than the version it came from.
    static func changes(since version: String) -> String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var sections: [(name: String, lines: [String])] = [], keeping = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let name = line.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                keeping = isNewer(name, than: version)
                if keeping { sections.append((name, [])) }
            } else if keeping {
                sections[sections.count - 1].lines.append(line)
            }
        }
        // The card already names the version; only several in a row need their own headings.
        return sections.map { (sections.count > 1 ? "### \($0.name)\n" : "") + $0.lines.joined(separator: "\n") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- what the panel asked for ----
    func act(_ action: String) {
        switch action {
        case "later": snoozed = true; show(nil)
        case "dismiss": show(nil)
        case "install": install()
        default: break
        }
    }

    // ---- the swap ----
    /// The button. Usually everything is already here and only the swap is left.
    private func install() {
        guard let latest else { return }
        pressed = true
        if ready == latest.version { return swap(version: latest.version) }
        show(["state": "downloading", "version": latest.version, "progress": 0.0])
        fetch(latest)
    }

    /// As soon as a new version is known it is fetched and checked quietly, the way other apps do it.
    private func fetch(_ release: Release) {
        guard !fetching, ready != release.version else { return }
        fetching = true
        let small = release.small.flatMap { $0.python == Updater.pythonID ? $0 : nil }
        download(small ?? release.whole, of: release)
    }

    private func download(_ package: Package, of release: Release) {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = URLSession.shared.downloadTask(with: package.url) { [weak self] file, _, error in
            guard let self else { return }
            let kept = self.folder.appendingPathComponent("Tako.zip")
            let problem = file != nil && error == nil && (try? FileManager.default.moveItem(at: file!, to: kept)) != nil
                ? self.prepare(kept, package) : "下载没有完成，检查网络后再试一次。"
            DispatchQueue.main.async { self.fetched(package, of: release, problem: problem) }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] seen, _ in
            DispatchQueue.main.async {
                guard let self, self.pressed, self.shown?["state"] as? String == "downloading" else { return }
                self.show(["state": "downloading", "version": release.version, "progress": seen.fractionCompleted])
            }
        }
        task.resume()
    }

    private func fetched(_ package: Package, of release: Release, problem: String?) {
        // The small package didn't come together: the whole one doesn't depend on anything here.
        if problem != nil, package.python != nil { return download(release.whole, of: release) }
        fetching = false
        if let problem {
            if pressed { failed(problem) }
            return
        }
        ready = release.version
        if pressed { install() }
    }

    private func failed(_ reason: String) {
        pressed = false
        offer(error: reason)
        if latest == nil { show(nil) }
    }

    /// Off the main thread. Returns what went wrong, in words for the panel.
    private func prepare(_ zip: URL, _ package: Package) -> String? {
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { return "下载的文件读不出来，再试一次。" }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == package.sha256.lowercased() else { return "下载的文件不完整，再试一次。" }
        let unpacked = folder.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { return "解压失败，再试一次。" }
        let app = unpacked.appendingPathComponent("Tako.app")
        if package.python != nil {
            // Cloned, so it costs neither time nor disk. The signature check below covers every file of it.
            let mine = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python")
            guard run("/bin/cp", ["-Rc", mine.path, app.appendingPathComponent("Contents/Resources/python").path]) else { return "解压失败，再试一次。" }
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard sameSignature(app) else { return "这个版本的签名和正在运行的不一致，没有安装。自己编译的 Tako 请用 git pull 更新。" }
        return nil
    }

    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// The new app must satisfy the requirement the running app was signed under.
    private func sameSignature(_ app: URL) -> Bool {
        var running: SecCode?, requirement: SecRequirement?, candidate: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return false }
        var mine: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(candidate, strict, requirement) == errSecSuccess
    }

    /// A small script outlives the app, swaps the bundles, and opens the new one. If the swap fails the old app comes back.
    private func swap(version: String) {
        let unpacked = folder.appendingPathComponent("unpacked/Tako.app").path
        let installed = Bundle.main.bundleURL.path
        let previous = takoHome.appendingPathComponent("previous-version.app").path
        let script = """
        #!/bin/sh
        pid="$1"; old="$2"; new="$3"; keep="$4"
        for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        kill -9 "$pid" 2>/dev/null
        rm -rf "$keep"
        if mv "$old" "$keep"; then
          if ! mv "$new" "$old"; then mv "$keep" "$old"; fi
        fi
        open "$old"
        rm -rf "$(dirname "$0")"
        """
        let file = folder.appendingPathComponent("swap.sh")
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil,
              FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            return failed("没有权限替换 \(installed)。把 Tako 放回“应用程序”后再试。")
        }
        show(["state": "installing", "version": version])
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [file.path, "\(getpid())", installed, unpacked, previous]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return failed("没能开始安装，再试一次。") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}
