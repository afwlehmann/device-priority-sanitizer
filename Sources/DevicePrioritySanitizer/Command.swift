import Foundation

let programName = "device-priority-sanitizer"

let programVersion = "0.2.0"

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data("[\(programName)] \(message)\n".utf8))
}

// MARK: - Failure domain
//
// Expected outcomes are encoded with Swift's native error handling (typed
// errors thrown and caught) — no abrupt exits inside logic, and the boundary
// alone renders a failure to stderr lines and a sysexits-al exit code.

/// Expected CLI failures. The exit code is data, not behavior.
enum CliFailure: Error, Sendable {
    /// Bad invocation: invalid flags, unknown command, refused mode. EX_USAGE.
    case usage(String)
    /// Unusable input data: invalid config or device fixture. EX_DATAERR.
    case dataInvalid(String)
    /// Expected state not found. EX_NOINPUT.
    case noDevice(String)
    /// Ambiguous device name; candidates are rendered as extra lines. No
    /// sysexits match — deliberate CLI-stable code (3), asserted by tests.
    case ambiguous(target: String, name: String, candidates: [MediaDevice])
    /// A side effect failed (device write). EX_SOFTWARE.
    case software(String)

    var exitCode: Int32 {
        switch self {
        case .usage: return 64  // EX_USAGE
        case .dataInvalid: return 65  // EX_DATAERR
        case .noDevice: return 66  // EX_NOINPUT
        case .ambiguous: return 3
        case .software: return 70  // EX_SOFTWARE
        }
    }

    /// Boundary rendering: stderr lines for the failure.
    var lines: [String] {
        switch self {
        case .usage(let message), .dataInvalid(let message), .noDevice(let message), .software(let message):
            return ["[\(programName)] \(message)"]
        case .ambiguous(let target, let name, let candidates):
            return ["[\(programName)] ambiguous '\(name)' for \(target); candidates:"]
                + candidates.map { "  \($0.name)" }
        }
    }
}

// MARK: - Options (pure fold over argv; flag syntax failures are typed)

struct Options: Sendable {
    let helpRequested: Bool
    let configPath: String?
    let devicesPath: String?
    let statePath: String?
    let dryRun: Bool
    let json: Bool
    let tier: String?
    let positional: [String]
}

/// Targets following a `[output|input|camera]` positional: all of them when
/// omitted, otherwise the one (validated) target.
func selectedTargets(_ options: Options) throws -> [Target] {
    guard options.positional.count > 1 else { return Target.allCases }
    guard let target = Target(rawValue: options.positional[1]) else {
        throw CliFailure.usage("unknown target '\(options.positional[1])'")
    }
    return [target]
}

/// The `[output|input|camera] <tail…>` shape shared by `set`/`cycle`/`current`.
func tailTarget(_ options: Options, usage: String) throws -> Target {
    guard options.positional.count >= 2 else { throw CliFailure.usage("usage: \(programName) \(usage)") }
    guard let target = Target(rawValue: options.positional[1]) else {
        throw CliFailure.usage("unknown target '\(options.positional[1])'")
    }
    return target
}

/// Real device writes are refused against a fixture table unless the caller
/// asked for `--dry-run` (the seam must stay pure).
func requireRealDeviceContext(_ options: Options) throws {
    guard options.devicesPath == nil || options.dryRun else {
        throw CliFailure.usage("--devices is a test seam; real writes require --dry-run")
    }
}

/// Rejects trailing positional arguments the command does not consume instead
/// of silently ignoring them.
func requirePositionalArguments(_ options: Options, atMost: Int, usage: String) throws {
    guard options.positional.count <= atMost else {
        throw CliFailure.usage("usage: \(programName) \(usage)")
    }
}

// MARK: - Device resolution (pure)

enum DeviceNameMatch: Sendable {
    case notFound
    case matched(MediaDevice)
    case ambiguous([MediaDevice])
}

