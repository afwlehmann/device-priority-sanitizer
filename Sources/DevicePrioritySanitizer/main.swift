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
    var levelsPath: String?
    var launchdPlistPath: String?
    var appBundlePath: String?
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
        case "--levels":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--levels requires a path")
            }
            levelsPath = value
        case "--launchd-plist":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--launchd-plist requires a path")
            }
            launchdPlistPath = value
        case "--app-bundle":
            guard let value = iterator.next() else {
                throw CliFailure.usage("--app-bundle requires a path")
            }
            appBundlePath = value
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
        levelsPath: levelsPath,
        launchdPlistPath: launchdPlistPath,
        appBundlePath: appBundlePath,
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
          start                         Start the app (launchd agent when installed, else launch the bundle)
          stop                          Stop the app (boots out the launchd agent; manual instances terminate)
          volume get <output|input>      Print the current device's volume (0…1)
          volume set <output|input> <0…1>
                                        Set the current device's volume live
          volume save <output|input>    Save the current device's volume as its restore level
          volume clear <output|input>   Remove the current device's saved restore level
          volume show [--json]         List saved restore levels
          config                        Open the configuration window (AppKit)
          menu-text                     Print the dropdown as deterministic text (test seam)

        Flags:
          --config <path>    Config JSON (default: ~/Library/Application Support/device-priority-sanitizer/config.json)
          --devices <path>   Device table JSON fixture (headless test seam; writes require --dry-run)
          --state <path>     Runtime state JSON (default: ~/Library/Application Support/device-priority-sanitizer/state.json)
          --levels <path>    Saved volume levels JSON (default: ~/Library/Application Support/device-priority-sanitizer/levels.json)
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
    private let options: Options
    private let configPath: String
    private let statePath: String
    private let levelsPath: String
    private var config: AppConfig
    private var source: DeviceSource
    private var engine: PriorityEngine
    private let menuController: MenuController
    private var prioritizationEnabled: Bool
    private var devices: [MediaDevice] = []
    private var previousSets: [Target: Set<String>] = [:]
    private var debounceTimer: Timer?
    private var configWindow: ConfigWindowController?
    private struct RegisteredListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var listeners: [RegisteredListener] = []
    private var cameraObservers: [NSObjectProtocol] = []
    private var stateObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var levelsObserver: NSObjectProtocol?
    /// Class-property KVO context for `AVCaptureDevice.systemPreferredCamera`.
    private var preferredCameraKVOContext = 0

    init(
        options: Options,
        config: AppConfig,
        source: DeviceSource,
        engine: PriorityEngine,
        statePath: String
    ) {
        self.options = options
        self.configPath = options.configPath ?? defaultConfigPath()
        self.config = config
        self.source = source
        self.engine = engine
        self.statePath = statePath
        self.levelsPath = options.levelsPath ?? defaultLevelsPath()
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
            } else {
                self.restoreLevelAfterActivation(device, target: target)
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
            } else {
                self.restoreLevelAfterActivation(next, target: target)
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
                for change in plan where change.device != nil && change.current?.uid != change.device?.uid {
                    self.restoreLevelAfterActivation(change.device!, target: change.target)
                }
            } catch {
                logStderr("\(error)")
            }
            self.refreshMenu()
        }
        menuController.onTogglePrioritization = { [weak self] in
            self?.togglePrioritization()
        }
        menuController.onConfigure = { [weak self] in
            self?.openConfigWindow()
        }
        menuController.onQuit = {
            // Boots out the launchd job when supervised — KeepAlive would
            // resurrect a plain exit; manual instances terminate directly.
            stopAgentFromWithinApp()
        }
        menuController.onSetVolume = { [weak self] target, level in
            guard let self, let current = self.source.defaultDevice(for: target) else { return }
            let status = self.source.setVolume(level, for: current, target: target)
            if status != noErr {
                logStderr("failed to set \(target.rawValue) volume for \(current.name): OSStatus \(status)")
            }
        }
        menuController.onSaveLevel = { [weak self] target in
            self?.saveCurrentLevel(for: target)
        }
        menuController.onClearLevel = { [weak self] target in
            (self?.clearCurrentLevel(for: target)) ?? false
        }
        menuController.onLevelState = { [weak self] target in
            self?.levelRowState(for: target) ?? LevelRowState(deviceName: nil, liveLevel: nil, savedLevel: nil)
        }

        registerListeners()
        registerCameraObservers()
        registerStateObserver()
        registerConfigObserver()
        registerLevelsObserver()
        reloadAndApply(initial: true)
    }

    // MARK: Configuration window

    /// The menubar "Configure Devices…" window. Owned by the agent: closing
    /// the window only releases the edit lock, never the agent.
    private func openConfigWindow() {
        if let configWindow {
            configWindow.show()
            return
        }
        let window = ConfigWindowController(
            configPath: configPath,
            statePath: statePath,
            source: source,
            standalone: false
        ) { [weak self] newConfig in
            self?.reloadConfiguration(newConfig)
        }
        if window.failedToOpen {
            logStderr("configuration window could not open — see the alert")
            return
        }
        configWindow = window
        window.show()
    }

    /// Rebuilds engine + source from a (validated) config and re-applies. The
    /// source is rebuilt via the original options so a fixture-injected agent
    /// (`--devices`) keeps its seam; `manageSoundEffects` changes take
    /// effect immediately.
    private func reloadConfiguration(_ newConfig: AppConfig) {
        do {
            engine = try PriorityEngine(config: newConfig)
            source = try makeSource(from: options, config: newConfig)
            config = newConfig
            menuController.update(engine: engine, source: source)
            reloadAndApply(initial: true)
        } catch {
            logStderr("failed to apply the new configuration: \(error)")
        }
    }

    /// A standalone config window saved: reload the config from disk (the
    /// window holds no reference to this agent) and apply.
    private func registerConfigObserver() {
        configObserver = DistributedNotificationCenter.default().addObserver(
            forName: configChangedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            do {
                self.reloadConfiguration(try loadConfig(self.configPath))
            } catch {
                logStderr("config-changed reload failed: \(error)")
            }
        }
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

    /// The CLI posts `levelsChanged` after a `volume save/clear` on the
    /// default path; the saved-state markers and Clear buttons must follow.
    private func registerLevelsObserver() {
        levelsObserver = DistributedNotificationCenter.default().addObserver(
            forName: levelsChangedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMenu()
        }
    }

    // MARK: Per-device volume levels

    /// The row snapshot for one audio target: the current device, its live
    /// level, and the stored level that applies to it (exact UID or unique
    /// replacement match). Camera never reaches here.
    private func levelRowState(for target: Target) -> LevelRowState {
        let current = source.defaultDevice(for: target)
        let match = current.map { savedLevelFor($0, target: target) } ?? .none
        return LevelRowState(
            deviceName: current?.name,
            liveLevel: current.flatMap { source.volume(for: $0, target: target) },
            savedLevel: match.entry?.level
        )
    }

    private func savedLevelFor(_ device: MediaDevice, target: Target) -> LevelMatch {
        savedLevel(
            for: device,
            target: target,
            document: loadLevelsDocument(levelsPath),
            connectedUIDs: Set(devices.map(\.uid))
        )
    }

    /// Menubar Save: upsert the current device's entry. Returns the saved
    /// value (the row updates its marker and Clear button), `nil` on failure.
    private func saveCurrentLevel(for target: Target) -> Float? {
        guard
            let current = source.defaultDevice(for: target),
            let level = source.volume(for: current, target: target)
        else { return nil }
        var document = loadLevelsDocument(levelsPath)
        document.upsert(
            SavedLevel(
                uid: current.uid,
                name: current.name,
                modelUID: current.modelUID,
                transport: current.transportClass,
                level: level,
                savedAt: currentTimestamp()
            ),
            for: target
        )
        do {
            try saveLevelsDocument(document, to: levelsPath)
        } catch {
            logStderr("failed to write saved levels at \(levelsPath): \(error)")
            return nil
        }
        return level
    }

    /// Menubar Clear: removes the entry applying to the current device —
    /// its exact-UID entry, or the unique replacement entry that restored it.
    private func clearCurrentLevel(for target: Target) -> Bool {
        guard let current = source.defaultDevice(for: target) else { return false }
        var document = loadLevelsDocument(levelsPath)
        guard let entry = savedLevelFor(current, target: target).entry else { return false }
        document.remove(uid: entry.uid, for: target)
        do {
            try saveLevelsDocument(document, to: levelsPath)
        } catch {
            logStderr("failed to write saved levels at \(levelsPath): \(error)")
            return false
        }
        return true
    }

    /// Restore hook after an activation (menu pick, cycle, reapply,
    /// auto-selection): applies the device's saved level, best-effort. NOT
    /// called for an already-current device at startup, nor for external
    /// default changes — a saved level never overwrites a change the user
    /// made outside this app's activations.
    private func restoreLevelAfterActivation(_ device: MediaDevice, target: Target) {
        let outcome = restoreSavedLevel(
            device: device,
            target: target,
            source: source,
            document: loadLevelsDocument(levelsPath),
            connectedUIDs: Set(devices.map(\.uid)),
            perform: true
        )
        switch outcome {
        case .restored(let level, let replacement):
            logStderr(
                "\(target.rawValue): restored saved level \(levelPercent(level))%"
                    + (replacement ? " (replacement match)" : ""))
        case .failed(let status):
            logStderr("failed to restore saved level for \(device.name): OSStatus \(status)")
        case .noEntry, .unsupported:
            break
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
        if status == noErr {
            restoreLevelAfterActivation(device, target: target)
        }
    }

    private func refreshMenu() {
        menuController.update(devices: devices, prioritizationEnabled: prioritizationEnabled)
    }
}

func runGUI(
    options: Options,
    config: AppConfig,
    source: DeviceSource,
    engine: PriorityEngine,
    statePath: String
) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(
        options: options, config: config, source: source, engine: engine, statePath: statePath
    )
    app.delegate = delegate
    app.run()
    // NSApplication.run never returns on the GUI path; satisfy Never on all
    // paths for the type checker.
    fatalError("unreachable")
}

