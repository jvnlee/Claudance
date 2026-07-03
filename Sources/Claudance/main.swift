import AppKit

let arguments = CommandLine.arguments

let app = NSApplication.shared

if let idx = arguments.firstIndex(of: "--render-frames") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    FrameRenderer.dump(to: dir)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-loop") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    FrameRenderer.loopStrip(to: dir)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-composite") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    FrameRenderer.compositeSheet(to: dir)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-icon") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    IconRenderer.dump(to: dir)
    exit(0)
}

if arguments.contains("--verify-loop") {
    for state in ["working", "waiting", "idle"] { FrameRenderer.verifyLoop(state: state) }
    exit(0)
}

if arguments.contains("--print-usage") {
    UsageMonitor.printDiagnostic()
    exit(0)
}

if arguments.contains("--print-accounts") {
    AccountRegistry.printDiagnostic()
    exit(0)
}

if arguments.contains("--print-sessions") {
    SessionMonitor.printDiagnostic()
    exit(0)
}

if arguments.contains("--selftest") {
    exit(AccountRegistry.selfTest() ? 0 : 1)
}

if let idx = arguments.firstIndex(of: "--install-hooks") {
    let next = idx + 1 < arguments.count ? arguments[idx + 1] : nil
    if let path = next, !path.hasPrefix("-") {
        HookInstaller.ensureInstalled(home: URL(fileURLWithPath: path))
    } else {
        HookInstaller.ensureInstalled()
    }
    print("Claudance hooks installed.")
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-gif") {
    let rest = arguments[(idx + 1)...].prefix(2)
    let states: Set = ["working", "waiting", "idle"]
    let dir = rest.first { !states.contains($0) } ?? FileManager.default.currentDirectoryPath
    let state = rest.first { states.contains($0) } ?? "working"
    FrameRenderer.loopGif(to: dir, state: state)
    exit(0)
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