/// Exact name first, then case-insensitive substring; ambiguity is data, not
/// a silent first-pick.
func resolveDevice(
    _ target: Target,
    name: String,
    devices: [MediaDevice]
) -> DeviceNameMatch {
    let candidates = devices.filter { $0.supports(target) }
    let exact = candidates.filter { $0.name == name }
    switch exact.count {
    case 1: return .matched(exact[0])
    case 0: break
    default: return .ambiguous(exact)
    }
    let fuzzy = candidates.filter { $0.name.range(of: name, options: .caseInsensitive) != nil }
    switch fuzzy.count {
    case 0: return .notFound
    case 1: return .matched(fuzzy[0])
    default: return .ambiguous(fuzzy)
    }
}

// MARK: - Planned changes (pure)

struct PlannedChange: Sendable {
    let target: Target
    /// The device the priority list would select; `nil` when no tier matches.
    let device: MediaDevice?
    let current: MediaDevice?
    /// The current device is a synthetic (excluded) transport: auto-selection
    /// leaves it alone (only explicit user actions bypass this).
    let skippedExcluded: Bool
    /// The target has no priority tiers — it is not auto-managed.
    let skippedUnmanaged: Bool
    /// The global prioritization switch is off.
    let skippedDisabled: Bool
}

func planApply(
    source: DeviceSource,
    engine: PriorityEngine,
    devices: [MediaDevice],
    force: Bool,
    prioritizationEnabled: Bool = true
) -> [PlannedChange] {
    Target.allCases.map { target -> PlannedChange in
        let current = source.defaultDevice(for: target)
        let skippedDisabled = !prioritizationEnabled
        let skippedUnmanaged = prioritizationEnabled && !engine.isManaged(target)
        let skippedExcluded =
            prioritizationEnabled && !skippedUnmanaged && !force && (current.map { !$0.isManaged } ?? false)
        let device =
            (skippedDisabled || skippedUnmanaged || skippedExcluded)
            ? nil
            : engine.targetDevice(target, current: current, devices: devices)
        return PlannedChange(
            target: target,
            device: device,
            current: current,
            skippedExcluded: skippedExcluded,
            skippedUnmanaged: skippedUnmanaged,
            skippedDisabled: skippedDisabled
        )
    }
}

/// Pure rendering of a plan: the caller decides where the lines go.
func renderPlan(_ plan: [PlannedChange], dryRun: Bool) -> [String] {
    plan.map { change -> String in
        let target = change.target.rawValue
        if change.skippedDisabled {
            return "\(target): skipped — prioritization disabled"
        }
        if change.skippedUnmanaged {
            return "\(target): not auto-managed (no priority tiers)"
        }
        if change.skippedExcluded {
            return "\(target): skipped — current '\(change.current?.name ?? "?")' is not managed"
        }
        guard let device = change.device else {
            return "\(target): no priority device present — leaving '\(change.current?.name ?? "none")'"
        }
        if change.current?.uid == device.uid {
            return "\(target): unchanged (\(device.name))"
        }
        return dryRun ? "\(target): would set to \(device.name)" : "\(target): set to \(device.name)"
    }
}

/// The effect executor for a plan. Effects only — rendering happens in
/// `renderPlan`, failures are typed.
func performPlan(
    _ plan: [PlannedChange],
    on source: DeviceSource,
    dryRun: Bool
) throws {
    guard !dryRun else { return }
    try plan.forEach { change in
        guard let device = change.device, change.current?.uid != device.uid else { return }
        let status = source.setDefault(device, target: change.target)
        guard status == noErr else {
            throw CliFailure.software(
                "failed to set \(change.target.rawValue) to \(device.name): OSStatus \(status)"
            )
        }
    }
}

// MARK: - Commands (computations; effects via source; output as data)

struct CommandOutput: Sendable {
    let lines: [String]
    /// Non-zero when the command completed with a diagnostic partial result
    /// (only `status` on an invalid config uses this); `nil` → exit 0.
    var exitCode: Int32? = nil
}

