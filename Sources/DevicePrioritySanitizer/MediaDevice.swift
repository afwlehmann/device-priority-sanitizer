import CoreAudio
import Foundation

/// A managed device class: `output`/`input` are the CoreAudio directions,
/// `camera` is the video capture target (the AVFoundation system-preferred
/// camera). CLI positional arguments and config keys use the raw values.
enum Target: String, CaseIterable, Sendable {
    case output
    case input
    case camera

    /// Human-facing title used in the menubar submenus and `menu-text`.
    var menuTitle: String {
        switch self {
        case .output: return "Speaker"
        case .input: return "Microphone"
        case .camera: return "Camera"
        }
    }

    /// Lowercase block label used by `menu-text`'s deterministic rendering.
    var menuLabel: String {
        switch self {
        case .output: return "speaker"
        case .input: return "microphone"
        case .camera: return "camera"
        }
    }
}

/// Device transports, shared by audio and camera devices.
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
    case continuity
    case deskView
    case other

    var isSynthetic: Bool {
        switch self {
        case .virtual, .aggregate, .airPlay, .deskView: return true
        default: return false
        }
    }
}

/// A capture device as the pure core sees it. Identified by `uid` (the
/// CoreAudio device UID / `AVCaptureDevice.uniqueID`), never by a transient
/// numeric id — numeric ids are a CoreAudio write-mechanics detail owned by
/// the audio source.
struct MediaDevice: Hashable, Sendable {
    let uid: String
    let name: String
    let transportClass: TransportClass
    /// AVFoundation device type for camera devices, `nil` for audio. Emitted
    /// by `list --json` as `deviceType`.
    let deviceType: String?
    let capabilities: Set<Target>

    var isManaged: Bool { !transportClass.isSynthetic }

    func supports(_ target: Target) -> Bool {
        capabilities.contains(target)
    }
}

/// Where device state comes from: real CoreAudio + AVFoundation, or an
/// injected fixture table (headless test seam, `--devices <file>`).
protocol DeviceSource: Sendable {
    func allDevices() -> [MediaDevice]
    func defaultDevice(for target: Target) -> MediaDevice?
    @discardableResult
    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus
}

// MARK: - CoreAudio helpers

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func getUInt32(
    _ id: AudioDeviceID,
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
    _ id: AudioDeviceID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var addr = propertyAddress(selector, scope: scope)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
    }
    guard status == noErr, let cf = value?.takeUnretainedValue() else { return nil }
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

// MARK: - Audio source (CoreAudio, output/input only)

/// CoreAudio-backed source for the audio targets. Camera calls are refused —
/// the camera target belongs to `CameraDeviceSource`, and `SystemDeviceSource`
/// routes accordingly. Main-thread confined (agent/CLI), hence the unchecked
/// `Sendable` on the mutable uid→id cache.
final class CoreAudioDeviceSource: DeviceSource, @unchecked Sendable {
    private let manageSoundEffects: Bool
    /// CoreAudio writes need the numeric `AudioDeviceID`; rebuilt on every
    /// enumeration so a write resolves the uid of the moment.
    private var idsByUID: [String: AudioDeviceID] = [:]

    init(manageSoundEffects: Bool = true) {
        self.manageSoundEffects = manageSoundEffects
    }

    func allDevices() -> [MediaDevice] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        var readSize = size
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &readSize, &ids) == noErr else { return [] }
        let pairs = ids.compactMap { id in
            device(id: id).map { (device: $0, id: id) }
        }
        idsByUID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.device.uid, $0.id) })
        return pairs.map(\.device)
    }

    func defaultDevice(for target: Target) -> MediaDevice? {
        switch target {
        case .camera: return nil
        case .output, .input:
            let systemObject = AudioObjectID(kAudioObjectSystemObject)
            let selector: AudioObjectPropertySelector =
                target == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
            guard
                let id = getUInt32(systemObject, selector),
                id != 0
            else { return nil }
            return device(id: id)
        }
    }

    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus {
        switch target {
        case .camera:
            return OSStatus(paramErr)
        case .output, .input:
            let selector: AudioObjectPropertySelector =
                target == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
            let primary = writeDefaultDevice(device, selector: selector)
            guard primary == noErr else { return primary }
            guard target == .output, manageSoundEffects else { return primary }
            return writeDefaultDevice(device, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
    }

    private func writeDefaultDevice(
        _ device: MediaDevice,
        selector: AudioObjectPropertySelector
    ) -> OSStatus {
        guard let id = audioDeviceID(for: device.uid) else { return kAudioHardwareBadObjectError }
        var addr = propertyAddress(selector)
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(systemObject, &addr, 0, nil, size, pointer)
        }
    }

    /// Resolves the numeric id for a uid, re-enumerating once when the cached
    /// mapping predates the device's appearance.
    private func audioDeviceID(for uid: String) -> AudioDeviceID? {
        if let id = idsByUID[uid] { return id }
        _ = allDevices()
        return idsByUID[uid]
    }

    private func device(id: AudioDeviceID) -> MediaDevice? {
        guard
            let name = getString(id, kAudioDevicePropertyDeviceNameCFString),
            let uid = getString(id, kAudioDevicePropertyDeviceUID),
            let rawTransport = getUInt32(id, kAudioDevicePropertyTransportType)
        else { return nil }
        let isOutput = channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        let isInput = channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
        return MediaDevice(
            uid: uid,
            name: name,
            transportClass: transportClass(for: rawTransport),
            deviceType: nil,
            capabilities: isOutput && isInput ? [.output, .input] : isOutput ? [.output] : [.input]
        )
    }
}

