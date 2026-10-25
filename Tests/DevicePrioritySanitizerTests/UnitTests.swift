import Foundation

// The unit test cases. Pure logic only — the DeviceSource doubles keep every
// test fully isolated from CoreAudio and AVFoundation, and each test builds
// fresh fixtures.

func runUnitTests() {
    // MARK: Regex semantics

    run("matching is case-sensitive") {
        let engine = try Fixtures.engine()
        let caseMismatched = MediaDevice(
            uid: "lower", name: "jabra speak 510 usb",
            transportClass: .usb, deviceType: nil, capabilities: [.output, .input]
        )
        try expectEqual(
            engine.entrySymbol(for: caseMismatched, target: .output),
            "speaker.wave.3",
            "lowercase name must fall through to the fallback"
        )
    }

    run("matching is unanchored") {
        let engine = try Fixtures.engine()
        let stereo = MediaDevice(
            uid: "stereo", name: "Jabra SPEAK 510 USB (Stereo)",
            transportClass: .usb, deviceType: nil, capabilities: [.output, .input]
        )
        try expectEqual(
            engine.entrySymbol(for: stereo, target: .output),
            "hifispeaker.fill",
            "pattern must match a substring of the name"
        )
    }

    run("alternation matches every token of the tier") {
        let engine = try Fixtures.engine()
        for (uid, name) in [("h1", "Jabra Evolve 75 SE"), ("h2", "WH-1000XM2"), ("h3", "EarPods")] {
            let device = MediaDevice(
                uid: uid, name: name, transportClass: .bluetooth, deviceType: nil, capabilities: [.output, .input]
            )
            try expectEqual(
                engine.entrySymbol(for: device, target: .input),
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
        let extra = MediaDevice(
            uid: "generic", name: "Aardvark USB Audio",
            transportClass: .usb, deviceType: nil, capabilities: [.output]
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
        let outputOnly = Fixtures.devices().filter { $0.supports(.output) }
        let inputOnly = Fixtures.devices().filter { $0.supports(.input) }
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

    // MARK: Camera priority

    run("camera tiers order External > Continuity > Built-in") {
        let engine = try Fixtures.engine()
        let ordered = engine.orderedManagedDevices(.camera, devices: Fixtures.devices())
        try expectEqual(
            ordered.map { $0.name },
            ["Elgato Cam Link 4K", "iPhone Continuity Camera", "FaceTime HD Camera"],
            "camera tier order, virtual camera excluded"
        )
    }

    run("camera target falls through absent tiers") {
        let engine = try Fixtures.engine()
        let devices = Fixtures.devices()
        try expectEqual(
            engine.targetDevice(.camera, current: nil, devices: devices.filter { $0.uid != "camlink" })?.uid,
            "iphone",
            "external tier absent → continuity wins"
        )
        try expectEqual(
            engine
                .targetDevice(
                    .camera, current: nil,
                    devices: devices.filter { $0.uid != "camlink" && $0.uid != "iphone" }
                )?
                .uid,
            "facetime",
            "external and continuity absent → built-in wins"
        )
    }

    run("camera current is kept within the winning tier") {
        let engine = try Fixtures.engine()
        let devices = Fixtures.devices()
        let camlink = devices.first { $0.uid == "camlink" }!
        try expectEqual(
            engine.targetDevice(.camera, current: camlink, devices: devices)?.uid,
            "camlink",
            "current winner-tier camera kept"
        )
        let facetime = devices.first { $0.uid == "facetime" }!
        try expectEqual(
            engine.targetDevice(.camera, current: facetime, devices: devices)?.uid,
            "camlink",
            "lower-tier current is replaced"
        )
    }

    run("empty camera list leaves the camera unmanaged") {
        let engine = try PriorityEngine(
            config: AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        )
        try check(
            engine.targetDevice(.camera, current: nil, devices: Fixtures.devices()) == nil,
            "no camera tiers → no camera target"
        )
        try expectEqual(
            engine.tierTarget(.camera, title: "External", current: nil, devices: Fixtures.devices()),
            .unknownTier,
            "unknown tier without camera tiers"
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

    run("cycle is per-target") {
        let engine = try Fixtures.engine()
        let mic = Fixtures.devices().first { $0.uid == "mic" }!
        try expectEqual(
            engine.cycleTarget(.input, current: mic, devices: Fixtures.devices())?.uid,
            "evolve",
            "input cycle order"
        )
    }

    run("cycle camera wraps from the built-in tier") {
        let engine = try Fixtures.engine()
        let devices = Fixtures.devices()
        let facetime = devices.first { $0.uid == "facetime" }!
        try expectEqual(
            engine.cycleTarget(.camera, current: facetime, devices: devices)?.uid,
            "camlink",
            "camera cycle wraps to the first tier"
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
        let camlink = devices.first { $0.uid == "camlink" }!
        let facetime = devices.first { $0.uid == "facetime" }!

        try expectEqual(engine.slotSymbol(for: evolve, target: .output), "headphones", "tier symbol")
        try expectEqual(engine.slotSymbol(for: mic, target: .input), "laptopcomputer", "internal symbol")
        try expectEqual(
            engine.slotSymbol(for: spk, target: .input),
            "mic",
            "output-only device falls back for the input target"
        )
        try expectEqual(engine.slotSymbol(for: dell, target: .output), "speaker.wave.3", "fallback symbol")
        try expectEqual(
            engine.slotSymbol(for: teams, target: .output),
            PriorityEngine.excludedSymbol,
            "excluded symbol"
        )
        try expectEqual(engine.slotSymbol(for: nil, target: .input), "mic", "no-device fallback")
        try expectEqual(engine.slotSymbol(for: camlink, target: .camera), "video", "camera tier symbol")
        try expectEqual(
            engine.slotSymbol(for: facetime, target: .camera),
            "laptopcomputer",
            "built-in camera symbol"
        )
        try expectEqual(
            engine.slotSymbol(for: devices.first { $0.uid == "obsvirtual" }, target: .camera),
            PriorityEngine.excludedSymbol,
            "virtual camera excluded symbol"
        )
        try expectEqual(engine.slotSymbol(for: nil, target: .camera), "video", "camera no-device fallback")
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
        try expectEqual(config.fallback(for: .camera), "video", "camera fallback defaults")
        try expectEqual(config.debounceInterval, 0.5, "debounce interval")
    }

    run("missing fallback and debounce fall back to sensible defaults") {
        let config = AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        try expectEqual(config.debounceInterval, 0.5, "default debounce")
        try expectEqual(config.fallback(for: .output), "speaker.wave.3", "default output fallback")
        try expectEqual(config.fallback(for: .input), "mic", "default input fallback")
        try expectEqual(config.fallback(for: .camera), "video", "default camera fallback")
    }

    run("cameras decode and default to empty for legacy configs") {
        let legacy = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"outputs": [], "inputs": []}"#.utf8)
        )
        try expectEqual(legacy.entries(for: .camera), [], "legacy config has no camera tiers")
        let camera = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(
                #"""
                {"outputs": [], "inputs": [],
                 "cameras": [{"title": "External", "match": "Cam Link", "symbol": "video"}]}
                """#.utf8)
        )
        try expectEqual(camera.entries(for: .camera).count, 1, "camera tiers decode")
        try expectEqual(
            camera.fallback(for: .camera),
            "video",
            "camera fallback without explicit symbol"
        )
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

    run("tier titles decode; legacy entries without one still work") {
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(
                #"""
                {"outputs": [
                  {"title": "Headset", "match": "Evolve", "symbol": "headphones"},
                  {"match": "Built-in", "symbol": "laptopcomputer"}
                ], "inputs": []}
                """#.utf8)
        )
        try expectEqual(config.outputs.map(\.title), ["Headset", nil], "tier titles")
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
        let twin = MediaDevice(
            uid: "evolve-twin", name: "Jabra Evolve 75 SE",
            transportClass: .bluetooth, deviceType: nil, capabilities: [.output, .input]
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

    run("target filters candidates") {
        let match = resolveDevice(.input, name: "DELL", devices: Fixtures.devices())
        guard case .notFound = match else {
            throw UnitTestFailure("expected notFound for the wrong target, got \(match)")
        }
        let camera = resolveDevice(.camera, name: "OBS Virtual Camera", devices: Fixtures.devices())
        guard case .matched = camera else {
            throw UnitTestFailure("expected the virtual camera to resolve explicitly, got \(camera)")
        }
    }

    // MARK: Tier selection (set --tier)

    run("tier selection ignores higher-priority tiers") {
        // The headset is connected and would win auto-selection, but an
        // explicit speaker-tier pick must resolve within that tier only.
        let engine = try Fixtures.engine()
        guard
            case .device(let target) = engine.tierTarget(
                .output, title: "Speaker", current: nil, devices: Fixtures.devices())
        else {
            throw UnitTestFailure("expected the speaker tier to resolve")
        }
        try expectEqual(target.uid, "jabra510", "speaker tier target")
    }

    run("tier selection keeps a current device that belongs to the tier") {
        let engine = try Fixtures.engine()
        let devices = Fixtures.devices()
        let current = devices.first { $0.uid == "jabra510" }!
        guard
            case .device(let target) = engine.tierTarget(
                .output, title: "Speaker", current: current, devices: devices)
        else {
            throw UnitTestFailure("expected the speaker tier to resolve")
        }
        try expectEqual(target.uid, "jabra510", "current speaker kept")
    }

    run("tier selection is per target") {
        let engine = try Fixtures.engine()
        guard
            case .device(let target) = engine.tierTarget(
                .input, title: "Built-in", current: nil, devices: Fixtures.devices())
        else {
            throw UnitTestFailure("expected the built-in input tier to resolve")
        }
        try expectEqual(target.uid, "mic", "built-in input")
    }

    run("camera tier selection resolves within the chosen tier") {
        let engine = try Fixtures.engine()
        guard
            case .device(let target) = engine.tierTarget(
                .camera, title: "Continuity", current: nil, devices: Fixtures.devices())
        else {
            throw UnitTestFailure("expected the continuity tier to resolve")
        }
        try expectEqual(target.uid, "iphone", "continuity camera")
    }

    run("unknown tier is reported, not resolved") {
        let engine = try Fixtures.engine()
        let selection = engine.tierTarget(
            .output, title: "Nope", current: nil, devices: Fixtures.devices())
        try expectEqual(selection, .unknownTier, "unknown tier")
    }

    run("tier with no connected device is reported as empty") {
        let engine = try Fixtures.engine()
        let withoutHeadset = Fixtures.devices().filter { $0.uid != "evolve" }
        let selection = engine.tierTarget(
            .output, title: "Headset", current: nil, devices: withoutHeadset)
        try expectEqual(selection, .noDevice, "empty tier")
    }

    run("tier titles are listed in priority order") {
        let engine = try Fixtures.engine()
        try expectEqual(
            engine.tierTitles(.output), ["Headset", "Speaker", "Built-in"], "output titles")
        try expectEqual(
            engine.tierTitles(.camera), ["External", "Continuity", "Built-in"], "camera titles")
    }

    // MARK: Planning (excluded-current guard, force bypass)

    run("auto: excluded current device is skipped without touching it") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "teams", input: "teams", camera: "obsvirtual")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: false)
        try check(plan.allSatisfy(\.skippedExcluded), "every change must be skipped")
        try check(plan.allSatisfy { $0.device == nil }, "no targets may be computed")
        try expectEqual(source.usageCount, 0, "no writes may happen")
    }

    run("reapply (force) bypasses the excluded-current guard") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "teams", input: "teams", camera: "obsvirtual")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try check(!plan.isEmpty, "plan must exist")
        try check(plan.allSatisfy { $0.device != nil }, "targets must be computed")
    }

    run("perform applies only role-set deltas") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic", camera: "facetime")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try performPlan(plan, on: source, dryRun: false)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output after apply")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "evolve", "input after apply")
        try expectEqual(source.defaultDevice(for: .camera)?.uid, "camlink", "camera after apply")
    }

    run("dry-run performs no writes") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic", camera: "facetime")
        let plan = planApply(source: source, engine: engine, devices: Fixtures.devices(), force: true)
        try performPlan(plan, on: source, dryRun: true)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "jabra510", "output unchanged")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input unchanged")
        try expectEqual(source.defaultDevice(for: .camera)?.uid, "facetime", "camera unchanged")
        try expectEqual(source.usageCount, 0, "no writes may happen")
    }

    // MARK: Sound-effects mirroring (output writes also move the alert device)

    run("output writes mirror the sound-effects device") {
        let source = Fixtures.overlay(output: "spk", input: "mic", systemOutput: "spk")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, target: .output)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "evolve", "output set")
        try expectEqual(source.systemOutput?.uid, "evolve", "effects device follows output")
    }

    run("input writes leave the sound-effects device untouched") {
        let source = Fixtures.overlay(output: "spk", input: "mic", systemOutput: "spk")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, target: .input)
        try expectEqual(source.defaultDevice(for: .input)?.uid, "evolve", "input set")
        try expectEqual(source.systemOutput?.uid, "spk", "effects device unchanged")
    }

    run("camera writes leave the sound-effects device untouched") {
        let source = Fixtures.overlay(output: "spk", input: "mic", systemOutput: "spk")
        let camlink = Fixtures.devices().first { $0.uid == "camlink" }!
        _ = source.setDefault(camlink, target: .camera)
        try expectEqual(source.defaultDevice(for: .camera)?.uid, "camlink", "camera set")
        try expectEqual(source.systemOutput?.uid, "spk", "effects device unchanged")
    }

    run("disabled sound-effects management leaves the effects device untouched") {
        let source = Fixtures.overlay(
            output: "spk", input: "mic", systemOutput: "spk", manageSoundEffects: false
        )
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, target: .output)
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
        try expectEqual(source.allDevices().count, 10, "device count")
        try expectEqual(source.defaultDevice(for: .output)?.uid, "jabra510", "output current")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input current")
        try check(source.defaultDevice(for: .camera) == nil, "no camera current")
    }

    run("fixture setDefault mutates only the targeted device class") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "jabra510", defaultInput: "mic"
        )
        let spk = Fixtures.devices().first { $0.uid == "spk" }!
        _ = source.setDefault(spk, target: .output)
        try expectEqual(source.defaultDevice(for: .output)?.uid, "spk", "output changed")
        try expectEqual(source.defaultDevice(for: .input)?.uid, "mic", "input unchanged")
        try expectEqual(source.defaultDevice(for: .camera)?.uid, nil, "camera unchanged")
        let camlink = Fixtures.devices().first { $0.uid == "camlink" }!
        _ = source.setDefault(camlink, target: .camera)
        try expectEqual(source.defaultDevice(for: .camera)?.uid, "camlink", "camera changed")
        try expectEqual(source.defaultDevice(for: .output)?.uid, "spk", "output still unchanged")
    }

    run("fixture source mirrors effects on output and records its initial pointer") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "spk", defaultInput: "mic",
            defaultSystemOutput: "dell"
        )
        try expectEqual(source.systemOutputDevice()?.uid, "dell", "initial effects pointer")
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, target: .output)
        try expectEqual(source.systemOutputDevice()?.uid, "evolve", "mirrored effects pointer")
    }

    run("fixture source honors disabled effects management") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "spk", defaultInput: "mic",
            defaultSystemOutput: "dell", manageSoundEffects: false
        )
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        _ = source.setDefault(evolve, target: .output)
        try expectEqual(source.systemOutputDevice()?.uid, "dell", "effects pointer untouched")
    }

    run("fixture JSON with cameras decodes, and legacy tables still work") {
        let legacy = """
            {"devices": [
              {"uid": "a", "name": "A", "transport": "usb", "isOutput": true, "isInput": false}
            ], "defaultOutput": "a", "defaultInput": null}
            """
        let legacyFixture = try JSONDecoder().decode(FixtureData.self, from: Data(legacy.utf8))
        try expectEqual(legacyFixture.devices.first?.isCamera ?? false, false, "legacy has no camera flag")

        let withCameras = """
            {"devices": [
              {"uid": "a", "name": "A", "transport": "usb", "isOutput": false, "isInput": false, "isCamera": true},
              {"uid": "b", "name": "B", "transport": "virtual", "isOutput": false, "isInput": false, "isCamera": true}
            ], "defaultOutput": null, "defaultInput": null, "defaultCamera": "a"}
            """
        let fixture = try JSONDecoder().decode(FixtureData.self, from: Data(withCameras.utf8))
        try expectEqual(fixture.defaultCamera, "a", "camera current pointer decodes")
        try expectEqual(fixture.devices.count, 2, "camera devices decode")
    }

    run("missing current pointer yields nil") {
        let source = FixtureDeviceSource(devices: Fixtures.devices(), defaultOutput: nil, defaultInput: nil)
        try check(source.defaultDevice(for: .output) == nil, "no output default")
        try check(source.defaultDevice(for: .input) == nil, "no input default")
        try check(source.defaultDevice(for: .camera) == nil, "no camera default")
    }

    // MARK: Prioritization switch (runtime state)

    run("state decodes, defaults, and round-trips") {
        let enabled = try JSONDecoder().decode(
            PrioritizationState.self, from: Data(#"{"prioritizationEnabled": true}"#.utf8))
        try check(enabled.prioritizationEnabled, "enabled decodes")
        let disabled = try JSONDecoder().decode(
            PrioritizationState.self, from: Data(#"{"prioritizationEnabled": false}"#.utf8))
        try check(!disabled.prioritizationEnabled, "disabled decodes")
        try expectEqual(loadState("/nonexistent-device-priority/state.json"), .missing, "missing state file")
        if case .corrupt = decodeState(Data("not json".utf8)) {
            // expected
        } else {
            throw UnitTestFailure("garbage must decode as corrupt")
        }
        let roundTrip = try JSONDecoder().decode(PrioritizationState.self, from: try encodeState(disabled))
        try expectEqual(roundTrip, disabled, "state round-trips through encode/decode")
    }

    run("engine reports managed targets from the tier lists") {
        let engine = try Fixtures.engine()
        try check(
            engine.isManaged(.output) && engine.isManaged(.input) && engine.isManaged(.camera),
            "documented config manages all targets")
        let empty = try PriorityEngine(
            config: AppConfig(outputs: [], inputs: [], fallbackSymbol: nil, debounceMs: nil)
        )
        try check(
            !empty.isManaged(.output) && !empty.isManaged(.input) && !empty.isManaged(.camera),
            "empty tier lists leave every target unmanaged")
    }

    run("plan skips disabled and unmanaged targets without writes") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "mic", camera: "facetime")

        let disabledPlan = planApply(
            source: source, engine: engine, devices: Fixtures.devices(), force: true,
            prioritizationEnabled: false
        )
        try check(disabledPlan.allSatisfy(\.skippedDisabled), "every change skipped as disabled")
        try check(disabledPlan.allSatisfy { $0.device == nil }, "no targets may be computed")
        try expectEqual(source.usageCount, 0, "no writes may happen")
        let disabledText = renderPlan(disabledPlan, dryRun: true).joined(separator: "\n")
        try check(
            disabledText.contains("output: skipped — prioritization disabled"),
            "disabled rendering: \(disabledText)")

        // An empty tier list is the per-target switch: those targets are
        // unmanaged even while prioritization is globally enabled.
        let sparseEngine = try PriorityEngine(
            config: AppConfig(
                outputs: [PriorityEntry(match: "Evolve", symbol: "headphones", title: "Headset")],
                inputs: [], cameras: [], fallbackSymbol: nil, debounceMs: nil
            )
        )
        let plan = planApply(
            source: source, engine: sparseEngine, devices: Fixtures.devices(), force: true,
            prioritizationEnabled: true
        )
        let byTarget = Dictionary(uniqueKeysWithValues: plan.map { ($0.target, $0) })
        try check(byTarget[.output]!.device != nil, "managed output still computes a target")
        try check(byTarget[.input]!.skippedUnmanaged, "empty input tier list is unmanaged")
        try check(byTarget[.camera]!.skippedUnmanaged, "empty camera tier list is unmanaged")
        let text = renderPlan(plan, dryRun: true).joined(separator: "\n")
        try check(
            text.contains("input: not auto-managed (no priority tiers)"),
            "unmanaged rendering: \(text)")
    }

    // MARK: Config document (UI model)

    func withTempConfig(_ json: String, _ body: (String) throws -> Void) throws {
        let path = NSTemporaryDirectory() + "device-priority-test-\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    run("exactPattern anchors and escapes device names") {
        try expectEqual(exactPattern("Jabra SPEAK 510"), "^Jabra SPEAK 510$", "plain name")
        try expectEqual(
            exactPattern("Jabra SPEAK 510 USB (Stereo)"),
            "^Jabra SPEAK 510 USB \\(Stereo\\)$",
            "parens are regex-escaped and the pattern is anchored"
        )
        try expectEqual(exactPattern("C920 [HD]"), "^C920 \\[HD]$", "brackets escaped (] needs no escape)")
    }

    run("uniqueTitle deduplicates against existing titles") {
        try expectEqual(uniqueTitle("Cam", existing: []), "Cam", "first title is untouched")
        try expectEqual(uniqueTitle("Cam", existing: ["Cam"]), "Cam (2)", "second gets a suffix")
        try expectEqual(
            uniqueTitle("Cam", existing: ["Cam", "Cam (2)"]),
            "Cam (3)",
            "third continues the sequence"
        )
    }

    run("autoSymbol derives from transport and target") {
        let devices = Fixtures.devices()
        let evolve = devices.first { $0.uid == "evolve" }!
        let dell = devices.first { $0.uid == "dell" }!
        let facetime = devices.first { $0.uid == "facetime" }!
        let camlink = devices.first { $0.uid == "camlink" }!
        try expectEqual(autoSymbol(evolve, .output), "headphones", "bluetooth output")
        try expectEqual(autoSymbol(evolve, .input), "headphones", "bluetooth input")
        try expectEqual(autoSymbol(dell, .output), "display", "displayPort output")
        try expectEqual(autoSymbol(facetime, .camera), "laptopcomputer", "built-in camera")
        try expectEqual(autoSymbol(camlink, .camera), "video", "external camera")
    }

    run("document rows split covered, uncovered, and unmanaged devices") {
        let document = ConfigDocument(
            path: "/dev/null",
            raw: [
                "outputs": [
                    ["match": "Evolve", "symbol": "headphones", "title": "Headset"]
                ],
                "cameras": [],
            ]
        )
        let rows = document.rows(for: .output, devices: Fixtures.devices())
        try expectEqual(rows.priority.count, 1, "one output tier")
        try expectEqual(rows.priority.first?.tier.title, "Headset", "tier title")
        try expectEqual(rows.priority.first?.connected.map(\.uid), ["evolve"], "tier's device")
        // Available: managed outputs, uncovered (SPEAK 510 tier absent),
        // lexicographic, duplicates collapsed.
        try expectEqual(
            rows.available.map(\.name),
            ["DELL U3824DW", "Jabra SPEAK 510 USB", "MacBook Pro Speakers"],
            "uncovered outputs in lexicographic order"
        )
        try check(rows.isManaged, "output is managed")
        let cameraRows = document.rows(for: .camera, devices: Fixtures.devices())
        try check(cameraRows.priority.isEmpty && !cameraRows.isManaged, "camera unmanaged")
        try expectEqual(cameraRows.available.count, 3, "cameras available (virtual excluded)")
    }

    run("document rows collapse identical device names in the available list") {
        let document = ConfigDocument(path: "/dev/null", raw: [:] as [String: Any])
        let twin = MediaDevice(
            uid: "evolve-twin", name: "Jabra Evolve 75 SE", transportClass: .bluetooth,
            deviceType: nil, capabilities: [.output, .input]
        )
        let rows = document.rows(for: .output, devices: Fixtures.devices() + [twin])
        try expectEqual(
            rows.available.filter { $0.name == "Jabra Evolve 75 SE" }.count, 1,
            "same-name devices collapse into one available row"
        )
    }

    run("insert adds an anchored tier with deduped title; remove and move are pure") {
        let document = ConfigDocument(
            path: "/dev/null",
            raw: ["cameras": [["match": "FaceTime", "symbol": "laptopcomputer", "title": "FaceTime HD Camera"]]]
        )
        let devices = Fixtures.devices()
        let facetime = devices.first { $0.uid == "facetime" }!
        let camlink = devices.first { $0.uid == "camlink" }!

        let inserted = document.insert(device: facetime, target: .camera, at: 0)
        try expectEqual(
            inserted.tiers(for: .camera).map(\.title),
            ["FaceTime HD Camera (2)", "FaceTime HD Camera"],
            "duplicate title gets a suffix; insertion at the top"
        )
        try expectEqual(inserted.tiers(for: .camera).first?.match, "^FaceTime HD Camera$", "anchored exact pattern")

        let removed = document.removeTier(target: .camera, at: 0)
        try check(removed.tiers(for: .camera).isEmpty, "removal empties the target")

        let multi = document.insert(device: camlink, target: .camera, at: 0)
        let moved = multi.moveTier(target: .camera, from: 1, to: 0)
        try expectEqual(
            moved.tiers(for: .camera).map(\.title),
            ["FaceTime HD Camera", "Elgato Cam Link 4K"],
            "move promotes the lower tier"
        )
    }

    run("document load/save preserves unknown keys and unknown tier fields") {
        try withTempConfig(
            #"""
            {"outputs": [{"match": "Evolve", "symbol": "headphones", "title": "Headset",
                          "note": "keep me"}],
             "inputs": [],
             "unknownTopLevel": {"a": 1}}
            """#
        ) { path in
            var document = try ConfigDocument.load(path)
            try check(document.tiers(for: .output).count == 1, "one tier loads")
            let camlink = Fixtures.devices().first { $0.uid == "camlink" }!
            document = document.insert(device: camlink, target: .camera, at: 0)

            let data = try document.encoded()
            let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try check(
                (raw["unknownTopLevel"] as? [String: Any])?["a"] as? Int == 1,
                "unknown top-level key survives"
            )
            let outputs = raw["outputs"] as! [[String: Any]]
            try expectEqual(outputs.first?["note"] as? String, "keep me", "unknown tier field survives")
            let cameras = raw["cameras"] as! [[String: Any]]
            try expectEqual(
                cameras.first?["match"] as? String, "^Elgato Cam Link 4K$",
                "new tier carries the anchored pattern"
            )

            // The typed view decodes what the engine needs.
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            try expectEqual(config.outputs.first?.title, "Headset", "typed config decodes")
            try expectEqual(config.entries(for: .camera).count, 1, "camera tier decodes")
        }
    }

    run("document load/save round-trips through the file and backs up broken files") {
        try withTempConfig(#"{"outputs": [], "inputs": []}"#) { path in
            var document = try ConfigDocument.load(path)
            let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
            document = document.insert(device: evolve, target: .output, at: 0)
            try document.save()
            let reloaded = try ConfigDocument.load(path)
            try expectEqual(
                reloaded.tiers(for: .output).map(\.title), ["Jabra Evolve 75 SE"],
                "tier persists across save/load"
            )
        }
        try withTempConfig("garbage") { path in
            do {
                _ = try ConfigDocument.load(path)
                throw UnitTestFailure("garbage must fail validation")
            } catch let error as ConfigDocumentError {
                guard case .invalidJSON = error else {
                    throw UnitTestFailure("expected invalidJSON, got \(error)")
                }
            }
            let empty = ConfigDocument.empty(path: path)
            let backupPath = try empty.backup()
            try check(FileManager.default.fileExists(atPath: backupPath), "backup created")
        }
    }

    // MARK: Menu rendering (deterministic)

    run("menu text lists tier order with checkmark and excluded info row") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "teams")
        let text = renderMenu(source: source, engine: engine, prioritizationEnabled: true)
            .joined(separator: "\n")
        try check(
            text.contains("status: hifispeaker.fill questionmark.circle video"),
            "status line: \(text)"
        )
        try check(text.contains("prioritization: enabled"), "prioritization line")
        try check(text.contains("  ✓ Jabra SPEAK 510 USB [hifispeaker.fill]"), "current speaker row")
        try check(text.contains("  · Jabra Evolve 75 SE [headphones]"), "other tier row")
        try check(
            text.contains("  - Current: Microsoft Teams Audio (not managed)"),
            "excluded info row"
        )
    }

    run("menu text covers the camera target with its own block") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "teams", camera: "obsvirtual")
        let text = renderMenu(source: source, engine: engine, prioritizationEnabled: true)
            .joined(separator: "\n")
        try check(
            text.contains("status: hifispeaker.fill questionmark.circle questionmark.circle"),
            "three-slot status line: \(text)"
        )
        try check(text.contains("camera-menu:"), "camera block present")
        try check(text.contains("  · Elgato Cam Link 4K [video]"), "camera tier row")
        try check(
            text.contains("  - Current: OBS Virtual Camera (not managed)"),
            "excluded camera info row"
        )
    }

    run("menu text marks a disabled switch and unmanaged targets") {
        let engine = try Fixtures.engine()
        let source = Fixtures.overlay(output: "jabra510", input: "teams", camera: "obsvirtual")
        let disabled = renderMenu(source: source, engine: engine, prioritizationEnabled: false)
            .joined(separator: "\n")
        try check(disabled.contains("prioritization: disabled"), "disabled line")
        try check(
            disabled.contains("status: hifispeaker.fill questionmark.circle questionmark.circle pause.circle"),
            "pause marker appended: \(disabled)"
        )

        let sparseEngine = try PriorityEngine(
            config: AppConfig(outputs: [], inputs: [], cameras: [], fallbackSymbol: nil, debounceMs: nil)
        )
        let sparse = renderMenu(source: source, engine: sparseEngine, prioritizationEnabled: true)
            .joined(separator: "\n")
        try check(
            sparse.contains("  - Not auto-managed (no priority tiers)"),
            "unmanaged info row: \(sparse)"
        )
    }

    // MARK: Saved levels (per-device volume restore)

    func levelEntry(
        _ uid: String, name: String = "Jabra Evolve 75 SE", modelUID: String? = "jabra-evolve-75",
        level: Float
    ) -> SavedLevel {
        SavedLevel(
            uid: uid, name: name, modelUID: modelUID, transport: .bluetooth, level: level,
            savedAt: "2026-01-01T00:00:00Z"
        )
    }

    run("levels document decodes, defaults, and round-trips") {
        let json = """
            {"output": {"evolve": {"uid": "evolve", "name": "Jabra Evolve 75 SE",
              "modelUID": "jabra-evolve-75", "transport": "bluetooth", "level": 0.42,
              "savedAt": "2026-01-01T00:00:00Z"}}}
            """
        let document = try JSONDecoder().decode(LevelsDocument.self, from: Data(json.utf8))
        try expectEqual(document.output["evolve"]?.level, 0.42, "entry decodes")
        try expectEqual(document.schemaVersion, 1, "schema version defaults for old files")
        let empty = try JSONDecoder().decode(LevelsDocument.self, from: Data("{}".utf8))
        try expectEqual(empty, LevelsDocument.empty, "an empty object decodes as the empty document")
        let reencoded = try JSONDecoder().decode(LevelsDocument.self, from: try JSONEncoder().encode(document))
        try expectEqual(reencoded, document, "round-trips through encode/decode")
    }

    run("upsert and remove maintain the per-target maps") {
        var document = LevelsDocument.empty
        let entry = levelEntry("evolve", level: 0.42)
        document.upsert(entry, for: .output)
        try expectEqual(document.entries(for: .output)["evolve"], entry, "output entry upserted")
        document.upsert(levelEntry("evolve", level: 0.7), for: .output)
        try expectEqual(document.output["evolve"]?.level, 0.7, "upsert overwrites")
        document.upsert(levelEntry("mic", name: "MacBook Pro Microphone", modelUID: nil, level: 0.5), for: .input)
        try expectEqual(document.input.count, 1, "input map independent")
        document.remove(uid: "evolve", for: .input)
        try expectEqual(document.input.count, 1, "removal is per target")
        document.remove(uid: "evolve", for: .output)
        try check(document.output.isEmpty, "output entry removed")
    }

    run("saved level lookup: exact UID wins over a replacement candidate") {
        let document = LevelsDocument(
            output: [
                "evolve": levelEntry("evolve", level: 0.42),
                "evolve-old": levelEntry("evolve-old", level: 0.25),
            ], input: [:])
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            savedLevel(for: evolve, target: .output, document: document, connectedUIDs: []),
            .exact(document.output["evolve"]!),
            "exact UID wins even with a replacement candidate present"
        )
    }

    run("saved level lookup: replacement match for an absent unit of the same model") {
        let old = levelEntry("evolve-old", level: 0.25)
        let document = LevelsDocument(output: ["evolve-old": old], input: [:])
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            savedLevel(for: evolve, target: .output, document: document, connectedUIDs: ["evolve"]),
            .replacement(old),
            "unique name+model match with the old UID disconnected"
        )
    }

    run("saved level lookup: the gate — a connected old UID never cross-applies") {
        // Two same-model units connected: the entry for evolve-old must not
        // restore onto its twin evolve while the old unit is still present.
        let old = levelEntry("evolve-old", level: 0.25)
        let document = LevelsDocument(output: ["evolve-old": old], input: [:])
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            savedLevel(
                for: evolve, target: .output, document: document,
                connectedUIDs: ["evolve", "evolve-old"]),
            .none,
            "no cross-apply between two connected same-name devices"
        )
    }

    run("saved level lookup: mismatch, ambiguity, and the camera target restore nothing") {
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        // Model mismatch.
        var document = LevelsDocument(
            output: ["old": levelEntry("old", modelUID: "different-model", level: 0.25)], input: [:])
        try expectEqual(
            savedLevel(for: evolve, target: .output, document: document, connectedUIDs: []),
            .none,
            "model UID mismatch"
        )
        // One-sided model UID.
        document = LevelsDocument(output: ["old": levelEntry("old", modelUID: nil, level: 0.25)], input: [:])
        try expectEqual(
            savedLevel(for: evolve, target: .output, document: document, connectedUIDs: []),
            .none,
            "a nil model UID on one side is not a match"
        )
        // Name mismatch.
        document = LevelsDocument(
            output: ["old": levelEntry("old", name: "Something else", level: 0.25)], input: [:])
        try expectEqual(
            savedLevel(for: evolve, target: .output, document: document, connectedUIDs: []),
            .none,
            "name mismatch"
        )
        // Ambiguity: two same-name candidates with nil model UIDs.
        document = LevelsDocument(
            output: [
                "old1": levelEntry("old1", modelUID: nil, level: 0.2),
                "old2": levelEntry("old2", modelUID: nil, level: 0.4),
            ], input: [:])
        let twin = MediaDevice(
            uid: "twin", name: "Jabra Evolve 75 SE", transportClass: .bluetooth, deviceType: nil,
            modelUID: nil, capabilities: [.output]
        )
        try expectEqual(
            savedLevel(for: twin, target: .output, document: document, connectedUIDs: []),
            .none,
            "ambiguous candidates restore nothing"
        )
        // Camera never participates.
        document = LevelsDocument(
            output: [:],
            input: [
                "facetime": levelEntry("facetime", name: "FaceTime HD Camera", level: 0.5)
            ])
        let facetime = Fixtures.devices().first { $0.uid == "facetime" }!
        try expectEqual(
            savedLevel(for: facetime, target: .camera, document: document, connectedUIDs: []),
            .none,
            "camera target has no saved levels"
        )
    }

    run("restore applies a saved level and skips absent or unsupported devices") {
        let document = LevelsDocument(
            output: [
                "evolve": levelEntry("evolve", level: 0.42),
                "dell": levelEntry("dell", name: "DELL U3824DW", modelUID: nil, level: 0.7),
            ], input: [:])
        let connectedUIDs = Set(Fixtures.devices().map(\.uid))

        // Exact entry: the write lands on the device.
        let source = Fixtures.overlay(
            output: "jabra510", input: "mic", volumes: [.output: ["evolve": 0.4], .input: ["mic": 0.6]])
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            restoreSavedLevel(
                device: evolve, target: .output, source: source, document: document,
                connectedUIDs: connectedUIDs, perform: true),
            .restored(level: 0.42, replacement: false),
            "restored outcome"
        )
        try expectEqual(source.volume(for: evolve, target: .output), 0.42, "volume written")

        // No entry: nothing happens.
        let jabra510 = Fixtures.devices().first { $0.uid == "jabra510" }!
        try expectEqual(
            restoreSavedLevel(
                device: jabra510, target: .output, source: source, document: document,
                connectedUIDs: connectedUIDs, perform: true),
            .noEntry,
            "no entry restores nothing"
        )

        // Entry exists but the device has no volume control in this source.
        let dell = Fixtures.devices().first { $0.uid == "dell" }!
        try expectEqual(
            restoreSavedLevel(
                device: dell, target: .output, source: source, document: document,
                connectedUIDs: connectedUIDs, perform: true),
            .unsupported,
            "unsupported device restores nothing"
        )

        // Dry-run reports the would-be restore without writing.
        let dry = Fixtures.overlay(output: "jabra510", input: "mic", volumes: [.output: ["evolve": 0.4]])
        try expectEqual(
            restoreSavedLevel(
                device: evolve, target: .output, source: dry, document: document,
                connectedUIDs: connectedUIDs, perform: false),
            .restored(level: 0.42, replacement: false),
            "dry-run outcome"
        )
        try expectEqual(dry.volume(for: evolve, target: .output), 0.4, "dry-run performs no write")
    }

    run("restore reports a replacement match for a swapped unit") {
        let old = levelEntry("evolve-old", level: 0.25)
        let document = LevelsDocument(output: ["evolve-old": old], input: [:])
        let source = Fixtures.overlay(output: "jabra510", input: "mic", volumes: [.output: ["evolve": 0.4]])
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(
            restoreSavedLevel(
                device: evolve, target: .output, source: source, document: document,
                connectedUIDs: ["evolve", "jabra510", "mic"], perform: true),
            .restored(level: 0.25, replacement: true),
            "replacement restore outcome"
        )
        try expectEqual(source.volume(for: evolve, target: .output), 0.25, "replacement level written")
    }

    run("fixture source seeds model UIDs and per-direction volumes") {
        let source = FixtureDeviceSource(
            devices: Fixtures.devices(), defaultOutput: "evolve", defaultInput: "mic",
            volumes: [.output: ["evolve": 0.4], .input: ["mic": 0.6]]
        )
        let evolve = Fixtures.devices().first { $0.uid == "evolve" }!
        try expectEqual(source.volume(for: evolve, target: .output), 0.4, "seeded output volume")
        try expectEqual(source.volume(for: evolve, target: .input), nil, "unseeded direction is unsupported")
        _ = source.setVolume(0.7, for: evolve, target: .input)
        try expectEqual(source.volume(for: evolve, target: .input), 0.7, "set volume reads back")
        let facetime = Fixtures.devices().first { $0.uid == "facetime" }!
        try expectEqual(source.volume(for: facetime, target: .camera), nil, "camera has no volume")
        try expectEqual(
            source.setVolume(0.5, for: facetime, target: .camera), OSStatus(paramErr),
            "camera volume writes are refused"
        )
    }

    run("fixture JSON decodes modelUID and volume seeds; legacy tables still work") {
        let withVolumes = """
            {"devices": [
              {"uid": "a", "name": "A", "transport": "usb", "isOutput": true, "isInput": false,
               "modelUID": "model-a", "volume": {"output": 0.4}}
            ], "defaultOutput": "a", "defaultInput": null}
            """
        let fixture = try JSONDecoder().decode(FixtureData.self, from: Data(withVolumes.utf8))
        try expectEqual(fixture.devices.first?.modelUID, "model-a", "modelUID decodes")
        try expectEqual(fixture.devices.first?.volume?.output, 0.4, "volume seed decodes")
        try expectEqual(fixture.devices.first?.volume?.input, nil, "unseeded direction is nil")
    }

    // MARK: Slider geometry (custom control mapping)

    run("slider mapping is symmetric, clamped, and clip-free") {
        // Knob positions: the center stays inside [radius, width - radius].
        try expectEqual(sliderKnobX(for: 0, width: 200, knobRadius: 5), 5, "minimum at the left inset")
        try expectEqual(sliderKnobX(for: 1, width: 200, knobRadius: 5), 195, "maximum at the right inset")
        try expectEqual(sliderKnobX(for: 0.5, width: 200, knobRadius: 5), 100, "midpoint centered")
        try expectEqual(sliderKnobX(for: -0.5, width: 200, knobRadius: 5), 5, "below-min clamps")
        try expectEqual(sliderKnobX(for: 1.5, width: 200, knobRadius: 5), 195, "above-max clamps")
        // Positions → values, same clamping.
        try expectEqual(sliderValue(forX: 5, width: 200, knobRadius: 5), 0, "left inset is zero")
        try expectEqual(sliderValue(forX: 195, width: 200, knobRadius: 5), 1, "right inset is one")
        try expectEqual(sliderValue(forX: 100, width: 200, knobRadius: 5), 0.5, "center is half")
        try expectEqual(sliderValue(forX: -10, width: 200, knobRadius: 5), 0, "outside-left clamps")
        try expectEqual(sliderValue(forX: 500, width: 200, knobRadius: 5), 1, "outside-right clamps")
        // Exact round-trip through both directions.
        try expectEqual(
            sliderKnobX(for: sliderValue(forX: 100, width: 200, knobRadius: 5), width: 200, knobRadius: 5), 100,
            "round-trip")
        // Degenerate width (no usable span): knob parked, value zero.
        try expectEqual(sliderKnobX(for: 0.7, width: 8, knobRadius: 5), 5, "degenerate width parks the knob")
        try expectEqual(sliderValue(forX: 4, width: 8, knobRadius: 5), 0, "degenerate width yields zero")
    }

    // MARK: Agent lifecycle (start/stop planning)

    func withTempDirectory(_ body: (String) throws -> Void) throws {
        let path = NSTemporaryDirectory() + "device-priority-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    run("start plans a launchd bootstrap when the job is not loaded") {
        let environment = AgentEnvironment(
            plistPath: "/Library/LaunchAgents/x.plist", label: "x",
            jobLoaded: false, appBundlePath: nil, appRunning: false
        )
        try expectEqual(
            planAgent(command: .start, environment: environment),
            .bootstrap(label: "x", plist: "/Library/LaunchAgents/x.plist"),
            "bootstrap plan"
        )
    }

    run("start treats a loaded job as already running, before any plist or bundle logic") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: true, appBundlePath: "/tmp/A.app", appRunning: true
        )
        try expectEqual(
            planAgent(command: .start, environment: environment),
            .alreadyRunning,
            "the supervisor guarantees the process"
        )
    }

    run("start falls back to a manual launch without a plist") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: false, appBundlePath: "/tmp/A.app", appRunning: false
        )
        try expectEqual(
            planAgent(command: .start, environment: environment),
            .launch(bundle: "/tmp/A.app"),
            "manual launch plan"
        )
    }

    run("start reports a running manual instance as already running") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: false, appBundlePath: "/tmp/A.app", appRunning: true
        )
        try expectEqual(
            planAgent(command: .start, environment: environment),
            .alreadyRunning,
            "no double start"
        )
    }

    run("start without any target is noTarget") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: false, appBundlePath: nil, appRunning: false
        )
        try expectEqual(
            planAgent(command: .start, environment: environment),
            .noTarget("no LaunchAgent installed and no app bundle found"),
            "nothing to start"
        )
    }

    run("stop plans a bootout for a loaded job, preferring the supervisor over the process") {
        let environment = AgentEnvironment(
            plistPath: "/p", label: "x", jobLoaded: true, appBundlePath: "/tmp/A.app", appRunning: true
        )
        try expectEqual(
            planAgent(command: .stop, environment: environment),
            .bootout(label: "x"),
            "KeepAlive demands bootout, not a kill"
        )
    }

    run("stop falls back to terminating a manual instance") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: false, appBundlePath: "/tmp/A.app", appRunning: true
        )
        try expectEqual(
            planAgent(command: .stop, environment: environment),
            .terminateApp,
            "unsupervised terminate plan"
        )
    }

    run("stop with nothing running is a no-op") {
        let environment = AgentEnvironment(
            plistPath: nil, label: nil, jobLoaded: false, appBundlePath: nil, appRunning: false
        )
        try expectEqual(
            planAgent(command: .stop, environment: environment),
            .notRunning,
            "idempotent stop"
        )
    }

    run("app bundle derivation covers the .app and package layouts") {
        try expectEqual(
            appBundlePath(executable: "/nix/store/x-Foo.app/Contents/MacOS/foo", override: nil),
            "/nix/store/x-Foo.app",
            "executable inside a bundle walks up"
        )
        try expectEqual(
            appBundlePath(executable: "/nix/store/x/bin/device-priority-sanitizer", override: nil),
            "/nix/store/x/Applications/device-priority-sanitizer.app",
            "package CLI resolves the sibling Applications bundle"
        )
        try expectEqual(
            appBundlePath(executable: "/usr/bin/somethingelse", override: nil),
            nil,
            "unrelated layout has no bundle"
        )
        try expectEqual(
            appBundlePath(executable: "/usr/bin/somethingelse", override: "/nonexistent/A.app"),
            nil,
            "a missing override is no bundle"
        )
        try withTempDirectory { directory in
            try expectEqual(
                appBundlePath(executable: "/usr/bin/somethingelse", override: directory),
                directory,
                "an existing override wins"
            )
        }
    }

    run("app bundle derivation resolves a package CLI symlink into the bundle layout") {
        try withTempDirectory { directory in
            let bundleContents = directory + "/Test.app/Contents/MacOS"
            let binDirectory = directory + "/bin"
            try FileManager.default.createDirectory(atPath: bundleContents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
            let binary = bundleContents + "/device-priority-sanitizer"
            try Data("x".utf8).write(to: URL(fileURLWithPath: binary))
            let symlink = binDirectory + "/device-priority-sanitizer"
            try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: binary)
            try expectEqual(
                appBundlePath(executable: symlink, override: nil),
                directory + "/Test.app",
                "package CLI symlink resolves to the sibling bundle"
            )
        }
    }

    run("plist label parsing reads the Label key and rejects garbage") {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Label</key><string>bats.device-priority-sanitizer</string></dict></plist>
            """
        try expectEqual(
            plistLabel(Data(xml.utf8)),
            "bats.device-priority-sanitizer",
            "label decodes"
        )
        try expectEqual(plistLabel(Data("garbage".utf8)), nil, "garbage yields nil")
    }

    run("agent log rotation keeps the previous run as .1 and starts a fresh log") {
        try withTempDirectory { directory in
            let log = AgentLog(directory: directory)
            try "first".write(toFile: log.path, atomically: true, encoding: .utf8)
            log.rotate()
            try expectEqual(
                try String(contentsOfFile: log.previousPath, encoding: .utf8),
                "first",
                "first run rotates to .1"
            )
            try "second".write(toFile: log.path, atomically: true, encoding: .utf8)
            log.rotate()
            try expectEqual(
                try String(contentsOfFile: log.previousPath, encoding: .utf8),
                "second",
                "an older .1 is replaced"
            )
            try check(
                !FileManager.default.fileExists(atPath: log.path),
                "rotation leaves no stale log behind"
            )
        }
    }
}
