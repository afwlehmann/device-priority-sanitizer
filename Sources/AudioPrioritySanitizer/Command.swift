import Foundation

let programName = "audio-priority-sanitizer"

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
    case ambiguous(direction: String, name: String, candidates: [AudioDevice])
    /// A side effect failed (CoreAudio set). EX_SOFTWARE.
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
        case .ambiguous(let direction, let name, let candidates):
            return ["[\(programName)] ambiguous '\(name)' for \(direction); candidates:"]
                + candidates.map { "  \($0.name)" }
        }
    }
}

// MARK: - Options (pure fold over argv; flag syntax failures are typed)

struct Options: Sendable {
    let helpRequested: Bool
    let configPath: String?
    let devicesPath: String?
    let dryRun: Bool
    let json: Bool
    let positional: [String]
}

/// Directions following a `[output|input]` positional: all of them when
/// omitted, otherwise the one (validated) direction.
func selectedDirections(_ options: Options) throws -> [Direction] {
    guard options.positional.count > 1 else { return Direction.allCases }
    guard let direction = Direction(rawValue: options.positional[1]) else {
        throw CliFailure.usage("unknown direction '\(options.positional[1])'")
    }
    return [direction]
}

/// The `[output|input] <tail…>` shape shared by `set`/`cycle`/`current`.
func tailDirection(_ options: Options, usage: String) throws -> Direction {
    guard options.positional.count >= 2 else { throw CliFailure.usage("usage: \(programName) \(usage)") }
    guard let direction = Direction(rawValue: options.positional[1]) else {
        throw CliFailure.usage("unknown direction '\(options.positional[1])'")
    }
    return direction
}

/// Real device writes are refused against a fixture table unless the caller
/// asked for `--dry-run` (the seam must stay pure).
func requireRealDeviceContext(_ options: Options) throws {
    guard options.devicesPath == nil || options.dryRun else {
        throw CliFailure.usage("--devices is a test seam; real writes require --dry-run")
    }
}

// MARK: - Device resolution (pure)

enum DeviceNameMatch: Sendable {
    case notFound
    case matched(AudioDevice)
    case ambiguous([AudioDevice])
}

