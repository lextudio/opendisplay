import Combine
import CoreAudio
import Foundation

/// Watches the current default output device's master volume and mute so the
/// Mac's volume and mute keys can drive the forwarded-audio gain.
///
/// With a virtual device like BlackHole as the output, the volume keys change
/// its volume but the device does not attenuate its loopback stream, so the keys
/// otherwise do nothing audible. This bridges that volume into the app's gain:
/// every change is reported through `onChange`, and `setVolume` writes back so
/// the slider and the keys stay one control.
///
/// Mute is a *separate* property (`kAudioDevicePropertyMute`) that leaves the
/// volume scalar untouched, so a monitor that only watches the volume never
/// hears the mute key. The reported gain is therefore the volume, or zero while
/// the device is muted — otherwise muting the Mac left the iPad playing.
@MainActor
final class OutputVolumeMonitor: ObservableObject {
    @Published private(set) var volume: Double = 1
    var onChange: (@MainActor (Double) -> Void)?

    private var device = AudioDeviceID(0)
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.bindToDefaultDevice() }
        }
        defaultDeviceListener = listener
        var address = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, listener)
        bindToDefaultDevice()
    }

    func stop() {
        removeVolumeListener()
        if let listener = defaultDeviceListener {
            var address = defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, listener)
            defaultDeviceListener = nil
        }
    }

    /// Slider -> device. A no-op when the device exposes no volume. Raising the
    /// level also clears a stale mute, so dragging the slider back up is not
    /// immediately overridden by the device still being muted.
    func setVolume(_ value: Double) {
        guard device != 0 else { return }
        let target = min(max(value, 0), 1)
        if target > 0, readMute(device) == true {
            writeMute(device, false)
        }
        guard hasVolume(device) else { return }
        var address = volumeAddress
        var scalar = Float(target)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar)
    }

    // MARK: - CoreAudio plumbing

    private var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func hasVolume(_ id: AudioDeviceID) -> Bool {
        var address = volumeAddress
        return AudioObjectHasProperty(id, &address)
    }

    private func hasMute(_ id: AudioDeviceID) -> Bool {
        var address = muteAddress
        return AudioObjectHasProperty(id, &address)
    }

    private func readVolume(_ id: AudioDeviceID) -> Double? {
        var address = volumeAddress
        var scalar: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectHasProperty(id, &address),
              AudioObjectGetPropertyData(id, &address, 0, nil, &size, &scalar) == noErr else { return nil }
        return Double(scalar)
    }

    private func readMute(_ id: AudioDeviceID) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &address),
              AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func writeMute(_ id: AudioDeviceID, _ muted: Bool) {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The gain the forwarded audio should use: the device volume, or zero when
    /// the device is muted (mute does not move the volume scalar).
    private func effectiveGain(_ id: AudioDeviceID) -> Double {
        if readMute(id) == true { return 0 }
        return readVolume(id) ?? 1
    }

    private func bindToDefaultDevice() {
        removeVolumeListener()
        var address = defaultDeviceAddress
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr else { return }
        device = id
        // Volume and mute are distinct properties; watch both so the keys and
        // the mute key all reach the receiver.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.publish(self.effectiveGain(id))
            }
        }
        var volumeAddress = self.volumeAddress
        if hasVolume(id) {
            volumeListener = listener
            AudioObjectAddPropertyListenerBlock(id, &volumeAddress, DispatchQueue.main, listener)
        }
        var muteAddress = self.muteAddress
        if hasMute(id) {
            muteListener = listener
            AudioObjectAddPropertyListenerBlock(id, &muteAddress, DispatchQueue.main, listener)
        }
        publish(effectiveGain(id))
    }

    private func removeVolumeListener() {
        guard device != 0 else { return }
        if let listener = volumeListener {
            var address = volumeAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, listener)
            volumeListener = nil
        }
        if let listener = muteListener {
            var address = muteAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, listener)
            muteListener = nil
        }
    }

    private func publish(_ value: Double) {
        guard abs(value - volume) > 0.001 else { return }   // ignore our own write-back echo
        volume = value
        onChange?(value)
    }
}
