import AppKit
import CoreAudio
import Foundation

let programVersion = "0.1.0"

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data("[\(programName)] \(message)\n".utf8))
}

// MARK: - Config lookup (I/O boundary)

func defaultConfigPath() -> String {
    if let envPath = ProcessInfo.processInfo.environment["AUDIO_PRIORITY_SANITIZER_CONFIG"] {
        return envPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/audio-priority-sanitizer/config.json"
}

/// Loads the config JSON; a missing file is a warning (empty priority lists),
/// an unparseable file is `dataInvalid`.
func loadConfig(_ explicitPath: String?) throws -> AppConfig {
    let path = explicitPath ?? defaultConfigPath()
    guard FileManager.default.fileExists(atPath: path) else {
        logStderr("warning: no config found — running with empty priority lists")
        return AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(AppConfig.self, from: data)
    } catch {
        throw CliFailure.dataInvalid("invalid config at \(path): \(error)")
    }
}

/// Real CoreAudio unless a fixture table was injected (headless test seam).
func makeSource(from options: Options, config: AppConfig) throws -> DeviceSource {
    guard let devicesPath = options.devicesPath else {
        return CoreAudioDeviceSource(manageSoundEffects: config.managesSoundEffects)
    }
    do {
        return try FixtureDeviceSource(path: devicesPath, manageSoundEffects: config.managesSoundEffects)
    } catch {
        throw CliFailure.dataInvalid("invalid devices fixture \(devicesPath): \(error)")
    }
}

// MARK: - Argument parsing (pure fold over argv; failures are typed)

func parseArguments(_ arguments: [String]) throws -> Options {
    var configPath: String?
    var devicesPath: String?
    var dryRun = false
    var json = false
    var helpRequested = false
    var positional: [String] = []

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--config":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--config requires a path")
            }
            configPath = value
        case "--devices":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--devices requires a path")
            }
            devicesPath = value
        case "--dry-run":
            dryRun = true
        case "--json":
            json = true
        case "--help", "-h":
            helpRequested = true
        default:
            positional.append(argument)
        }
    }
    return Options(
        helpRequested: helpRequested,
        configPath: configPath,
        devicesPath: devicesPath,
        dryRun: dryRun,
        json: json,
        positional: positional
    )
}

func printUsage() {
    print(
        """
        Usage: \(programName) [flags] [command]

        Commands:
          list [output|input]         List devices (current marked with *; includes excluded)
          current [output|input]      Print current device name(s)
          set <output|input> <name>   Set the default device by name
          reapply                     Force-apply the configured priority (both directions)
          cycle <output|input>        Advance to the next visible device (wrapping)
          menu-text                   Print the dropdown as deterministic text (test seam)

        Flags:
          --config <path>    Config JSON (default: ~/Library/Application Support/audio-priority-sanitizer/config.json)
          --devices <path>   Device table JSON fixture (headless test seam; writes require --dry-run)
          --dry-run          Report intended changes without applying them
          --json             Machine-readable output for `list`
          --help             Show this help

        Without a command the app runs as a menubar accessory.

        Exit codes: 64 usage, 65 invalid config/fixture, 66 no device, 3 ambiguous, 70 software error.
        """
    )
}

