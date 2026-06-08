import Foundation
import CoreAudio
import AppKit

struct AudioDevice: Equatable, Identifiable {
    let id: AudioObjectID
    let name: String
    let uid: String

    var isBlackHole: Bool {
        name.lowercased().contains("blackhole") || uid.lowercased().contains("blackhole")
    }
}

final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    func listOutputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)

        var devices: [AudioDevice] = []
        for id in deviceIDs {
            guard hasOutputChannels(deviceID: id) else { continue }
            let name = deviceName(deviceID: id) ?? "Unknown"
            let uid = deviceUID(deviceID: id) ?? ""
            devices.append(AudioDevice(id: id, name: name, uid: uid))
        }
        return devices
    }

    func currentDefaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &newID
        )
        return status == noErr
    }

    func findBlackHole() -> AudioDevice? {
        listOutputDevices().first(where: { $0.isBlackHole })
    }

    func device(matching deviceUID: String) -> AudioDevice? {
        listOutputDevices().first(where: { $0.uid == deviceUID })
    }

    // MARK: - Per-device volume

    /// Read a device's master output volume (0…1). Falls back to the average of
    /// per-channel volumes if there's no master element. Returns nil if neither
    /// is supported (e.g., the device exposes only a mute/no-volume control).
    func outputVolume(of deviceID: AudioObjectID) -> Float? {
        if let v = scalarVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return v
        }
        // No master element — average channels 1 and 2 if present.
        let l = scalarVolume(deviceID: deviceID, element: 1)
        let r = scalarVolume(deviceID: deviceID, element: 2)
        switch (l, r) {
        case (let a?, let b?): return (a + b) / 2
        case (let a?, nil):    return a
        case (nil, let b?):    return b
        default:               return nil
        }
    }

    /// Write a device's master output volume (0…1). Falls back to setting each
    /// channel individually when there's no master element. Returns true if any
    /// element accepted the new value.
    @discardableResult
    func setOutputVolume(_ volume: Float, of deviceID: AudioObjectID) -> Bool {
        let v = max(0, min(1, volume))
        if setScalarVolume(v, deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return true
        }
        let okL = setScalarVolume(v, deviceID: deviceID, element: 1)
        let okR = setScalarVolume(v, deviceID: deviceID, element: 2)
        return okL || okR
    }

    private func scalarVolume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var v: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &v)
        return status == noErr ? v : nil
    }

    private func setScalarVolume(_ v: Float, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value = v
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        return status == noErr
    }

    // MARK: - Private helpers

    private func hasOutputChannels(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard size > 0 else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { bufferList.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList)
        guard status == noErr else { return false }

        let abl = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for buffer in buffers where buffer.mNumberChannels > 0 { return true }
        return false
    }

    private func deviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func deviceUID(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
