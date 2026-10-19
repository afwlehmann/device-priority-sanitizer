import Foundation

// MARK: - Minimal assertion harness
//
// Swift Testing / XCTest are unavailable in this environment (SwiftPM cannot
// run under the nix sandbox: manifest linking loses the Swift stdlib through
// the cc-wrapper target mismatch). This harness keeps the unit tests plain,
// isolated, and assertion-based; see AGENTS.md.

struct UnitTestFailure: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

var unitTestFailures: [String] = []

func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("ok - \(name)")
    } catch {
        unitTestFailures.append("\(name): \(error)")
        print("not ok - \(name): \(error)")
    }
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw UnitTestFailure(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw UnitTestFailure("\(message): got \(actual), expected \(expected)")
    }
}

/// Minimal in-memory source for unit tests: deterministic DeviceSource double
/// with no hash-derived IDs, recording writes so tests can observe effects
/// without any CoreAudio dependency.
final class OverlaySource: DeviceSource {
    private let devices: [AudioDevice]
    private var current: [Direction: AudioDevice?]
    private let manageSoundEffects: Bool
    private(set) var systemOutput: AudioDevice?
    private(set) var usageCount = 0

    init(
        devices: [AudioDevice],
        currentOutput: String?,
        currentInput: String?,
        systemOutput: String? = nil,
        manageSoundEffects: Bool = true
    ) {
        self.devices = devices
        self.manageSoundEffects = manageSoundEffects
        let byUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        current = [
            .output: currentOutput.flatMap { byUID[$0] },
            .input: currentInput.flatMap { byUID[$0] },
        ]
        self.systemOutput = systemOutput.flatMap { byUID[$0] }
    }

    func allDevices() -> [AudioDevice] { devices }

    func defaultDevice(for direction: Direction) -> AudioDevice? {
        current[direction] ?? nil
    }

    @discardableResult
    func setDefault(_ device: AudioDevice, direction: Direction) -> OSStatus {
        usageCount += 1
        current[direction] = device
        if direction == .output, manageSoundEffects {
            systemOutput = device
        }
        return noErr
    }
}

// MARK: - Fixtures (fresh values per call — tests stay fully isolated)

enum Fixtures {
    static func devices() -> [AudioDevice] {
        [
            AudioDevice(
                id: 1, uid: "evolve", name: "Jabra Evolve 75 SE", transportClass: .bluetooth, isOutput: true,
                isInput: true),
            AudioDevice(
                id: 2, uid: "jabra510", name: "Jabra SPEAK 510 USB", transportClass: .usb, isOutput: true, isInput: true
            ),
            AudioDevice(
                id: 3, uid: "spk", name: "MacBook Pro Speakers", transportClass: .builtIn, isOutput: true,
                isInput: false),
            AudioDevice(
                id: 4, uid: "mic", name: "MacBook Pro Microphone", transportClass: .builtIn, isOutput: false,
                isInput: true),
            AudioDevice(
                id: 5, uid: "dell", name: "DELL U3824DW", transportClass: .displayPort, isOutput: true, isInput: false),
            AudioDevice(
                id: 6, uid: "teams", name: "Microsoft Teams Audio", transportClass: .virtual, isOutput: true,
                isInput: true),
        ]
    }

    /// The documented configuration: Headset > Jabra speaker > internal.
    static func engine() throws -> PriorityEngine {
        try PriorityEngine(
            config: AppConfig(
                outputs: [
                    PriorityEntry(
                        match: "Evolve|WH-1000|Rienok|EarPods", symbol: "headphones", title: "Headset"),
                    PriorityEntry(match: "SPEAK 510", symbol: "hifispeaker.fill", title: "Speaker"),
                    PriorityEntry(
                        match: "MacBook Pro Speakers|Built-in", symbol: "laptopcomputer", title: "Built-in"),
                ],
                inputs: [
                    PriorityEntry(
                        match: "Evolve|WH-1000|Rienok|EarPods", symbol: "headphones", title: "Headset"),
                    PriorityEntry(match: "SPEAK 510", symbol: "hifispeaker.fill", title: "Speaker"),
                    PriorityEntry(
                        match: "MacBook Pro Microphone|Built-in", symbol: "laptopcomputer", title: "Built-in"),
                ],
                fallbackSymbol: FallbackSymbols(output: "speaker.wave.3", input: "mic"),
                debounceMs: 500
            )
        )
    }

    static func overlay(
        output: String?,
        input: String?,
        systemOutput: String? = nil,
        manageSoundEffects: Bool = true
    ) -> OverlaySource {
        OverlaySource(
            devices: devices(), currentOutput: output, currentInput: input,
            systemOutput: systemOutput, manageSoundEffects: manageSoundEffects
        )
    }
}
