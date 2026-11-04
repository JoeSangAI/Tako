import AppKit

// Opened from the Dock there is no terminal: what it has to say goes to a file.
let logFile = open(takoHome.appendingPathComponent("panel.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
if logFile >= 0 { dup2(logFile, STDERR_FILENO) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller(selfTest: CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains { $0.hasPrefix("--showcase") })
app.delegate = controller
app.run()