func runList(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requirePositionalArguments(options, atMost: 2, usage: "list [output|input|camera]")
    let devices = source.allDevices()
    let targets = try selectedTargets(options)

    if options.json {
        let sections = try targets.reduce(into: [String: [[String: Any]]]()) { sections, target in
            let currentUID = source.defaultDevice(for: target)?.uid
            let entries: [[String: Any]] =
                devices
                .filter { $0.supports(target) }
                .map { device in
                    var entry: [String: Any] = [
                        "name": device.name,
                        "uid": device.uid,
                        "transport": device.transportClass.rawValue,
                        "excluded": !device.isManaged,
                        "current": device.uid == currentUID,
                    ]
                    if let deviceType = device.deviceType {
                        entry["deviceType"] = deviceType
                    }
                    return entry
                }
            sections[target.rawValue] = entries
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: sections,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            throw CliFailure.software("could not serialize the device list")
        }
        return CommandOutput(lines: [String(decoding: data, as: UTF8.self)])
    }

    let blocks = targets.map { target -> [String] in
        let current = source.defaultDevice(for: target)
        let row = { (device: MediaDevice) -> String in
            let marker = current?.uid == device.uid ? "*" : " "
            let suffix = device.isManaged ? "" : " [\(device.transportClass.rawValue)]"
            return "\(marker) \(device.name)\(suffix)"
        }
        let managed = engine.orderedManagedDevices(target, devices: devices).map(row)
        let excluded =
            devices
            .filter { $0.supports(target) && !$0.isManaged }
            .sorted { $0.name.compare($1.name, options: .caseInsensitive) == .orderedAscending }
            .map(row)
        return ["\(target.rawValue):"] + managed + excluded
    }
    return CommandOutput(lines: blocks.flatMap { $0 })
}

func runCurrent(
    _ options: Options,
    source: DeviceSource
) throws -> CommandOutput {
    try requirePositionalArguments(options, atMost: 2, usage: "current [output|input|camera]")
    let targets = try selectedTargets(options)
    let lines: [String] = try targets.map { target -> String in
        let device = source.defaultDevice(for: target)
        if options.positional.count > 1 {
            guard let device = device else {
                throw CliFailure.noDevice("no default \(target.rawValue) device")
            }
            return device.name
        }
        return "\(target.rawValue): \(device?.name ?? "none")"
    }
    return CommandOutput(lines: lines)
}

/// Shared effect for `set <name>` and `set --tier`: one manual pick, with the
/// usual already-set / dry-run reporting.
private func applyDefaultDevice(
    _ device: MediaDevice,
    target: Target,
    source: DeviceSource,
    dryRun: Bool
) throws -> CommandOutput {
    if source.defaultDevice(for: target)?.uid == device.uid {
        return CommandOutput(lines: ["\(target.rawValue): already \(device.name)"])
    }
    if dryRun {
        return CommandOutput(lines: ["\(target.rawValue): would set to \(device.name)"])
    }
    let status = source.setDefault(device, target: target)
    guard status == noErr else {
        throw CliFailure.software(
            "failed to set \(target.rawValue) to \(device.name): OSStatus \(status)"
        )
    }
    return CommandOutput(lines: ["\(target.rawValue): set to \(device.name)"])
}

func runSet(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requireRealDeviceContext(options)
    if let tier = options.tier {
        guard options.positional.count == 2 else {
            throw CliFailure.usage("usage: \(programName) set <output|input|camera> --tier <title>")
        }
        let target = try tailTarget(options, usage: "set <output|input|camera> --tier <title>")
        switch engine.tierTarget(
            target,
            title: tier,
            current: source.defaultDevice(for: target),
            devices: source.allDevices()
        ) {
        case .unknownTier:
            throw CliFailure.usage(
                "unknown \(target.rawValue) tier '\(tier)'; available: "
                    + engine.tierTitles(target).joined(separator: ", ")
            )
        case .noDevice:
            throw CliFailure.noDevice(
                "no connected \(target.rawValue) device in tier '\(tier)'"
            )
        case .device(let device):
            return try applyDefaultDevice(
                device, target: target, source: source, dryRun: options.dryRun
            )
        }
    }
    guard options.positional.count >= 3 else {
        throw CliFailure.usage("usage: \(programName) set <output|input|camera> <device name>")
    }
    let target = try tailTarget(options, usage: "set <output|input|camera> <device name>")
    let name = options.positional[2...].joined(separator: " ")
    switch resolveDevice(target, name: name, devices: source.allDevices()) {
    case .notFound:
        throw CliFailure.noDevice("no \(target.rawValue) device matching '\(name)'")
    case .ambiguous(let candidates):
        throw CliFailure.ambiguous(target: target.rawValue, name: name, candidates: candidates)
    case .matched(let device):
        return try applyDefaultDevice(
            device, target: target, source: source, dryRun: options.dryRun
        )
    }
}

