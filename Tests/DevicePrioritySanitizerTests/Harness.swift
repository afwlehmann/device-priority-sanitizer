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
/// without any CoreAudio or AVFoundation dependency.
final class OverlaySource: DeviceSource, @unchecked Sendable {
    private let devices: [MediaDevice]
    private var current: [Target: MediaDevice?]
    private let manageSoundEffects: Bool
    private(set) var systemOutput: MediaDevice?
    private(set) var usageCount = 0

    init(
        devices: [MediaDevice],
        currentOutput: String?,
        currentInput: String?,
        currentCamera: String? = nil,
        systemOutput: String? = nil,
        manageSoundEffects: Bool = true
    ) {
        self.devices = devices
        self.manageSoundEffects = manageSoundEffects
        let byUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        current = [
            .output: currentOutput.flatMap { byUID[$0] },
            .input: currentInput.flatMap { byUID[$0] },
            .camera: currentCamera.flatMap { byUID[$0] },
        ]
        self.systemOutput = systemOutput.flatMap { byUID[$0] }
    }

    func allDevices() -> [MediaDevice] { devices }

    func defaultDevice(for target: Target) -> MediaDevice? {
        current[target] ?? nil
    }

    @discardableResult
    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus {
        usageCount += 1
        current[target] = device
        if target == .output, manageSoundEffects {
            systemOutput = device
        }
        return noErr
    }
}

// MARK: - Fixtures (fresh values per call — tests stay fully isolated)

enum Fixtures {
    static func devices() -> [MediaDevice] {
        [
            MediaDevice(
                uid: "evolve", name: "Jabra Evolve 75 SE", transportClass: .bluetooth, deviceType: nil,
                capabilities: [.output, .input]),
            MediaDevice(
                uid: "jabra510", name: "Jabra SPEAK 510 USB", transportClass: .usb, deviceType: nil,
                capabilities: [.output, .input]),
            MediaDevice(
                uid: "spk", name: "MacBook Pro Speakers", transportClass: .builtIn, deviceType: nil,
                capabilities: [.output]),
            MediaDevice(
                uid: "mic", name: "MacBook Pro Microphone", transportClass: .builtIn, deviceType: nil,
                capabilities: [.input]),
            MediaDevice(
                uid: "dell", name: "DELL U3824DW", transportClass: .displayPort, deviceType: nil,
                capabilities: [.output]),
            MediaDevice(
                uid: "teams", name: "Microsoft Teams Audio", transportClass: .virtual, deviceType: nil,
                capabilities: [.output, .input]),
            MediaDevice(
                uid: "camlink", name: "Elgato Cam Link 4K", transportClass: .usb,
                deviceType: "AVCaptureDeviceTypeExternal",
                capabilities: [.camera]),
            MediaDevice(
                uid: "iphone", name: "iPhone Continuity Camera", transportClass: .continuity,
                deviceType: "AVCaptureDeviceTypeContinuityCamera", capabilities: [.camera]),
            MediaDevice(
                uid: "facetime", name: "FaceTime HD Camera", transportClass: .builtIn,
                deviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera",
                capabilities: [.camera]),
            MediaDevice(
                uid: "obsvirtual", name: "OBS Virtual Camera", transportClass: .virtual, deviceType: nil,
                capabilities: [.camera]),
        ]
    }

    /// The documented configuration: Headset > Jabra speaker > internal for
    /// audio; External > Continuity > Built-in for cameras.
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
                cameras: [
                    PriorityEntry(
                        match: "Cam Link|Elgato|Brio|C920|C922|C930|Kiyo|USB Video|USB Camera",
                        symbol: "video", title: "External"),
                    PriorityEntry(match: "iPhone|Continuity Camera", symbol: "iphone", title: "Continuity"),
                    PriorityEntry(match: "FaceTime", symbol: "laptopcomputer", title: "Built-in"),
                ],
                fallbackSymbol: FallbackSymbols(output: "speaker.wave.3", input: "mic", camera: "video"),
                debounceMs: 500
            )
        )
    }

    static func overlay(
        output: String?,
        input: String?,
        camera: String? = nil,
        systemOutput: String? = nil,
        manageSoundEffects: Bool = true
    ) -> OverlaySource {
        OverlaySource(
            devices: devices(), currentOutput: output, currentInput: input, currentCamera: camera,
            systemOutput: systemOutput, manageSoundEffects: manageSoundEffects
        )
    }
}
