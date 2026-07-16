import AVFoundation
import CoreAudio
import Foundation

enum MicrophoneManager {
    private static let microphoneDiscoveryDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInMicrophone,
        .externalUnknown
    ]

    static func availableMicrophones() -> [MicrophoneOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: microphoneDiscoveryDeviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        var devicesByUID: [String: MicrophoneOption] = [:]
        for device in session.devices {
            devicesByUID[device.uniqueID] = MicrophoneOption(uid: device.uniqueID, name: device.localizedName)
        }

        return devicesByUID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultMicrophoneUID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    static func builtInMicrophoneUID() -> String? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.first?.uniqueID
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )

        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else {
            return nil
        }

        return defaultDeviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let uidRef = uid as CFString
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafePointer(to: uidRef) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    static func setDefaultInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var requested = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &requested
        )

        return status == noErr
    }

    static func recoverDefaultInputDevice(preferredUID: String? = nil) -> String? {
        var candidateUIDs: [String] = []

        func appendCandidate(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !candidateUIDs.contains(trimmed) else { return }
            candidateUIDs.append(trimmed)
        }

        appendCandidate(preferredUID)
        appendCandidate(builtInMicrophoneUID())
        appendCandidate(defaultMicrophoneUID())
        availableMicrophones().forEach { appendCandidate($0.uid) }

        let currentDefaultInput = defaultInputDeviceID()
        for uid in candidateUIDs {
            guard let deviceID = deviceID(forUID: uid) else { continue }
            if currentDefaultInput == deviceID {
                return uid
            }
            if setDefaultInput(deviceID: deviceID) {
                return uid
            }
        }

        return nil
    }
}

struct MicrophoneOption: Identifiable, Hashable {
    let uid: String
    let name: String

    var id: String { uid }
}
