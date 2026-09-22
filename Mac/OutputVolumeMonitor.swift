import Combine
import CoreAudio
import Foundation

/// Watches the current default output device's master volume so the Mac's volume
/// keys can drive the forwarded-audio gain.
///
/// With a virtual device like BlackHole as the output, the volume keys change
/// its volume but the device does not attenuate its loopback stream, so the keys
/// otherwise do nothing audible. This bridges that volume into the app's gain:
/// every change is reported through `onChange`, and `setVolume` writes back so
/// the slider and the keys stay one control.
@MainActor
final class OutputVolumeMonitor: ObservableObject {
    @Published private(set) var volume: Double = 1
    var onChange: (@MainActor (Double) -> Void)?

    private var device = AudioDeviceID(0)
    private var volumeListener: AudioObjectPropertyListenerBlock?
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

    /// Slider -> device. A no-op when the device exposes no volume.
    func setVolume(_ value: Double) {
        guard device != 0, hasVolume(device) else { return }
        var address = volumeAddress
        var scalar = Float(min(max(value, 0), 1))
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

    private func hasVolume(_ id: AudioDeviceID) -> Bool {
        var address = volumeAddress
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

    private func bindToDefaultDevice() {
        removeVolumeListener()
        var address = defaultDeviceAddress
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr else { return }
        device = id
        guard hasVolume(id) else {
            publish(readVolume(id) ?? 1)
            return
        }
        var volumeAddress = self.volumeAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.publish(self.readVolume(id) ?? 1)
            }
        }
        volumeListener = listener
        AudioObjectAddPropertyListenerBlock(id, &volumeAddress, DispatchQueue.main, listener)
        publish(readVolume(id) ?? 1)
    }

    private func removeVolumeListener() {
        guard device != 0, let listener = volumeListener else { return }
        var address = volumeAddress
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, listener)
        volumeListener = nil
    }

    private func publish(_ value: Double) {
        guard abs(value - volume) > 0.001 else { return }   // ignore our own write-back echo
        volume = value
        onChange?(value)
    }
}
