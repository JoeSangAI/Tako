import AppKit
import CoreGraphics

// Asked by the running Tako: a process started now gets the system's current answer on Screen Recording, which one
// started before the switch was turned on never does. Before anything else, so it touches no log and opens no window.
if CommandLine.arguments.contains("--can-capture") {
    print(CGPreflightScreenCaptureAccess() ? "yes" : "no")
    // From a terminal the system answers for the terminal app, which owns the process, not for Tako (GitHub issue 2).
    if isatty(STDOUT_FILENO) != 0 {
        FileHandle.standardError.write(Data("run from a terminal, this is the terminal's own Screen Recording switch; Tako's own answer is in panel.log (\"screen capture fresh process=\")\n".utf8))
    }
    exit(0)
}

// Opened from the Dock there is no terminal: what it has to say goes to a file.
let logFile = open(takoHome.appendingPathComponent("panel.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
if logFile >= 0 { dup2(logFile, STDERR_FILENO) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller(selfTest: CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains { $0.hasPrefix("--showcase") })
app.delegate = controller
app.run()