func runReapply(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requirePositionalArguments(options, atMost: 1, usage: "reapply")
    try requireRealDeviceContext(options)
    let prioritizationEnabled = resolveState(options.statePath ?? defaultStatePath()).prioritizationEnabled
    let devices = source.allDevices()
    let plan = planApply(
        source: source, engine: engine, devices: devices, force: true,
        prioritizationEnabled: prioritizationEnabled
    )
    let lines = renderPlan(plan, dryRun: options.dryRun)
    try performPlan(plan, on: source, dryRun: options.dryRun)
    return CommandOutput(lines: lines)
}

func runCycle(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requirePositionalArguments(options, atMost: 2, usage: "cycle <output|input|camera>")
    try requireRealDeviceContext(options)
    let target = try tailTarget(options, usage: "cycle <output|input|camera>")
    let devices = source.allDevices()
    let current = source.defaultDevice(for: target)
    guard let next = engine.cycleTarget(target, current: current, devices: devices) else {
        throw CliFailure.noDevice("no visible \(target.rawValue) devices to cycle")
    }
    if current?.uid == next.uid {
        return CommandOutput(lines: ["\(target.rawValue): unchanged (\(next.name))"])
    }
    if options.dryRun {
        return CommandOutput(lines: ["\(target.rawValue): would cycle to \(next.name)"])
    }
    let status = source.setDefault(next, target: target)
    guard status == noErr else {
        throw CliFailure.software(
            "failed to cycle \(target.rawValue) to \(next.name): OSStatus \(status)"
        )
    }
    return CommandOutput(lines: ["\(target.rawValue): cycled to \(next.name)"])
}

// MARK: - Prioritization switch (state only; never loads the tier config)

/// `enable` / `disable`: write the state file and notify a running agent.
/// Deliberately independent of the tier config — a broken config must never
/// prevent disabling the service. An overridden `--state` path (tests) never
/// pokes the live agent.
func runPrioritizationSwitch(
    _ options: Options,
    enabled: Bool
) throws -> CommandOutput {
    let usage = enabled ? "enable" : "disable"
    try requirePositionalArguments(options, atMost: 1, usage: usage)
    let path = options.statePath ?? defaultStatePath()
    do {
        try saveState(PrioritizationState(prioritizationEnabled: enabled), to: path)
    } catch {
        throw CliFailure.software("failed to write state at \(path): \(error)")
    }
    if options.statePath == nil {
        DistributedNotificationCenter.default().post(name: stateChangedNotificationName, object: nil)
    }
    return CommandOutput(lines: ["prioritization: \(enabled ? "enabled" : "disabled")"])
}

/// `status [--json]`: the global switch plus per-target managed state. Reads
/// the config JSON but never compiles tier regexes — an invalid regex does
/// not block status; invalid JSON still shows the global state and exits 65.
func runStatus(_ options: Options) throws -> CommandOutput {
    try requirePositionalArguments(options, atMost: 1, usage: "status [--json]")
    let enabled = resolveState(options.statePath ?? defaultStatePath()).prioritizationEnabled

    func render(_ config: AppConfig?) -> [String] {
        let targets = Target.allCases.map { target in
            let tiers = config.map { $0.entries(for: target) } ?? []
            return (target, tiers)
        }
        if options.json {
            let sections = Dictionary(
                uniqueKeysWithValues: targets.map { target, tiers in
                    (
                        target.rawValue,
                        ["managed": !tiers.isEmpty, "tiers": tiers.count] as [String: Any]
                    )
                })
            let json: [String: Any] = ["enabled": enabled, "targets": sections]
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
                )
            else { return ["could not serialize status"] }
            return [String(decoding: data, as: UTF8.self)]
        }
        return ["prioritization: \(enabled ? "enabled" : "disabled")"]
            + targets.map { target, tiers in
                tiers.isEmpty
                    ? "\(target.rawValue): not managed (0 tiers)"
                    : "\(target.rawValue): managed (\(tiers.count) tiers)"
            }
    }

    let path = options.configPath ?? defaultConfigPath()
    guard FileManager.default.fileExists(atPath: path) else {
        // Missing config is not an error: every target is simply unmanaged.
        return CommandOutput(lines: render(nil))
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        return CommandOutput(lines: render(config))
    } catch {
        let lines = ["prioritization: \(enabled ? "enabled" : "disabled")", "targets: unavailable (invalid config)"]
        return CommandOutput(lines: lines, exitCode: 65)
    }
}

