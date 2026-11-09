import CoreAudio
import Foundation
import KithCore

final class MacAudioHardware: AudioHardware {
    func outputs() throws -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices))
        return devices.compactMap { device in
            guard let uid = try? string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = try? string(device, selector: kAudioObjectPropertyName) else { return nil }
            return AudioOutput(uid: uid, name: name)
        }
    }

    func defaultOutput() throws -> AudioOutput? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        guard device != kAudioObjectUnknown else { return nil }
        return AudioOutput(uid: try string(device, selector: kAudioDevicePropertyDeviceUID),
                           name: try string(device, selector: kAudioObjectPropertyName))
    }

    func isMuted(uid: String) throws -> Bool {
        let device = try device(for: uid)
        var address = muteAddress
        var size = UInt32(MemoryLayout<UInt32>.size)
        var muted: UInt32 = 0
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted))
        return muted != 0
    }

    func setMuted(_ muted: Bool, uid: String) throws {
        let device = try device(for: uid)
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func device(for uid: String) throws -> AudioObjectID {
        var value: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        return try withUnsafeMutablePointer(to: &value) { input in
            try withUnsafeMutablePointer(to: &device) { output in
                var translation = AudioValueTranslation(mInputData: input, mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: output, mOutputDataSize: UInt32(MemoryLayout<AudioObjectID>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation))
                guard output.pointee != kAudioObjectUnknown else { throw PowerError.unavailable("Audio output is disconnected") }
                return output.pointee
            }
        }
    }

    private func string(_ device: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value))
        guard let value else { throw PowerError.unavailable("Audio device name is unavailable") }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw PowerError.unavailable("Audio device does not support this operation (\(status))") }
    }
}
