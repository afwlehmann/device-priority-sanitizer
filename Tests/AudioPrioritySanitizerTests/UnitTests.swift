import Foundation

// The unit test cases. Pure logic only — the DeviceSource doubles keep every
// test fully isolated from CoreAudio, and each test builds fresh fixtures.

func runUnitTests() {
    // MARK: Regex semantics

    run("matching is case-sensitive") {
        let engine = try Fixtures.engine()
        let caseMismatched = AudioDevice(
            id: 9, uid: "lower", name: "jabra speak 510 usb",
            transportClass: .usb, isOutput: true, isInput: true
        )
        try expectEqual(
            engine.entrySymbol(for: caseMismatched, direction: .output),
            "speaker.wave.3",
            "lowercase name must fall through to the fallback"
        )
    }

    run("matching is unanchored") {
        let engine = try Fixtures.engine()
        let stereo = AudioDevice(
            id: 10, uid: "stereo", name: "Jabra SPEAK 510 USB (Stereo)",
            transportClass: .usb, isOutput: true, isInput: true
        )
        try expectEqual(
            engine.entrySymbol(for: stereo, direction: .output),
            "hifispeaker.fill",
            "pattern must match a substring of the name"
        )
    }

    run("alternation matches every token of the tier") {
        let engine = try Fixtures.engine()
        for (uid, name) in [("h1", "Jabra Evolve 75 SE"), ("h2", "WH-1000XM2"), ("h3", "EarPods")] {
            let device = AudioDevice(
                id: 21, uid: uid, name: name, transportClass: .bluetooth, isOutput: true, isInput: true
            )
            try expectEqual(
                engine.entrySymbol(for: device, direction: .input),
                "headphones",
                "device \(name)"
            )
        }
    }

    run("invalid regex is fatal at construction") {
        let engine = { () -> PriorityEngine? in
            try? PriorityEngine(
                config: AppConfig(
                    outputs: [PriorityEntry(match: "([", symbol: "headphones")],
                    inputs: [],
                    fallbackSymbol: nil,
                    debounceMs: nil
                )
            )
        }()
        try check(engine == nil, "invalid regex must make construction fail")
    }

    // MARK: Priority: ordered first-match over tiers

    run("documented example: headset tier precedes the Jabra speaker tier") {
        let engine = try Fixtures.engine()
        let ordered = engine.orderedManagedDevices(.output, devices: Fixtures.devices())
        try expectEqual(
            ordered.map { $0.name },
            [
                "Jabra Evolve 75 SE",
                "Jabra SPEAK 510 USB",
                "MacBook Pro Speakers",
                "DELL U3824DW",
            ],
            "tier order must be headset, speaker, internal, fallback"
        )
    }

    run("target is the first tier with a matching device") {
        let engine = try Fixtures.engine()
        try expectEqual(
            engine.targetDevice(.input, current: nil, devices: Fixtures.devices())?.uid,
            "evolve",
            "headset tier wins for input"
        )
    }

    run("unmatched devices sort alphabetically after the tiers") {
        let engine = try Fixtures.engine()
        let extra = AudioDevice(
            id: 31, uid: "generic", name: "Aardvark USB Audio",
            transportClass: .usb, isOutput: true, isInput: false
        )
        let ordered = engine.orderedManagedDevices(.output, devices: Fixtures.devices() + [extra])
        try expectEqual(
            ordered.map { $0.name },
            [
                "Jabra Evolve 75 SE",
                "Jabra SPEAK 510 USB",
                "MacBook Pro Speakers",
                "Aardvark USB Audio",
                "DELL U3824DW",
            ],
            "unmatched devices sort alphabetically"
        )
    }

    run("synthetic transports are never managed") {
        let engine = try Fixtures.engine()
        let ordered = engine.orderedManagedDevices(.output, devices: Fixtures.devices())
        try check(
            !ordered.contains { $0.uid == "teams" },
            "virtual device must be excluded from the managed list"
        )
    }

    run("output and input are independent") {
        let engine = try Fixtures.engine()
        let outputOnly = Fixtures.devices().filter { $0.isOutput }
        let inputOnly = Fixtures.devices().filter { $0.isInput }
        try expectEqual(
            engine.targetDevice(.output, current: nil, devices: outputOnly)?.uid,
            "evolve",
            "output target"
        )
        try expectEqual(
            engine.targetDevice(.input, current: nil, devices: inputOnly)?.uid,
            "evolve",
            "input target"
        )
    }

    run("tier fall-through when the headset is absent") {
        let engine = try Fixtures.engine()
        let noHeadset = Fixtures.devices().filter { $0.uid != "evolve" }
        try expectEqual(
            engine.targetDevice(.output, current: nil, devices: noHeadset)?.uid,
            "jabra510",
            "output falls through to the speaker tier"
        )
        try expectEqual(
            engine.targetDevice(.input, current: nil, devices: noHeadset)?.uid,
            "jabra510",
            "input falls through to the speaker tier"
        )
    }

    run("current device is kept when it belongs to the winning tier") {
        // Tier 0 holds several equivalent headsets; a current member of the
        // winning tier must not be replaced by its alphabetically-first peer.
        let engine = try Fixtures.engine()
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            engine.targetDevice(.output, current: evolve, devices: Fixtures.devices())?.uid,
            "evolve",
            "current tier member is kept"
        )
        // A current device outside the winning tier does not hold it.
        let spk = Fixtures.devices().first { $0.uid == "spk" }!
        try expectEqual(
            engine.targetDevice(.output, current: spk, devices: Fixtures.devices())?.uid,
            "evolve",
            "non-member current is replaced by the tier's first device"
        )
    }

    // MARK: Cycle

    run("cycle advances in visible menu order") {
        let engine = try Fixtures.engine()
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            engine.cycleTarget(.output, current: evolve, devices: Fixtures.devices())?.uid,
            "jabra510",
            "next in menu order"
        )
    }

    run("cycle wraps from the last device to the first") {
        let engine = try Fixtures.engine()
        let dell = Fixtures.devices().first { $0.uid == "dell" }!
        try expectEqual(
            engine.cycleTarget(.output, current: dell, devices: Fixtures.devices())?.uid,
            "evolve",
            "wrap to the first visible device"
        )
    }

    run("cycle starts at the first device when none is current") {
        let engine = try Fixtures.engine()
        try expectEqual(
            engine.cycleTarget(.output, current: nil, devices: Fixtures.devices())?.uid,
            "evolve",
            "no current device → first"
        )
    }

    run("cycle is per-direction") {
        let engine = try Fixtures.engine()
        let mic = Fixtures.devices().first { $0.uid == "mic" }!
        try expectEqual(
            engine.cycleTarget(.input, current: mic, devices: Fixtures.devices())?.uid,
            "evolve",
            "input cycle order"
        )
    }

    // MARK: Symbols

    run("slot symbol reflects the tier, fallback, and excluded state") {
        let engine = try Fixtures.engine()
        let devices = Fixtures.devices()
        let evolve = devices.first { $0.uid == "evolve" }!
        let spk = devices.first { $0.uid == "spk" }!
        let mic = devices.first { $0.uid == "mic" }!
        let dell = devices.first { $0.uid == "dell" }!
        let teams = devices.first { $0.uid == "teams" }!

        try expectEqual(engine.slotSymbol(for: evolve, direction: .output), "headphones", "tier symbol")
        try expectEqual(engine.slotSymbol(for: mic, direction: .input), "laptopcomputer", "internal symbol")
        try expectEqual(
            engine.slotSymbol(for: spk, direction: .input),
            "mic",
            "output-only device falls back for the input direction"
        )
        try expectEqual(engine.slotSymbol(for: dell, direction: .output), "speaker.wave.3", "fallback symbol")
        try expectEqual(
            engine.slotSymbol(for: teams, direction: .output),
            PriorityEngine.excludedSymbol,
            "excluded symbol"
        )
        try expectEqual(engine.slotSymbol(for: nil, direction: .input), "mic", "no-device fallback")
    }

    // MARK: Config decoding

    run("config JSON decodes and provides fallbacks") {
        let json = """
            {
              "outputs": [{"match": "Evolve", "symbol": "headphones"}],
              "inputs": [],
              "fallbackSymbol": {"output": "speaker.wave.3", "input": "mic"},
              "debounceMs": 500
            }
            """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        try expectEqual(config.outputs.count, 1, "one output tier")
        try expectEqual(config.fallback(for: .input), "mic", "input fallback")
        try expectEqual(config.debounceInterval, 0.5, "debounce interval")
    }

    run("missing fallback and debounce fall back to sensible defaults") {
        let config = AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        try expectEqual(config.debounceInterval, 0.5, "default debounce")
        try expectEqual(config.fallback(for: .output), "speaker.wave.3", "default output fallback")
        try expectEqual(config.fallback(for: .input), "mic", "default input fallback")
    }

    run("sound-effects management defaults to enabled and decodes explicit false") {
        let defaults = AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        try check(defaults.managesSoundEffects, "missing field means enabled")
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"outputs": [], "inputs": [], "manageSoundEffects": false}"#.utf8)
        )
        try check(!config.managesSoundEffects, "explicit false disables the mirror")
    }

    // MARK: Device resolution (CLI set semantics)

    run("exact match wins over substring") {
        let match = resolveDevice(.output, name: "DELL U3824DW", devices: Fixtures.devices())
        guard case .matched(let device) = match else {
            throw UnitTestFailure("expected a match, got \(match)")
        }
        try expectEqual(device.uid, "dell", "exact match")
    }

    run("case-insensitive substring resolves a unique device") {
        let match = resolveDevice(.output, name: "macbook pro speak", devices: Fixtures.devices())
        guard case .matched(let device) = match else {
            throw UnitTestFailure("expected a match, got \(match)")
        }
        try expectEqual(device.uid, "spk", "substring match")
    }

    run("multiple candidates are ambiguous") {
        let match = resolveDevice(.output, name: "Jabra", devices: Fixtures.devices())
        guard case .ambiguous(let candidates) = match else {
            throw UnitTestFailure("expected ambiguity, got \(match)")
        }
        try expectEqual(candidates.map { $0.uid }, ["evolve", "jabra510"], "candidates")
    }

    run("duplicate exact names are ambiguous") {
        // Two identical headsets share a name: exact matching must not silently
        // pick one of them.
        let twin = AudioDevice(
            id: 41, uid: "evolve-twin", name: "Jabra Evolve 75 SE",
            transportClass: .bluetooth, isOutput: true, isInput: true
        )
        let match = resolveDevice(
            .output, name: "Jabra Evolve 75 SE", devices: Fixtures.devices() + [twin]
        )
        guard case .ambiguous(let candidates) = match else {
            throw UnitTestFailure("expected ambiguity, got \(match)")
        }
        try expectEqual(candidates.map { $0.uid }, ["evolve", "evolve-twin"], "both exact matches")
    }

    run("no candidate is notFound") {
        let match = resolveDevice(.output, name: "Nonexistent", devices: Fixtures.devices())
        guard case .notFound = match else {
            throw UnitTestFailure("expected notFound, got \(match)")
        }
    }

    run("direction filters candidates") {
        let match = resolveDevice(.input, name: "DELL", devices: Fixtures.devices())
        guard case .notFound = match else {
            throw UnitTestFailure("expected notFound for the wrong direction, got \(match)")
        }
    }

    // MARK: Planning (excluded-current guard, force bypass)

    run("auto: excluded current device is skipped without touching it") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "teams", input: "teams")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: false)
        try check(plan.allSatisfy(\.skippedExcluded), "every change must be skipped")
        try check(plan.allSatisfy { $0.target == nil }, "no targets may be computed")
        try expectEqual(source.usageCount, 0, "no writes may happen")
    }

    run("reapply (force) bypasses the excluded-current guard") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "teams", input: "teams")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try check(!plan.isEmpty, "plan must exist")
        try check(plan.allSatisfy { $0.target != nil }, "targets must be computed")
    }

    run("perform applies only role-set deltas") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try performPlan(plan, on: source, dryRun: false)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output after apply")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "evolve", "input after apply")
    }

    run("dry-run performs no writes") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try performPlan(plan, on: source, dryRun: true)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "jabra510", "output unchanged")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input unchanged")
        try expectEqual(source.usageCount, 0, "no writes may happen")
    }

    // MARK: Sound-effects mirroring (output writes also move the alert device)

    run("output writes mirror the sound-effects device") {
        let source = Fixtures.overlay(output: "spk", input: "mic", systemOutput: "spk")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, direction: .output)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output set")
        try expectEqual(source.systemOutput?.uid, "evolve", "effects device follows output")
    }

    run("input writes leave the sound-effects device untouched") {
        let source = Fixtures.overlay(output: "spk", input: "mic", systemOutput: "spk")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, direction: .input)
        try expectEqual(source.defaultDevice(for: .input)?.uid, "evolve", "input set")
        try expectEqual(source.systemOutput?.uid, "spk", "effects device unchanged")
    }

    run("disabled sound-effects management leaves the effects device untouched") {
        let source = Fixtures.overlay(
            output: "spk", input: "mic", systemOutput: "spk", manageSoundEffects: false
        )
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, direction: .output)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output set")
        try expectEqual(source.systemOutput?.uid, "spk", "effects device unchanged")
    }

    run("applying a plan mirrors the effects device with the output") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic", systemOutput: "jabra510")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try performPlan(plan, on: source, dryRun: false)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output after apply")
        try expectEqual(source.systemOutput?.uid, "evolve", "effects device after apply")
    }

    // MARK: FixtureSource (in-memory device table unit)

    run("fixture loads devices and current pointers") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "jabra510", defaultInput: "mic"
        )
        try expectEqual(source.allDevices().count, 6, "device count")
        try expectEqual(source.defaultDevice(for: .output)?.uid, "jabra510", "output current")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input current")
    }

    run("fixture setDefault mutates only the targeted direction") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "jabra510", defaultInput: "mic"
        )
        let spk = Fixtures.devices().first { $0.uid == "spk" }!
        _ = source.setDefault(spk, direction: .output)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "spk", "output changed")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input unchanged")
    }

    run("fixture source mirrors effects on output and records its initial pointer") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "spk", defaultInput: "mic",
            defaultSystemOutput: "dell"
        )
        try expectEqual(source.systemOutputDevice()?.uid, "dell", "initial effects pointer")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, direction: .output)
        try expectEqual(source.systemOutputDevice()?.uid, "evolve", "mirrored effects pointer")
    }

    run("fixture source honors disabled effects management") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "spk", defaultInput: "mic",
            defaultSystemOutput: "dell", manageSoundEffects: false
        )
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, direction: .output)
        try expectEqual(source.systemOutputDevice()?.uid, "dell", "effects pointer untouched")
    }

    run("missing current pointer yields nil") {
        let source = FixtureDeviceSource(devices: Fixtures.devices(), defaultOutput: nil, defaultInput: nil)
        try check(source.defaultDevice(for: .output) == nil, "no output default")
        try check(source.defaultDevice(for: .input) == nil, "no input default")
    }

    // MARK: Menu rendering (deterministic)

    run("menu text lists tier order with checkmark and excluded info row") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "teams")
        let text = renderMenu(source: source, engine: engine).joined(separator: "\n")
        try check(
            text.contains("status: hifispeaker.fill questionmark.circle"),
            "status line: \(text)"
        )
        try check(text.contains("  ✓ Jabra SPEAK 510 USB [hifispeaker.fill]"), "current speaker row")
        try check(text.contains("  · Jabra Evolve 75 SE [headphones]"), "other tier row")
        try check(
            text.contains("  - Current: Microsoft Teams Audio (not managed)"),
            "excluded info row"
        )
    }
}
