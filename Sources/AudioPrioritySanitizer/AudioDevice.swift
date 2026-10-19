import CoreAudio
import Foundation

enum Direction: String, CaseIterable, Sendable {
    case output
    case input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

/// CoreAudio transport classes.
///
/// `isSynthetic` drives exclusion from the menu *and* from auto-selection.
/// The set is deliberately centralized: enabling a future transport class
/// (e.g. treating AirPlay as managed) is a one-place change here, not a
/// config-format break (see AGENTS.md).
enum TransportClass: String, Codable, CaseIterable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case displayPort
    case fireWire
    case thunderbolt
    case pci
    case virtual
    case aggregate
    case airPlay
    case other

    var isSynthetic: Bool {
        switch self {
        case .virtual, .aggregate, .airPlay: return true
        default: return false
        }
    }
}

struct AudioDevice: Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportClass: TransportClass
    let isOutput: Bool
    let isInput: Bool

    var isManaged: Bool { !transportClass.isSynthetic }

    func isDirection(_ direction: Direction) -> Bool {
        direction == .output ? isOutput : isInput
    }
}

/// Where device state comes from: real CoreAudio, or an injected fixture
/// (headless test seam, `--devices <file>`).
protocol DeviceSource: Sendable {
    func allDevices() -> [AudioDevice]
    func defaultDevice(for direction: Direction) -> AudioDevice?
    @discardableResult
    func setDefault(_ device: AudioDevice, direction: Direction) -> OSStatus
}

// MARK: - CoreAudio helpers

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func getUInt32(
    _ id: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var addr = propertyAddress(selector, scope: scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
    }
    return status == noErr ? value : nil
}

private func getString(
    _ id: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var addr = propertyAddress(selector, scope: scope)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
    }
    guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
    return cf as String
}

private func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    // The buffer list is variable-length: one AudioBuffer per stream, so the
    // allocation must span the full property size (not a single AudioBufferList).
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bufferList)
    guard status == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// 'blue' — kAudioDeviceTransportTypeBluetoothA2DP is not exported to Swift
/// by the SDK overlay, so use the FourCC directly.
private let transportTypeBluetoothA2DP: UInt32 = 0x626C_7565

private func transportClass(for raw: UInt32) -> TransportClass {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return .builtIn
    case kAudioDeviceTransportTypeUSB: return .usb
    case kAudioDeviceTransportTypeBluetooth, transportTypeBluetoothA2DP: return .bluetooth
    case kAudioDeviceTransportTypeDisplayPort: return .displayPort
    case kAudioDeviceTransportTypeFireWire: return .fireWire
    case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
    case kAudioDeviceTransportTypePCI: return .pci
    case kAudioDeviceTransportTypeVirtual: return .virtual
    case kAudioDeviceTransportTypeAggregate: return .aggregate
    case kAudioDeviceTransportTypeAirPlay: return .airPlay
    default: return .other
    }
}

// MARK: - Real source

final class CoreAudioDeviceSource: DeviceSource {
    func allDevices() -> [AudioDevice] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        var readSize = size
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &readSize, &ids) == noErr else { return [] }
        return ids.compactMap { device(id: $0) }
    }

    func defaultDevice(for direction: Direction) -> AudioDevice? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard let id = getUInt32(systemObject, direction.defaultDeviceSelector), id != 0 else { return nil }
        return device(id: id)
    }

    func setDefault(_ device: AudioDevice, direction: Direction) -> OSStatus {
        var addr = propertyAddress(direction.defaultDeviceSelector)
        var value = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(systemObject, &addr, 0, nil, size, pointer)
        }
    }

    private func device(id: AudioDeviceID) -> AudioDevice? {
        guard
            let name = getString(id, kAudioDevicePropertyDeviceNameCFString),
            let uid = getString(id, kAudioDevicePropertyDeviceUID),
            let rawTransport = getUInt32(id, kAudioDevicePropertyTransportType)
        else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transportClass: transportClass(for: rawTransport),
            isOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
            isInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
        )
    }
}

// MARK: - Fixture source (headless test seam)

struct FixtureDevice: Codable, Sendable {
    let uid: String
    let name: String
    let transport: TransportClass
    let isOutput: Bool
    let isInput: Bool
}

struct FixtureData: Codable, Sendable {
    let devices: [FixtureDevice]
    let defaultOutput: String?
    let defaultInput: String?
}

/// In-memory device table. The pure initializer takes decoded fixture data;
/// the `path` convenience is the I/O boundary. Never touches real devices;
/// `setDefault` only mutates the in-memory current pointers, and the CLI
/// refuses fixture-mode writes without `--dry-run`.
final class FixtureDeviceSource: DeviceSource {
    private let devices: [AudioDevice]
    private var currentUIDs: [Direction: String]

    init(devices: [AudioDevice], defaultOutput: String?, defaultInput: String?) {
        self.devices = devices
        currentUIDs = [.output: defaultOutput ?? "", .input: defaultInput ?? ""]
    }

    convenience init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONDecoder().decode(FixtureData.self, from: data)
        self.init(
            devices: fixture.devices.map { fixtureDevice in
                AudioDevice(
                    id: AudioDeviceID(truncatingIfNeeded: fixtureDevice.uid.hashValue),
                    uid: fixtureDevice.uid,
                    name: fixtureDevice.name,
                    transportClass: fixtureDevice.transport,
                    isOutput: fixtureDevice.isOutput,
                    isInput: fixtureDevice.isInput
                )
            }, defaultOutput: fixture.defaultOutput, defaultInput: fixture.defaultInput)
    }

    func allDevices() -> [AudioDevice] { devices }

    func defaultDevice(for direction: Direction) -> AudioDevice? {
        guard let uid = currentUIDs[direction], !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    func setDefault(_ device: AudioDevice, direction: Direction) -> OSStatus {
        currentUIDs[direction] = device.uid
        return noErr
    }
}
