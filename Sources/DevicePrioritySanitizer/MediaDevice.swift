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
    /// CoreAudio model UID (`kAudioDevicePropertyModelUID`), `nil` where the
    /// platform has none. Used by the saved-levels replacement match: a
    /// defective unit swapped for the same model keeps restoring its level.
    var modelUID: String? = nil
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
    /// The device's current 0…1 volume in the target's direction; `nil`
    /// when the device has no volume control (always for the camera target).
    func volume(for device: MediaDevice, target: Target) -> Float?
    /// Writes the 0…1 volume (clamped); the returned OSStatus decides —
    /// unlike the camera preference, volume writes have a real error channel.
    @discardableResult
    func setVolume(_ level: Float, for device: MediaDevice, target: Target) -> OSStatus
}

extension DeviceSource {
    func volume(for device: MediaDevice, target: Target) -> Float? { nil }

    @discardableResult
    func setVolume(_ level: Float, for device: MediaDevice, target: Target) -> OSStatus {
        OSStatus(paramErr)
    }
}

// MARK: - CoreAudio helpers

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getFloat32(
    _ id: AudioDeviceID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) -> Float32? {
    var addr = propertyAddress(selector, scope: scope, element: element)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
    }
    return status == noErr ? value : nil
}

private func setFloat32(
    _ value: Float32,
    _ id: AudioDeviceID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) -> OSStatus {
    var addr = propertyAddress(selector, scope: scope, element: element)
    var scalar = value
    let size = UInt32(MemoryLayout<Float32>.size)
    return withUnsafeMutablePointer(to: &scalar) { pointer in
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, pointer)
    }
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

    /// Volume via `kAudioDevicePropertyVolumeScalar`: the main element when
    /// the device has one, otherwise the per-channel elements (read: the
    /// channel average, write: every channel).
    func volume(for device: MediaDevice, target: Target) -> Float? {
        switch target {
        case .camera:
            return nil
        case .output, .input:
            guard let id = audioDeviceID(for: device.uid) else { return nil }
            let scope: AudioObjectPropertyScope =
                target == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
            var main = propertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope)
            if AudioObjectHasProperty(id, &main) {
                return getFloat32(
                    id, kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain
                )
            }
            let channels = channelCount(id, scope: scope)
            guard channels > 0 else { return nil }
            var total: Float32 = 0
            var found = 0
            for element in 1...UInt32(channels) {
                if let value = getFloat32(
                    id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element
                ) {
                    total += value
                    found += 1
                }
            }
            return found > 0 ? total / Float32(found) : nil
        }
    }

    @discardableResult
    func setVolume(_ level: Float, for device: MediaDevice, target: Target) -> OSStatus {
        guard target != .camera, let id = audioDeviceID(for: device.uid) else { return OSStatus(paramErr) }
        let scope: AudioObjectPropertyScope =
            target == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        let clamped = min(max(level, 0), 1)
        var main = propertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope)
        if AudioObjectHasProperty(id, &main) {
            return setFloat32(
                Float32(clamped), id, kAudioDevicePropertyVolumeScalar, scope: scope,
                element: kAudioObjectPropertyElementMain
            )
        }
        let channels = channelCount(id, scope: scope)
        guard channels > 0 else { return OSStatus(paramErr) }
        for element in 1...UInt32(channels) {
            let status = setFloat32(
                Float32(clamped), id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element
            )
            guard status == noErr else { return status }
        }
        return noErr
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
            modelUID: getString(id, kAudioDevicePropertyModelUID),
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

    func volume(for device: MediaDevice, target: Target) -> Float? {
        switch target {
        case .output, .input: return audio.volume(for: device, target: target)
        case .camera: return nil
        }
    }

    @discardableResult
    func setVolume(_ level: Float, for device: MediaDevice, target: Target) -> OSStatus {
        switch target {
        case .output, .input: return audio.setVolume(level, for: device, target: target)
        case .camera: return OSStatus(paramErr)
        }
    }
}

// MARK: - Fixture source (headless test seam)

/// Per-direction volume seeds for a fixture device — a seeded direction is
/// volume-capable, an unseeded one is not.
struct FixtureVolume: Codable, Equatable, Sendable {
    let output: Float?
    let input: Float?
}

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
    /// Optional CoreAudio model UID; decodes as `nil` for older fixtures.
    /// Seeds `MediaDevice.modelUID` for the saved-levels replacement match.
    let modelUID: String?
    /// Optional volume seeds; decodes as `nil` for older fixtures.
    let volume: FixtureVolume?
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
/// refuses fixture-mode writes without `--dry-run`. Volume seeds mark a
/// direction volume-capable; `setVolume` updates the in-memory value (tests
/// observe the write without hardware).
final class FixtureDeviceSource: DeviceSource, @unchecked Sendable {
    private let devices: [MediaDevice]
    private let manageSoundEffects: Bool
    private var currentUIDs: [Target: String]
    private var systemOutputUID: String?
    private var volumes: [Target: [String: Float]]

    init(
        devices: [MediaDevice],
        defaultOutput: String?,
        defaultInput: String?,
        defaultSystemOutput: String? = nil,
        defaultCamera: String? = nil,
        manageSoundEffects: Bool = true,
        volumes: [Target: [String: Float]] = [:]
    ) {
        self.devices = devices
        self.manageSoundEffects = manageSoundEffects
        currentUIDs = [
            .output: defaultOutput ?? "",
            .input: defaultInput ?? "",
            .camera: defaultCamera ?? "",
        ]
        systemOutputUID = defaultSystemOutput
        self.volumes = volumes
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
                    modelUID: fixtureDevice.modelUID,
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
            manageSoundEffects: manageSoundEffects,
            volumes: fixture.devices.reduce(into: [Target: [String: Float]]()) { map, fixtureDevice in
                if let output = fixtureDevice.volume?.output {
                    map[.output, default: [:]][fixtureDevice.uid] = output
                }
                if let input = fixtureDevice.volume?.input {
                    map[.input, default: [:]][fixtureDevice.uid] = input
                }
            }
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

    func volume(for device: MediaDevice, target: Target) -> Float? {
        guard target != .camera else { return nil }
        return volumes[target]?[device.uid]
    }

    @discardableResult
    func setVolume(_ level: Float, for device: MediaDevice, target: Target) -> OSStatus {
        guard target != .camera else { return OSStatus(paramErr) }
        volumes[target, default: [:]][device.uid] = level
        return noErr
    }
}