// MARK: - System composite

/// Composite over the audio (CoreAudio) and camera (AVFoundation) subsystems,
/// routing per target. The sound-effects mirror stays inside the audio
/// source; a camera write never touches the effects slot.
final class SystemDeviceSource: DeviceSource {
    private let audio: CoreAudioDeviceSource
    private let camera: CameraDeviceSource

    init(manageSoundEffects: Bool = true) {
        audio = CoreAudioDeviceSource(manageSoundEffects: manageSoundEffects)
        camera = CameraDeviceSource()
    }

    func allDevices() -> [MediaDevice] {
        audio.allDevices() + camera.allDevices()
    }

    func defaultDevice(for target: Target) -> MediaDevice? {
        switch target {
        case .output, .input: return audio.defaultDevice(for: target)
        case .camera: return camera.defaultDevice(for: target)
        }
    }

    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus {
        switch target {
        case .output, .input: return audio.setDefault(device, target: target)
        case .camera: return camera.setDefault(device, target: target)
        }
    }
}

// MARK: - Fixture source (headless test seam)

struct FixtureDevice: Codable, Sendable {
    let uid: String
    let name: String
    let transport: TransportClass
    let isOutput: Bool
    let isInput: Bool
    /// Absent in audio-only fixtures (older tables predate cameras); decodes
    /// as `nil` → the device has no camera capability.
    let isCamera: Bool?
    /// Optional AVFoundation device type string for camera fixtures; decodes
    /// as `nil` for tables that do not model it.
    let deviceType: String?
}

struct FixtureData: Codable, Sendable {
    let devices: [FixtureDevice]
    let defaultOutput: String?
    let defaultInput: String?
    let defaultSystemOutput: String?
    /// Absent in audio-only fixtures; decodes as `nil` → no current camera.
    let defaultCamera: String?
}

/// In-memory device table. The pure initializer takes decoded fixture data;
/// the `path` convenience is the I/O boundary. Never touches real devices;
/// `setDefault` only mutates the in-memory current pointers, and the CLI
/// refuses fixture-mode writes without `--dry-run`.
final class FixtureDeviceSource: DeviceSource, @unchecked Sendable {
    private let devices: [MediaDevice]
    private let manageSoundEffects: Bool
    private var currentUIDs: [Target: String]
    private var systemOutputUID: String?

    init(
        devices: [MediaDevice],
        defaultOutput: String?,
        defaultInput: String?,
        defaultSystemOutput: String? = nil,
        defaultCamera: String? = nil,
        manageSoundEffects: Bool = true
    ) {
        self.devices = devices
        self.manageSoundEffects = manageSoundEffects
        currentUIDs = [
            .output: defaultOutput ?? "",
            .input: defaultInput ?? "",
            .camera: defaultCamera ?? "",
        ]
        systemOutputUID = defaultSystemOutput
    }

    convenience init(path: String, manageSoundEffects: Bool = true) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONDecoder().decode(FixtureData.self, from: data)
        self.init(
            devices: fixture.devices.map { fixtureDevice in
                MediaDevice(
                    uid: fixtureDevice.uid,
                    name: fixtureDevice.name,
                    transportClass: fixtureDevice.transport,
                    deviceType: fixtureDevice.deviceType,
                    capabilities: Set(
                        Target.allCases.filter { target in
                            switch target {
                            case .output: return fixtureDevice.isOutput
                            case .input: return fixtureDevice.isInput
                            case .camera: return fixtureDevice.isCamera ?? false
                            }
                        }
                    )
                )
            },
            defaultOutput: fixture.defaultOutput,
            defaultInput: fixture.defaultInput,
            defaultSystemOutput: fixture.defaultSystemOutput,
            defaultCamera: fixture.defaultCamera,
            manageSoundEffects: manageSoundEffects
        )
    }

    func allDevices() -> [MediaDevice] { devices }

    func defaultDevice(for target: Target) -> MediaDevice? {
        guard let uid = currentUIDs[target], !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// The sound-effects/alert pointer (test observation; mirrors the default
    /// output when `manageSoundEffects` is enabled).
    func systemOutputDevice() -> MediaDevice? {
        guard let uid = systemOutputUID, !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus {
        currentUIDs[target] = device.uid
        if target == .output, manageSoundEffects {
            systemOutputUID = device.uid
        }
        return noErr
    }
}