// MARK: - menu-text (deterministic rendering of the dropdown + status icons)

/// The current menubar status line: three slot symbols plus the pause marker
/// when prioritization is globally disabled.
func renderStatusLine(
    source: DeviceSource,
    engine: PriorityEngine,
    prioritizationEnabled: Bool
) -> String {
    var symbols = Target.allCases.map { engine.slotSymbol(for: source.defaultDevice(for: $0), target: $0) }
    if !prioritizationEnabled {
        symbols.append("pause.circle")
    }
    return "status: " + symbols.joined(separator: " ")
}

func renderMenu(
    source: DeviceSource,
    engine: PriorityEngine,
    prioritizationEnabled: Bool
) -> [String] {
    let devices = source.allDevices()
    let statusLine = renderStatusLine(source: source, engine: engine, prioritizationEnabled: prioritizationEnabled)
    let blocks: [String] = Target.allCases
        .flatMap { target -> [String] in
            var lines = ["\(target.menuLabel)-menu:"]
            if !engine.isManaged(target) {
                // No priority tiers: the target is not auto-managed — the
                // empty tier list is the switch, there is no other flag.
                lines.append("  - Not auto-managed (no priority tiers)")
            }
            if let current = source.defaultDevice(for: target), !current.isManaged {
                // Out-of-domain current device: the app deliberately does not
                // touch it — say so instead of silently hiding it.
                lines.append("  - Current: \(current.name) (not managed)")
            }
            let rows: [String] = engine.orderedManagedDevices(target, devices: devices)
                .map { device in
                    let check = source.defaultDevice(for: target)?.uid == device.uid ? "✓" : "·"
                    let symbol = engine.entrySymbol(for: device, target: target)
                    return "  \(check) \(device.name) [\(symbol)]"
                }
            lines.append(contentsOf: rows)
            return lines
        }
    return ["prioritization: \(prioritizationEnabled ? "enabled" : "disabled")", statusLine] + blocks
}

// MARK: - Dispatch (registry wiring; logic lives in the run* functions)

func runCommand(
    _ command: String,
    _ options: Options,
    _ source: DeviceSource,
    _ engine: PriorityEngine
) throws -> CommandOutput {
    switch command {
    case "list": return try runList(options, source: source, engine: engine)
    case "current": return try runCurrent(options, source: source)
    case "set": return try runSet(options, source: source, engine: engine)
    case "reapply": return try runReapply(options, source: source, engine: engine)
    case "cycle": return try runCycle(options, source: source, engine: engine)
    case "menu-text":
        try requirePositionalArguments(options, atMost: 1, usage: "menu-text")
        let prioritizationEnabled = resolveState(options.statePath ?? defaultStatePath()).prioritizationEnabled
        return CommandOutput(
            lines: renderMenu(source: source, engine: engine, prioritizationEnabled: prioritizationEnabled))
    case "auto":
        // Hidden test seam: models the GUI's automatic path (list change →
        // per-target apply, respecting the excluded-current guard).
        try requirePositionalArguments(options, atMost: 1, usage: "auto")
        try requireRealDeviceContext(options)
        let prioritizationEnabled = resolveState(options.statePath ?? defaultStatePath()).prioritizationEnabled
        let devices = source.allDevices()
        let plan = planApply(
            source: source, engine: engine, devices: devices, force: false,
            prioritizationEnabled: prioritizationEnabled
        )
        let lines = renderPlan(plan, dryRun: options.dryRun)
        try performPlan(plan, on: source, dryRun: options.dryRun)
        return CommandOutput(lines: lines)
    default:
        throw CliFailure.usage("unknown command '\(command)' — see --help")
    }
}
