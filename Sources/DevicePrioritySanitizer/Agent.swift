import AppKit
import Darwin
import Foundation

// MARK: - Agent lifecycle (launchd-supervised or manually launched)

/// The app IS the agent — one binary, no separate service. `start`/`stop`
/// (and the menubar Quit) control the lifecycle of that one process:
///
/// - With the Home Manager LaunchAgent installed (`autostart = true`),
///   `KeepAlive` resurrects any plain exit, so stopping must go through
///   `launchctl bootout` and starting through `launchctl bootstrap`.
/// - Without the plist (`autostart = false`, or a manual install) the app is
///   an unsupervised accessory: LaunchServices launches it and
///   `NSRunningApplication` terminates it.
///
/// `/bin/launchctl` is the only binary invoked here — it has no nixpkgs
/// package, and the HM module's migration script already uses the same
/// path for its bootout.

enum AgentCommand: Equatable, Sendable {
    case start
    case stop
}

/// Everything the planner needs, gathered as data so the plan itself is pure
/// and unit-testable.
struct AgentEnvironment: Equatable, Sendable {
    /// Installed LaunchAgent plist (`~/Library/LaunchAgents/…`), if any.
    var plistPath: String?
    /// The plist's `Label` key — HM derives it from the Nix `username`, so
    /// it is read from the file, never guessed.
    var label: String?
    /// The launchd job is currently loaded into the user's GUI domain.
    var jobLoaded: Bool
    /// A resolvable `.app` bundle for manual (unsupervised) launching.
    var appBundlePath: String?
    /// A running instance is visible to LaunchServices (bundle id match).
    var appRunning: Bool
}

enum AgentPlan: Equatable, Sendable {
    case bootstrap(label: String, plist: String)
    case bootout(label: String)
    case launch(bundle: String)
    case terminateApp
    case alreadyRunning
    case notRunning
    /// Nothing to act on; carries the reason.
    case noTarget(String)
}

func planAgent(command: AgentCommand, environment: AgentEnvironment) -> AgentPlan {
    switch command {
    case .start:
        if environment.jobLoaded { return .alreadyRunning }
        if let label = environment.label, let plist = environment.plistPath {
            return .bootstrap(label: label, plist: plist)
        }
        if environment.appRunning { return .alreadyRunning }
        if let bundle = environment.appBundlePath { return .launch(bundle: bundle) }
        return .noTarget("no LaunchAgent installed and no app bundle found")
    case .stop:
        if environment.jobLoaded, let label = environment.label {
            return .bootout(label: label)
        }
        if environment.appRunning { return .terminateApp }
        return .notRunning
    }
}

// MARK: - Pure derivation helpers

/// Resolves the app bundle for an executable path: inside a `.app` bundle
/// (`…/Foo.app/Contents/MacOS/bin`) walk up to the bundle; from the package
/// CLI (`$out/bin/device-priority-sanitizer`, possibly via a profile symlink)
/// use the sibling `$out/Applications/device-priority-sanitizer.app`.
func appBundlePath(executable: String, override: String?) -> String? {
    if let override {
        return FileManager.default.fileExists(atPath: override) ? override : nil
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    if resolved.contains("/Contents/MacOS/") {
        var url = URL(fileURLWithPath: resolved)
        url.deleteLastPathComponent()  // …/Contents/MacOS
        url.deleteLastPathComponent()  // …/Contents
        url.deleteLastPathComponent()  // …/Foo.app
        return url.path
    }
    // The package layout: `$out/bin/<programName>` → the sibling
    // `$out/Applications/<programName>.app`. The basename guard keeps any
    // foreign `bin/…` executable from resolving to a nonsense bundle.
    let url = URL(fileURLWithPath: resolved)
    guard
        url.lastPathComponent == programName,
        url.deletingLastPathComponent().lastPathComponent == "bin"
    else { return nil }
    return
        url
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Applications/device-priority-sanitizer.app", isDirectory: true)
        .path
}

func appBundlePath(override: String?) -> String? {
    guard let executable = Bundle.main.executablePath else { return nil }
    return appBundlePath(executable: executable, override: override)
}

/// The `Label` of a LaunchAgent plist; `nil` for unreadable files.
func plistLabel(_ data: Data) -> String? {
    guard
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any]
    else { return nil }
    return dictionary["Label"] as? String
}