/// Exact name first, then case-insensitive substring; ambiguity is data, not
/// a silent first-pick.
func resolveDevice(
    _ direction: Direction,
    name: String,
    devices: [AudioDevice]
) -> DeviceNameMatch {
    let candidates = devices.filter { $0.isDirection(direction) }
    if let exact = candidates.first(where: { $0.name == name }) {
        return .matched(exact)
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
    let direction: Direction
    /// The device the priority list would select; `nil` when no tier matches.
    let target: AudioDevice?
    let current: AudioDevice?
    /// The current device is a synthetic (excluded) transport: auto-selection
    /// leaves it alone (only explicit user actions bypass this).
    let skippedExcluded: Bool
}

func planApply(
    source: DeviceSource,
    engine: PriorityEngine,
    devices: [AudioDevice],
    force: Bool
) -> [PlannedChange] {
    Direction.allCases.map { direction -> PlannedChange in
        let current = source.defaultDevice(for: direction)
        let skippedExcluded = !force && (current.map { !$0.isManaged } ?? false)
        let target =
            skippedExcluded
            ? nil
            : engine.targetDevice(direction, current: current, devices: devices)
        return PlannedChange(
            direction: direction,
            target: target,
            current: current,
            skippedExcluded: skippedExcluded
        )
    }
}

/// Pure rendering of a plan: the caller decides where the lines go.
func renderPlan(_ plan: [PlannedChange], dryRun: Bool) -> [String] {
    plan.map { change -> String in
        let direction = change.direction.rawValue
        if change.skippedExcluded {
            return "\(direction): skipped — current '\(change.current?.name ?? "?")' is not managed"
        }
        guard let target = change.target else {
            return "\(direction): no priority device present — leaving '\(change.current?.name ?? "none")'"
        }
        if change.current?.uid == target.uid {
            return "\(direction): unchanged (\(target.name))"
        }
        return dryRun ? "\(direction): would set to \(target.name)" : "\(direction): set to \(target.name)"
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
        guard let target = change.target, change.current?.uid != target.uid else { return }
        let status = source.setDefault(target, direction: change.direction)
        guard status == noErr else {
            throw CliFailure.software(
                "failed to set \(change.direction.rawValue) to \(target.name): OSStatus \(status)"
            )
        }
    }
}

// MARK: - Commands (computations; effects via source; output as data)

struct CommandOutput: Sendable {
    let lines: [String]
}

func runList(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    let devices = source.allDevices()
    let directions = try selectedDirections(options)

    if options.json {
        let sections = try directions.reduce(into: [String: [[String: Any]]]()) { sections, direction in
            let currentUID = source.defaultDevice(for: direction)?.uid
            let entries: [[String: Any]] =
                devices
                .filter { $0.isDirection(direction) }
                .map { device in
                    [
                        "name": device.name,
                        "transport": device.transportClass.rawValue,
                        "excluded": !device.isManaged,
                        "current": device.uid == currentUID,
                    ]
                }
            sections[direction.rawValue] = entries
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

    let blocks = directions.map { direction -> [String] in
        let current = source.defaultDevice(for: direction)
        let row = { (device: AudioDevice) -> String in
            let marker = current?.uid == device.uid ? "*" : " "
            let suffix = device.isManaged ? "" : " [\(device.transportClass.rawValue)]"
            return "\(marker) \(device.name)\(suffix)"
        }
        let managed = engine.orderedManagedDevices(direction, devices: devices).map(row)
        let excluded =
            devices
            .filter { $0.isDirection(direction) && !$0.isManaged }
            .sorted { $0.name.compare($1.name, options: .caseInsensitive) == .orderedAscending }
            .map(row)
        return ["\(direction.rawValue):"] + managed + excluded
    }
    return CommandOutput(lines: blocks.flatMap { $0 })
}

func runCurrent(
    _ options: Options,
    source: DeviceSource
) throws -> CommandOutput {
    let directions = try selectedDirections(options)
    let lines: [String] = try directions.map { direction -> String in
        let device = source.defaultDevice(for: direction)
        if options.positional.count > 1 {
            guard let device = device else {
                throw CliFailure.noDevice("no default \(direction.rawValue) device")
            }
            return device.name
        }
        return "\(direction.rawValue): \(device?.name ?? "none")"
    }
    return CommandOutput(lines: lines)
}

func runSet(
    _ options: Options,
    source: DeviceSource
) throws -> CommandOutput {
    try requireRealDeviceContext(options)
    guard options.positional.count >= 3 else {
        throw CliFailure.usage("usage: \(programName) set <output|input> <device name>")
    }
    let direction = try tailDirection(options, usage: "set <output|input> <device name>")
    let name = options.positional[2...].joined(separator: " ")
    let current = source.defaultDevice(for: direction)
    switch resolveDevice(direction, name: name, devices: source.allDevices()) {
    case .notFound:
        throw CliFailure.noDevice("no \(direction.rawValue) device matching '\(name)'")
    case .ambiguous(let candidates):
        throw CliFailure.ambiguous(direction: direction.rawValue, name: name, candidates: candidates)
    case .matched(let device):
        if current?.uid == device.uid {
            return CommandOutput(lines: ["\(direction.rawValue): already \(device.name)"])
        }
        if options.dryRun {
            return CommandOutput(lines: ["\(direction.rawValue): would set to \(device.name)"])
        }
        let status = source.setDefault(device, direction: direction)
        guard status == noErr else {
            throw CliFailure.software(
                "failed to set \(direction.rawValue) to \(device.name): OSStatus \(status)"
            )
        }
        return CommandOutput(lines: ["\(direction.rawValue): set to \(device.name)"])
    }
}

func runReapply(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requireRealDeviceContext(options)
    let devices = source.allDevices()
    let plan = planApply(source: source, engine: engine, devices: devices, force: true)
    let lines = renderPlan(plan, dryRun: options.dryRun)
    try performPlan(plan, on: source, dryRun: options.dryRun)
    return CommandOutput(lines: lines)
}

func runCycle(
    _ options: Options,
    source: DeviceSource,
    engine: PriorityEngine
) throws -> CommandOutput {
    try requireRealDeviceContext(options)
    let direction = try tailDirection(options, usage: "cycle <output|input>")
    let devices = source.allDevices()
    let current = source.defaultDevice(for: direction)
    guard let target = engine.cycleTarget(direction, current: current, devices: devices) else {
        throw CliFailure.noDevice("no visible \(direction.rawValue) devices to cycle")
    }
    if current?.uid == target.uid {
        return CommandOutput(lines: ["\(direction.rawValue): unchanged (\(target.name))"])
    }
    if options.dryRun {
        return CommandOutput(lines: ["\(direction.rawValue): would cycle to \(target.name)"])
    }
    let status = source.setDefault(target, direction: direction)
    guard status == noErr else {
        throw CliFailure.software(
            "failed to cycle \(direction.rawValue) to \(target.name): OSStatus \(status)"
        )
    }
    return CommandOutput(lines: ["\(direction.rawValue): cycled to \(target.name)"])
}

// MARK: - menu-text (deterministic rendering of the dropdown + status icons)

/// The current menubar status line: two slot symbols.
func renderStatusLine(source: DeviceSource, engine: PriorityEngine) -> String {
    let outSymbol = engine.slotSymbol(for: source.defaultDevice(for: .output), direction: .output)
    let inSymbol = engine.slotSymbol(for: source.defaultDevice(for: .input), direction: .input)
    return "status: \(outSymbol) \(inSymbol)"
}

func renderMenu(
    source: DeviceSource,
    engine: PriorityEngine
) -> [String] {
    let devices = source.allDevices()
    let statusLine = renderStatusLine(source: source, engine: engine)
    let blocks: [String] = [(Direction.output, "speaker"), (Direction.input, "microphone")]
        .flatMap { direction, title -> [String] in
            var lines = ["\(title)-menu:"]
            if let current = source.defaultDevice(for: direction), !current.isManaged {
                // Out-of-domain current device: the app deliberately does not
                // touch it — say so instead of silently hiding it.
                lines.append("  - Current: \(current.name) (not managed)")
            }
            let rows: [String] = engine.orderedManagedDevices(direction, devices: devices)
                .map { device in
                    let check = source.defaultDevice(for: direction)?.uid == device.uid ? "✓" : "·"
                    let symbol = engine.entrySymbol(for: device, direction: direction)
                    return "  \(check) \(device.name) [\(symbol)]"
                }
            lines.append(contentsOf: rows)
            return lines
        }
    return [statusLine] + blocks
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
    case "set": return try runSet(options, source: source)
    case "reapply": return try runReapply(options, source: source, engine: engine)
    case "cycle": return try runCycle(options, source: source, engine: engine)
    case "menu-text": return CommandOutput(lines: renderMenu(source: source, engine: engine))
    case "auto":
        // Hidden test seam: models the GUI's automatic path (list change →
        // per-direction apply, respecting the excluded-current guard).
        try requireRealDeviceContext(options)
        let devices = source.allDevices()
        let plan = planApply(source: source, engine: engine, devices: devices, force: false)
        let lines = renderPlan(plan, dryRun: options.dryRun)
        try performPlan(plan, on: source, dryRun: options.dryRun)
        return CommandOutput(lines: lines)
    default:
        throw CliFailure.usage("unknown command '\(command)' — see --help")
    }
}
