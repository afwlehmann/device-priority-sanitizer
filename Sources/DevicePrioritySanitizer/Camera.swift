import AVFoundation
import CoreAudio
import Foundation

/// AVFoundation-backed camera source.
///
/// - Discovery: `AVCaptureDevice.DiscoverySession` over the built-in,
///   external, Continuity, and Desk View camera types.
/// - Current camera: `AVCaptureDevice.systemPreferredCamera`.
/// - Write: `AVCaptureDevice.userPreferredCamera` — the system's preferred
///   camera, which apps following the system default pick up (see AGENTS.md
///   for the per-app picker caveat).
///
/// Never opens a capture session and never requests camera TCC. The setter
/// has no error channel, so every write is verified by re-reading the
/// preference with a bounded runloop spin; a silent no-op surfaces as a
/// non-`noErr` status, which the CLI maps to a software failure.
///
/// The write path is deliberately isolated in `setDefault` so a fallback
/// backend (e.g. the CoreMediaIO default input device) would be a one-place
/// change behind the same `DeviceSource` seam.
final class CameraDeviceSource: DeviceSource {
    /// `.external` replaces `.externalUnknown` on macOS 14; the latter remains
    /// for macOS 13 where the camera APIs first shipped.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        return types
    }()

    init() {}

    func allDevices() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map(Self.device)
    }

    func defaultDevice(for target: Target) -> MediaDevice? {
        guard target == .camera else { return nil }
        guard let current = AVCaptureDevice.systemPreferredCamera else { return nil }
        // Resolve to the enumerated view so uid/name/transport stay
        // consistent; fall back to constructing from the AVCaptureDevice
        // itself should the preferred camera not be in the discovery list.
        return allDevices().first { $0.uid == current.uniqueID } ?? Self.device(current)
    }

    func setDefault(_ device: MediaDevice, target: Target) -> OSStatus {
        guard target == .camera else { return OSStatus(paramErr) }
        guard let avDevice = AVCaptureDevice(uniqueID: device.uid) else { return OSStatus(paramErr) }
        AVCaptureDevice.userPreferredCamera = avDevice
        let deadline = Date().addingTimeInterval(0.1)
        while AVCaptureDevice.userPreferredCamera?.uniqueID != device.uid, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return AVCaptureDevice.userPreferredCamera?.uniqueID == device.uid ? noErr : OSStatus(paramErr)
    }

    /// Maps an AVFoundation capture device into the pure model.
    ///
    /// macOS has no public "is a virtual camera" flag (`isVirtualDevice` is
    /// iOS-only), so virtual cameras (OBS Virtual Camera and friends) are
    /// recognized by their conventional name — the one platform signal
    /// available. Desk View is excluded via its dedicated device type.
    private static func device(_ device: AVCaptureDevice) -> MediaDevice {
        let transport: TransportClass
        if device.localizedName.range(of: "Virtual Camera", options: .caseInsensitive) != nil {
            transport = .virtual
        } else {
            switch device.deviceType {
            case .builtInWideAngleCamera: transport = .builtIn
            case .continuityCamera: transport = .continuity
            case .deskViewCamera: transport = .deskView
            default: transport = .usb
            }
        }
        return MediaDevice(
            uid: device.uniqueID,
            name: device.localizedName,
            transportClass: transport,
            deviceType: device.deviceType.rawValue,
            capabilities: [.camera]
        )
    }
}