// MARK: - GUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private let source: DeviceSource
    private let engine: PriorityEngine
    private let menuController: MenuController
    private var devices: [AudioDevice] = []
    private var previousSets: [Direction: Set<String>] = [:]
    private var debounceTimer: Timer?
    private struct RegisteredListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var listeners: [RegisteredListener] = []

    init(config: AppConfig, source: DeviceSource, engine: PriorityEngine) {
        self.config = config
        self.source = source
        self.engine = engine
        menuController = MenuController(engine: engine, source: source)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController.onSelect = { [weak self] direction, device in
            guard let self = self else { return }
            let status = self.source.setDefault(device, direction: direction)
            if status != noErr {
                logStderr("failed to select \(device.name): OSStatus \(status)")
            }
            self.refreshMenu()
        }
        menuController.onCycle = { [weak self] direction in
            guard let self = self else { return }
            let current = self.source.defaultDevice(for: direction)
            guard
                let target = self.engine.cycleTarget(
                    direction, current: current, devices: self.devices
                )
            else { return }
            let status = self.source.setDefault(target, direction: direction)
            if status != noErr {
                logStderr("failed to cycle \(direction.rawValue) to \(target.name): OSStatus \(status)")
            }
            self.refreshMenu()
        }
        menuController.onReapply = { [weak self] in
            guard let self = self else { return }
            // Explicit user action: bypasses the excluded-current guard.
            let plan = planApply(
                source: self.source,
                engine: self.engine,
                devices: self.devices,
                force: true
            )
            do {
                try performPlan(plan, on: self.source, dryRun: false)
            } catch {
                logStderr("\(error)")
            }
            self.refreshMenu()
        }

        registerListeners()
        reloadAndApply(initial: true)
    }

    // MARK: Listeners

    private func addListener(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping () -> Void
    ) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let observer: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        listeners.append(RegisteredListener(address: addr, block: observer))
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main, observer)
        if status != noErr {
            logStderr("failed to register listener (selector \(selector)): OSStatus \(status)")
        }
    }

    private func removeListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for listener in listeners {
            var addr = listener.address
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, .main, listener.block)
        }
        listeners.removeAll()
    }

    private func registerListeners() {
        addListener(kAudioHardwarePropertyDevices) { [weak self] in self?.deviceListChanged() }
        addListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.defaultsChanged() }
        addListener(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.defaultsChanged() }
        addListener(kAudioHardwarePropertyServiceRestarted) { [weak self] in self?.serviceRestarted() }
    }

    // MARK: State transitions

    private func deviceListChanged() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: config.debounceInterval,
            repeats: false
        ) { [weak self] _ in
            self?.reloadAndApply(initial: false)
        }
    }

    private func defaultsChanged() {
        refreshMenu()
    }

    private func serviceRestarted() {
        logStderr("coreaudiod restarted — re-registering listeners")
        // CoreAudio drops every property listener when the service restarts.
        removeListeners()
        registerListeners()
        reloadAndApply(initial: true)
    }

    private func reloadAndApply(initial: Bool) {
        devices = source.allDevices()
        for direction in Direction.allCases {
            let newSet = Set(
                devices.filter { $0.isDirection(direction) }
                    .map { $0.uid }
            )
            let old = previousSets[direction]
            previousSets[direction] = newSet
            if initial || old != newSet {
                applyAuto(direction: direction)
            }
        }
        refreshMenu()
    }

    /// Auto-selection: only on a per-direction device-set change, never over a
    /// synthetic (excluded) current device.
    private func applyAuto(direction: Direction) {
        if let current = source.defaultDevice(for: direction), !current.isManaged {
            logStderr("skip \(direction.rawValue): current '\(current.name)' is not managed")
            return
        }
        guard
            let target = engine.targetDevice(
                direction,
                current: source.defaultDevice(for: direction),
                devices: devices
            )
        else { return }
        guard source.defaultDevice(for: direction)?.uid != target.uid else { return }
        let status = source.setDefault(target, direction: direction)
        logStderr("\(direction.rawValue): set to \(target.name) (status \(status))")
    }

    private func refreshMenu() {
        menuController.update(devices: devices)
    }
}

func runGUI(
    config: AppConfig,
    source: DeviceSource,
    engine: PriorityEngine
) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(config: config, source: source, engine: engine)
    app.delegate = delegate
    app.run()
    // NSApplication.run never returns on the GUI path; satisfy Never on all
    // paths for the type checker.
    fatalError("unreachable")
}

// MARK: - Bootstrap (I/O boundary)

func bootstrap() throws -> (options: Options, config: AppConfig, engine: PriorityEngine, source: DeviceSource) {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    if options.helpRequested {
        printUsage()
        exit(0)
    }
    let config = try loadConfig(options.configPath)
    let engine: PriorityEngine
    do {
        engine = try PriorityEngine(config: config)
    } catch let error as PriorityEngine.InvalidRegexError {
        throw CliFailure.dataInvalid("\(error)")
    }
    let source = try makeSource(from: options, config: config)
    return (options, config, engine, source)
}

func renderFailure(_ failure: CliFailure) -> Never {
    failure.lines.forEach { line in
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
    exit(failure.exitCode)
}

func main() -> Never {
    do {
        let context = try bootstrap()
        guard let command = context.options.positional.first else {
            runGUI(config: context.config, source: context.source, engine: context.engine)
        }
        let output = try runCommand(command, context.options, context.source, context.engine)
        output.lines.forEach { print($0) }
        exit(0)
    } catch let failure as CliFailure {
        renderFailure(failure)
    } catch {
        logStderr("unexpected error: \(error)")
        exit(EXIT_FAILURE)
    }
}

main()