// MARK: - Standalone configuration window (CLI `config`)

/// Owns the NSApplication lifecycle of a `config` CLI invocation: the process
/// quits when the (only) window closes, releasing the edit lock via the
/// window delegate on the way out.
final class ConfigStandaloneDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Runs the configuration window as its own accessory process. Device
/// enumeration goes through the same source seam (fixtures work for
/// screenshots); a save posts the config-changed notification so a running
/// agent reloads — there is nothing to apply in this process.
func runConfigUI(_ options: Options) -> Never {
    let source: DeviceSource
    do {
        source = try makeSource(
            from: options,
            config: AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        )
    } catch let failure as CliFailure {
        renderFailure(failure)
    } catch {
        logStderr("unexpected error: \(error)")
        exit(EXIT_FAILURE)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = ConfigStandaloneDelegate()
    app.delegate = delegate
    let window = ConfigWindowController(
        configPath: options.configPath ?? defaultConfigPath(),
        statePath: options.statePath ?? defaultStatePath(),
        source: source,
        standalone: true,
        onSaveApply: nil
    )
    window.show()
    app.run()
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
        // Lifecycle control needs neither config nor engine — stopping the
        // app must always be possible.
        switch options.positional.first {
        case "enable":
            finish(try runPrioritizationSwitch(options, enabled: true))
        case "disable":
            finish(try runPrioritizationSwitch(options, enabled: false))
        case "status":
            finish(try runStatus(options))
        case "start":
            finish(try runAgentCommand(.start, options))
        case "stop":
            finish(try runAgentCommand(.stop, options))
        case "volume":
            // Volume control needs no tier config — only a device source
            // (real, or the `--devices` fixture seam).
            let volumeSource: DeviceSource
            do {
                volumeSource = try makeSource(
                    from: options,
                    config: AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil))
            } catch let failure as CliFailure {
                renderFailure(failure)
            } catch {
                logStderr("unexpected error: \(error)")
                exit(EXIT_FAILURE)
            }
            finish(try runVolumeCommand(options, source: volumeSource))
        case "config":
            try requirePositionalArguments(options, atMost: 1, usage: "config")
            runConfigUI(options)
        default:
            break
        }
        // GUI mode owns agent.log from here on (rotation + stream redirect),
        // so the config warnings below land in the log as well.
        if options.positional.isEmpty {
            setUpAgentLogging()
        }
        let context = try bootstrap(options)
        guard let command = options.positional.first else {
            runGUI(
                options: options,
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
