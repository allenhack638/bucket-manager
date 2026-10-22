import AppKit
import Logging

#if DEBUG
if ProcessInfo.processInfo.environment["S3C_LOG"] == "1" {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = .debug
        return handler
    }
}
#endif

private func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

private func parsedSize(default fallback: NSSize) -> NSSize {
    guard let raw = argumentValue("--size") else { return fallback }
    let parts = raw.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return fallback }
    return NSSize(width: w, height: h)
}

#if DEBUG
// Hidden diagnostics and offscreen rendering for visual verification.
if let path = argumentValue("--snapshot") {
    SnapshotRunner.runMain(
        path: path,
        size: parsedSize(default: NSSize(width: Theme.Metrics.windowWidth, height: Theme.Metrics.windowHeight)),
        tab: argumentValue("--tab"),
        empty: argumentValue("--empty"),
        pathPrefix: argumentValue("--prefix"),
        errorMessage: argumentValue("--error"),
        filter: argumentValue("--filter")
    )
    exit(0)
}

if let kind = argumentValue("--snapshot-sheet") {
    SnapshotRunner.runSheet(
        path: argumentValue("--out") ?? ".commandcode/refs/sheet-\(kind).png",
        size: parsedSize(default: kind == "accounts" ? NSSize(width: 760, height: 460) : NSSize(width: 640, height: 620)),
        kind: kind
    )
    exit(0)
}

if CommandLine.arguments.contains("--uitest") {
    UITest.run()
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    Probe.run()
    exit(0)
}

if CommandLine.arguments.contains("--verify-startup") {
    StartupVerify.run()
}

if let port = argumentValue("--e2e") {
    E2E.run(port: port)
}

// Hidden diagnostic: `BucketManager --selftest [endpoint] [region]` exercises the
// S3 endpoint resolver with dummy credentials and prints the resulting error
// class, without launching the GUI.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}
#endif

// AppKit entry point (SwiftPM executable). Keeps the app running as a regular,
// focusable GUI application.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