// MARK: - LaunchAgent discovery (I/O)

/// Finds the installed LaunchAgent: the `--launchd-plist` override (test
/// seam) or a scan of `~/Library/LaunchAgents` for
/// `*.device-priority-sanitizer.plist`. The label is read from the file.
func launchdAgentPlist(override: String?) -> (path: String, label: String)? {
    let candidates: [String]
    if let override {
        candidates = [override]
    } else {
        let directory = NSHomeDirectory() + "/Library/LaunchAgents"
        candidates =
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".device-priority-sanitizer.plist") }
            .sorted()
            .map { "\(directory)/\($0)" }
    }
    for path in candidates {
        guard
            FileManager.default.fileExists(atPath: path),
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let label = plistLabel(data)
        else { continue }
        return (path, label)
    }
    return nil
}

// MARK: - launchctl effects

private func runLaunchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CliFailure.software("launchctl \(arguments.joined(separator: " ")) failed")
    }
}

/// Read-only probe: is the job loaded in the user's GUI domain? A sandboxed
/// test run cannot execute `/bin/launchctl` — degrade to "not loaded"
/// instead of failing.
func isJobLoaded(label: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/\(label)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func bootstrapAgent(plist: String) throws {
    try runLaunchctl(["bootstrap", "gui/\(getuid())", plist])
}

func bootoutAgent(label: String) throws {
    try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
}

// MARK: - Manual (unsupervised) instances

func bundleIdentifier(at bundlePath: String) -> String? {
    let infoURL = URL(fileURLWithPath: bundlePath)
        .appendingPathComponent("Contents/Info.plist")
    guard
        let data = try? Data(contentsOf: infoURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any]
    else { return nil }
    return dictionary["CFBundleIdentifier"] as? String
}

func runningInstances(bundleIdentifier: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
}

func terminateInstances(_ applications: [NSRunningApplication]) throws {
    for application in applications {
        application.terminate()
    }
    let deadline = Date().addingTimeInterval(2)
    for application in applications {
        while !application.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard application.isTerminated else {
            throw CliFailure.software("could not stop the running app (PID \(application.processIdentifier))")
        }
    }
}

func openApplication(at bundlePath: String) throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    var launchError: Error?
    var finished = false
    NSWorkspace.shared.openApplication(
        at: URL(fileURLWithPath: bundlePath),
        configuration: configuration
    ) { _, error in
        launchError = error
        finished = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !finished, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if let launchError {
        throw CliFailure.software("could not launch \(bundlePath): \(launchError)")
    }
    guard finished else {
        throw CliFailure.software("could not launch \(bundlePath): timed out")
    }
}

// MARK: - CLI commands (effects per plan)

func runAgentCommand(_ command: AgentCommand, _ options: Options) throws -> CommandOutput {
    let usage = command == .start ? "start" : "stop"
    try requirePositionalArguments(options, atMost: 1, usage: usage)

    let agent = launchdAgentPlist(override: options.launchdPlistPath)
    let bundle = appBundlePath(override: options.appBundlePath)
    let bundleID = bundle.flatMap(bundleIdentifier(at:))
    let running = bundleID.map { !runningInstances(bundleIdentifier: $0).isEmpty } ?? false
    let environment = AgentEnvironment(
        plistPath: agent?.path,
        label: agent?.label,
        jobLoaded: agent.map { isJobLoaded(label: $0.label) } ?? false,
        appBundlePath: bundle,
        appRunning: running
    )
    let plan = planAgent(command: command, environment: environment)

    if case .noTarget = plan {
        throw CliFailure.software("no LaunchAgent installed and no app bundle found — nothing to start")
    }
    if options.dryRun {
        return CommandOutput(lines: renderAgentDryRun(plan))
    }

    switch plan {
    case .bootstrap(let label, let plist):
        try bootstrapAgent(plist: plist)
        return CommandOutput(lines: ["app: started (launchd agent \(label))"])
    case .bootout(let label):
        try bootoutAgent(label: label)
        var lines = ["app: stopped (launchd agent \(label))"]
        // A manually launched instance may coexist with the job; sweep it.
        if let bundleID, !runningInstances(bundleIdentifier: bundleID).isEmpty {
            try terminateInstances(runningInstances(bundleIdentifier: bundleID))
            lines.append("app: stopped leftover instance")
        }
        return CommandOutput(lines: lines)
    case .launch(let bundle):
        try openApplication(at: bundle)
        return CommandOutput(lines: ["app: started"])
    case .terminateApp:
        guard let bundleID else {
            throw CliFailure.software("the running app has no readable bundle identifier")
        }
        try terminateInstances(runningInstances(bundleIdentifier: bundleID))
        return CommandOutput(lines: ["app: stopped"])
    case .alreadyRunning:
        return CommandOutput(lines: ["app: already running"])
    case .notRunning:
        return CommandOutput(lines: ["app: not running"])
    case .noTarget:
        throw CliFailure.software("unreachable — noTarget is handled above")
    }
}

func renderAgentDryRun(_ plan: AgentPlan) -> [String] {
    switch plan {
    case .bootstrap(let label, _):
        return ["app: would start launchd agent \(label)"]
    case .bootout(let label):
        return ["app: would stop launchd agent \(label)"]
    case .launch(let bundle):
        return ["app: would launch \(bundle)"]
    case .terminateApp:
        return ["app: would terminate the running instance"]
    case .alreadyRunning:
        return ["app: already running"]
    case .notRunning:
        return ["app: not running"]
    case .noTarget(let reason):
        return ["app: \(reason)"]
    }
}

// MARK: - Quit (shared with the menubar app)

/// The menubar Quit: boots out the launchd job when the app is supervised —
/// `KeepAlive` would resurrect a plain exit — and otherwise terminates
/// directly. The bootout kills this process mid-call; that is the goal, and
/// the direct terminate is the fallback for manual instances and a failed
/// bootout.
func stopAgentFromWithinApp() {
    if let agent = launchdAgentPlist(override: nil), isJobLoaded(label: agent.label) {
        do {
            try bootoutAgent(label: agent.label)
            logStderr("bootout did not stop this process — terminating directly")
        } catch {
            logStderr("\(error) — terminating directly")
        }
    }
    NSApp.terminate(nil)
}

// MARK: - Agent-owned logging

func defaultAgentLogDirectory() -> String {
    NSHomeDirectory() + "/Library/Logs/device-priority-sanitizer"
}

/// Rotates `agent.log` to `agent.log.1` (replacing an older rotation), so
/// every process start begins a fresh log and a crash loop keeps the previous
/// run's evidence — the same guarantee the old launchd wrapper provided.
struct AgentLog {
    let path: String
    let previousPath: String

    init(directory: String) {
        path = directory + "/agent.log"
        previousPath = directory + "/agent.log.1"
    }

    func rotate() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }
        try? fileManager.removeItem(atPath: previousPath)
        try? fileManager.moveItem(atPath: path, toPath: previousPath)
    }

    /// Creates the directory, rotates the previous log, and redirects both
    /// standard streams so every launch mode (launchd, `start`, manual)
    /// keeps the same `agent.log`. A failure degrades to terminal output —
    /// logging must never block startup.
    func setUp() {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        rotate()
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }
}

/// GUI-mode logging: called before any config load so startup warnings land
/// in the log too. CLI invocations keep their terminal stdio.
func setUpAgentLogging() {
    AgentLog(directory: defaultAgentLogDirectory()).setUp()
}
