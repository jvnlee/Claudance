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

if let idx = arguments.firstIndex(of: "--render-cluster") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    FrameRenderer.clusterSheet(to: dir)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--bench-panel") {
    let count = (idx + 1 < arguments.count) ? Int(arguments[idx + 1]) ?? 20 : 20
    PanelDemo.bench(count: count, iterations: 20)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-panel") {
    let count = (idx + 1 < arguments.count) ? Int(arguments[idx + 1]) ?? 20 : 20
    let dir = (idx + 2 < arguments.count) ? arguments[idx + 2] : FileManager.default.currentDirectoryPath
    PanelDemo.render(count: count, to: dir)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-icon") {
    let dir = (idx + 1 < arguments.count) ? arguments[idx + 1] : FileManager.default.currentDirectoryPath
    IconRenderer.dump(to: dir)
    exit(0)
}

if arguments.contains("--verify-loop") {
    FrameRenderer.verifyLoop(label: "idle", state: .idle, energy: 0.30, style: .bounce)
    FrameRenderer.verifyLoop(label: "waiting", state: .waiting, energy: 0.60, style: .bounce)
    for style in DanceStyle.allCases {
        FrameRenderer.verifyLoop(label: "working/\(style.rawValue)", state: .working, energy: 1.00, style: style)
    }
    exit(0)
}

if arguments.contains("--print-usage") {
    UsageMonitor.printDiagnostic()
    exit(0)
}

if arguments.contains("--probe-auth-recovery") {
    UsageMonitor.probeAuthRecoveryDiagnostic()
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
    let accountsOK = AccountRegistry.selfTest()
    let usageOK = UsageMonitor.selfTest()
    exit(accountsOK && usageOK ? 0 : 1)
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
    let rest = arguments[(idx + 1)...].prefix(3)
    let states: Set = ["working", "waiting", "idle"]
    let styles = Dictionary(uniqueKeysWithValues: DanceStyle.allCases.map { ($0.rawValue, $0) })
    let dir = rest.first { !states.contains($0) && styles[$0] == nil } ?? FileManager.default.currentDirectoryPath
    let state = rest.first { states.contains($0) } ?? "working"
    let style = rest.compactMap { styles[$0] }.first ?? .bounce
    FrameRenderer.loopGif(to: dir, state: state, style: style)
    exit(0)
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
