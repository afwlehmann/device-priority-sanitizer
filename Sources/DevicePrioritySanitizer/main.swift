import AVFoundation
import AppKit
import CoreAudio
import Foundation

// MARK: - Config lookup (I/O boundary)

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

/// Real CoreAudio + AVFoundation unless a fixture table was injected
/// (headless test seam).
func makeSource(from options: Options, config: AppConfig) throws -> DeviceSource {
    guard let devicesPath = options.devicesPath else {
        return SystemDeviceSource(manageSoundEffects: config.managesSoundEffects)
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
    var statePath: String?
    var dryRun = false
    var json = false
    var tier: String?
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
        case "--state":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--state requires a path")
            }
            statePath = value
        case "--tier":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--tier requires a title")
            }
            tier = value
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
        statePath: statePath,
        dryRun: dryRun,
        json: json,
        tier: tier,
        positional: positional
    )
}

func printUsage() {
    print(
        """
        Usage: \(programName) [flags] [command]

        Commands:
          list [output|input|camera]    List devices (current marked with *; includes excluded)
          current [output|input|camera] Print current device name(s)
          set <output|input|camera> <name>
                                       Set the default device by name
          set <output|input|camera> --tier <title>
                                       Set the best connected device in a configured tier
          reapply                       Force-apply the configured priority (all managed targets)
          cycle <output|input|camera>  Advance to the next visible device (wrapping)
          enable                        Enable automatic prioritization
          disable                       Disable automatic prioritization
          status [--json]               Show the switch and per-target managed state
          menu-text                     Print the dropdown as deterministic text (test seam)

        Flags:
          --config <path>    Config JSON (default: ~/Library/Application Support/device-priority-sanitizer/config.json)
          --devices <path>   Device table JSON fixture (headless test seam; writes require --dry-run)
          --state <path>     Runtime state JSON (default: ~/Library/Application Support/device-priority-sanitizer/state.json)
          --tier <title>     Tier for `set` (titles come from the configured tiers)
          --dry-run          Report intended changes without applying them
          --json             Machine-readable output for `list`
          --help             Show this help

        Without a command the app runs as a menubar accessory.

        Cameras follow the system-preferred camera; apps with their own pinned
        camera picker (e.g. Zoom) must be set to "System Default" to follow it.

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
    private let statePath: String
    private var prioritizationEnabled: Bool
    private var devices: [MediaDevice] = []
    private var previousSets: [Target: Set<String>] = [:]
    private var debounceTimer: Timer?
    private struct RegisteredListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var listeners: [RegisteredListener] = []
    private var cameraObservers: [NSObjectProtocol] = []
    private var stateObserver: NSObjectProtocol?
    /// Class-property KVO context for `AVCaptureDevice.systemPreferredCamera`.
    private var preferredCameraKVOContext = 0

    init(config: AppConfig, source: DeviceSource, engine: PriorityEngine, statePath: String) {
        self.config = config
        self.source = source
        self.engine = engine
        self.statePath = statePath
        prioritizationEnabled = resolveState(statePath).prioritizationEnabled
        menuController = MenuController(engine: engine, source: source)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController.onSelect = { [weak self] target, device in
            guard let self = self else { return }
            let status = self.source.setDefault(device, target: target)
            if status != noErr {
                logStderr("failed to select \(device.name): OSStatus \(status)")
            }
            self.refreshMenu()
        }
        menuController.onCycle = { [weak self] target in
            guard let self = self else { return }
            let current = self.source.defaultDevice(for: target)
            guard
                let next = self.engine.cycleTarget(
                    target, current: current, devices: self.devices
                )
            else { return }
            let status = self.source.setDefault(next, target: target)
            if status != noErr {
                logStderr("failed to cycle \(target.rawValue) to \(next.name): OSStatus \(status)")
            }
            self.refreshMenu()
        }
        menuController.onReapply = { [weak self] in
            guard let self = self else { return }
            // Explicit user action: bypasses the excluded-current guard.
            // A globally disabled switch still wins — the menu item is
            // greyed, but stay defensive here.
            let plan = planApply(
                source: self.source,
                engine: self.engine,
                devices: self.devices,
                force: true,
                prioritizationEnabled: self.prioritizationEnabled
            )
            do {
                try performPlan(plan, on: self.source, dryRun: false)
            } catch {
                logStderr("\(error)")
            }
            self.refreshMenu()
        }
        menuController.onTogglePrioritization = { [weak self] in
            self?.togglePrioritization()
        }

        registerListeners()
        registerCameraObservers()
        registerStateObserver()
        reloadAndApply(initial: true)
    }

    // MARK: Prioritization switch

    /// Menubar toggle: write the state, refresh, and apply immediately when
    /// enabling. Disabling never restores previous devices — it only stops
    /// future automatic writes. A failed write logs and reverts the menu.
    private func togglePrioritization() {
        let newValue = !prioritizationEnabled
        do {
            try saveState(
                PrioritizationState(prioritizationEnabled: newValue), to: statePath
            )
        } catch {
            logStderr("failed to write state at \(statePath): \(error)")
            refreshMenu()
            return
        }
        prioritizationEnabled = newValue
        logStderr("prioritization \(newValue ? "enabled" : "disabled")")
        if newValue {
            reloadAndApply(initial: true)
        } else {
            refreshMenu()
        }
    }

    /// The CLI posts `stateChanged` after writing the state file; reload and
    /// apply when the switch was turned on, otherwise just refresh the menu.
    private func registerStateObserver() {
        stateObserver = DistributedNotificationCenter.default().addObserver(
            forName: stateChangedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let wasEnabled = self.prioritizationEnabled
            self.prioritizationEnabled = resolveState(self.statePath).prioritizationEnabled
            if self.prioritizationEnabled && !wasEnabled {
                self.reloadAndApply(initial: true)
            } else {
                self.refreshMenu()
            }
        }
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

    /// Camera hotplug and preferred-camera changes: `wasConnected`/
    /// `wasDisconnected` drive the debounced device-list pass; KVO on
    /// `systemPreferredCamera` (a class property — documented as
    /// KVO-observable) refreshes the menu when another app changes the
    /// preferred camera.
    private func registerCameraObservers() {
        cameraObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.deviceListChanged() }
        )
        cameraObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.deviceListChanged() }
        )
        AVCaptureDevice.self.addObserver(
            self,
            forKeyPath: "systemPreferredCamera",
            options: [.new],
            context: &preferredCameraKVOContext
        )
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &preferredCameraKVOContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenu()
        }
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
        for target in Target.allCases {
            let newSet = Set(
                devices.filter { $0.supports(target) }
                    .map { $0.uid }
            )
            let old = previousSets[target]
            previousSets[target] = newSet
            if initial || old != newSet {
                applyAuto(target: target)
            }
        }
        refreshMenu()
    }

    /// Auto-selection: only on a per-target device-set change, never over a
    /// synthetic (excluded) current device, and never while the global
    /// prioritization switch is off.
    private func applyAuto(target: Target) {
        guard prioritizationEnabled else { return }
        if let current = source.defaultDevice(for: target), !current.isManaged {
            logStderr("skip \(target.rawValue): current '\(current.name)' is not managed")
            return
        }
        guard
            let device = engine.targetDevice(
                target,
                current: source.defaultDevice(for: target),
                devices: devices
            )
        else { return }
        guard source.defaultDevice(for: target)?.uid != device.uid else { return }
        let status = source.setDefault(device, target: target)
        logStderr("\(target.rawValue): set to \(device.name) (status \(status))")
    }

    private func refreshMenu() {
        menuController.update(devices: devices, prioritizationEnabled: prioritizationEnabled)
    }
}

func runGUI(
    config: AppConfig,
    source: DeviceSource,
    engine: PriorityEngine,
    statePath: String
) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(config: config, source: source, engine: engine, statePath: statePath)
    app.delegate = delegate
    app.run()
    // NSApplication.run never returns on the GUI path; satisfy Never on all
    // paths for the type checker.
    fatalError("unreachable")
}

// MARK: - Bootstrap (I/O boundary)

func bootstrap(_ options: Options) throws -> (config: AppConfig, engine: PriorityEngine, source: DeviceSource) {
    let config = try loadConfig(options.configPath)
    let engine: PriorityEngine
    do {
        engine = try PriorityEngine(config: config)
    } catch let error as PriorityEngine.InvalidRegexError {
        throw CliFailure.dataInvalid("\(error)")
    }
    let source = try makeSource(from: options, config: config)
    return (config, engine, source)
}

func renderFailure(_ failure: CliFailure) -> Never {
    failure.lines.forEach { line in
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
    exit(failure.exitCode)
}

/// Prints command output and exits with its exit code (0 when unset).
func finish(_ output: CommandOutput) -> Never {
    output.lines.forEach { print($0) }
    exit(output.exitCode ?? 0)
}

func main() -> Never {
    do {
        let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        if options.helpRequested {
            printUsage()
            exit(0)
        }
        // The prioritization switch is state-only: enable/disable never load
        // the tier config (a broken config must not prevent disabling), and
        // status reads the config leniently without compiling tier regexes.
        switch options.positional.first {
        case "enable":
            finish(try runPrioritizationSwitch(options, enabled: true))
        case "disable":
            finish(try runPrioritizationSwitch(options, enabled: false))
        case "status":
            finish(try runStatus(options))
        default:
            break
        }
        let context = try bootstrap(options)
        guard let command = options.positional.first else {
            runGUI(
                config: context.config,
                source: context.source,
                engine: context.engine,
                statePath: options.statePath ?? defaultStatePath()
            )
        }
        let output = try runCommand(command, options, context.source, context.engine)
        finish(output)
    } catch let failure as CliFailure {
        renderFailure(failure)
    } catch {
        logStderr("unexpected error: \(error)")
        exit(EXIT_FAILURE)
    }
}

main()
