import AudioToolbox
import CoreGraphics

/// How a display's volume is read and set.
enum VolumeBackend: String, Sendable {
    /// The monitor's own speakers, over DDC (VCP 0x62).
    case ddc
    /// The built-in speakers, through CoreAudio.
    case coreaudio
    /// No volume to control: the card shows no volume row.
    case none
}

/// Reads and sets the volume of a display, 0...1. Everything runs on this actor, off the main
/// actor. The store picks the latest slider value and calls `write` at most every 50 ms.
actor Volume {
    static let shared = Volume()

    /// The maximum of VCP 0x62 per display, from its last read.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]

    /// A new read from the monitor or the built-in speakers; nil when there is no volume or no answer.
    func read(_ display: DisplayInfo) async -> Double? {
        switch display.volumeBackend {
        case .ddc:
            guard let reply = await DDC.shared.read(DDC.volume, display: display.id), reply.max > 0
            else { return nil }
            ddcMax[display.id] = reply.max
            return min(Double(reply.current) / Double(reply.max), 1)
        case .coreaudio:
            guard let device = Self.builtInOutput() else { return nil }
            var address = Self.volumeProperty
            var value: Float32 = -1
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
                  (0...1).contains(value)
            else { return nil }
            return Double(value)
        case .none:
            return nil
        }
    }

    /// Sets the volume. A DDC value goes through `DDC.write`, which returns before it is sent.
    func write(_ value: Double, to display: DisplayInfo) async {
        switch display.volumeBackend {
        case .ddc:
            // The maximum comes from a read; the refresh makes one before a slider shows.
            guard let max = ddcMax[display.id] else { return }
            await DDC.shared.write(DDC.volume, value: UInt16((value * Double(max)).rounded()), display: display.id)
        case .coreaudio:
            guard let device = Self.builtInOutput() else { return }
            var address = Self.volumeProperty
            var value = Float32(value)
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        case .none:
            break
        }
    }

    // MARK: CoreAudio

    /// The main volume of an output device, 0...1.
    private static var volumeProperty: AudioObjectPropertyAddress {
        property(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    }

    private static func property(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The built-in speakers: the first device with the built-in transport type that has an output
    /// volume (the built-in microphone has none).
    private static func builtInOutput() -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var transport = property(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
            var volume = volumeProperty
            var type: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &transport, 0, nil, &size, &type) == noErr
                && type == kAudioDeviceTransportTypeBuiltIn && AudioObjectHasProperty(device, &volume)
        }
    }
}
