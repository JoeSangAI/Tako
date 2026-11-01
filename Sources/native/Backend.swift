import AppKit

/// Everything Tako writes while running: logs, handed-over files, backups, the note about a moved window.
/// TAKO_HOME means an isolated run, for tests: the Python side sees it too, and then nothing leaves this Mac. The real app never sets it.
let takoHome: URL = {
    let home = ProcessInfo.processInfo.environment["TAKO_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tako")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return home
}()

/// The Python side (`tako_server.py`), shipped inside the app and run for as long as the app runs.
final class Backend {
    /// Its own Python, inside the app, so a new Mac needs nothing installed for it.
    static let python = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3").path ?? ""

    var onReady: (URL) -> Void = { _ in }
    var onFail: (String) -> Void = { _ in }
    private var process: Process?
    private var keepAlive: Pipe?
    private var stopping = false
    private var startedAt: CFTimeInterval = 0
    private let errorFile = takoHome.appendingPathComponent("server.err")

    func start(arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: Backend.python) else {
            onFail("安装不完整，少了内置的 Python。重新安装一次 Tako。")
            return
        }
        guard let script = Bundle.main.url(forResource: "tako_server", withExtension: "py") else {
            onFail("安装不完整，重新安装一次 Tako。")
            return
        }
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let task = Process()
        // Opened from the Dock an app gets almost no environment; the model needs the PATH and proxy of the owner's own shell.
        task.executableURL = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_shell))
        task.arguments = ["-lc", "exec \"$0\" \"$@\"", Backend.python, script.path, "--with-app"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"  // A .pyc written inside the app would break its signature.
        task.environment = environment
        let output = Pipe(), input = Pipe()
        task.standardOutput = output
        task.standardInput = input     // The server leaves when this closes, so even a crash of the app takes it along.
        task.standardError = (try? FileHandle(forWritingTo: errorFile)) ?? FileHandle.nullDevice
        var ready = false
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.ended(wasReady: ready) }
        }
        do { try task.run() } catch {
            onFail("后端启动失败：\(error.localizedDescription)")
            return
        }
        process = task
        keepAlive = input
        startedAt = CACurrentMediaTime()
        DispatchQueue.global().async { [weak self] in
            // A login profile may print things of its own; the address is the one line that looks like it.
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                pending.append(chunk)
                let lines = String(decoding: pending, as: UTF8.self).split(separator: "\n")
                if let line = lines.first(where: { $0.hasPrefix("http://127.0.0.1:") }), let url = URL(string: String(line)) {
                    DispatchQueue.main.async { ready = true; self?.onReady(url) }
                    return
                }
            }
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    private func ended(wasReady: Bool) {
        guard !stopping else { return }
        // One that ran for a while gets another go; one that keeps dying has something to say.
        if wasReady, CACurrentMediaTime() - startedAt > 20 {
            start(arguments: [])
        } else {
            onFail(explanation())
        }
    }

    private func explanation() -> String {
        let text = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        if text.contains("Operation not permitted") {
            return "Tako 读不到桌面文件夹。\n请到“系统设置 > 隐私与安全性 > 文件和文件夹”打开 Tako 的“桌面文件夹”，再打开一次 Tako。"
        }
        let tail = text.split(separator: "\n").suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "后端退出了，没有留下原因。" : "后端退出了：\n\(tail)"
    }
}
