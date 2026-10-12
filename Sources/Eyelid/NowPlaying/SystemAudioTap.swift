import AudioToolbox
import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AudioTap")

/// Listens to everything the Mac plays, through a Core Audio process tap, and measures it for the equalizer.
///
/// Nothing is recorded: each buffer is measured on Core Audio's thread and dropped. macOS asks the user once to allow
/// Eyelid to record system audio, and shows that it does in Privacy & Security.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    /// The latest level of each band, from 0 to 1, read from the main thread.
    let levels = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.bands.count))

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.satis-ku.eyelid.audio-tap", qos: .userInteractive)
    // Only touched on `queue`, from the IO block.
    private let analyzer = SpectrumAnalyzer()
    /// Room for more frames than Core Audio delivers at once, so the real-time thread never allocates.
    private var mono = [Float](repeating: 0, count: 8_192)
    private var measured = [Float](repeating: 0, count: SpectrumAnalyzer.bands.count)

    /// Starts listening. Returns false if Core Audio refuses.
    ///
    /// The aggregate device holds the tap alone, with no output in it: with the output in, Eyelid took part in the
    /// audio on that output, and Bluetooth's smart routing counted it as the app playing to AirPods, ahead of every
    /// other. It then kept sound on them when another output was picked, and kept AirPods from switching to another
    /// device.
    func start() -> Bool {
        stop()

        // Everything but Eyelid's own sound: an app at its own volume plays through Eyelid, and the tap would hear it
        // twice, from the app, which it hears though macOS mutes it, and from Eyelid.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Eyelid equalizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            logger.error("Could not create the tap: \(status, privacy: .public)")
            return false
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eyelid equalizer",
            kAudioAggregateDeviceUIDKey: OutputDevice.ownDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            logger.error("Could not create the aggregate device: \(status, privacy: .public)")
            stop()
            return false
        }

        let format: AudioStreamBasicDescription? = AudioProperty.value(AudioProperty.address(kAudioTapPropertyFormat), of: tapID)
        let sampleRate = format?.mSampleRate ?? 48_000
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input, sampleRate: sampleRate)
        }
        guard status == noErr else {
            logger.error("Could not create the IO proc: \(status, privacy: .public)")
            stop()
            return false
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            logger.error("Could not start the tap: \(status, privacy: .public)")
            stop()
            return false
        }
        logger.debug("Listening at \(sampleRate, privacy: .public) Hz")
        return true
    }

    /// Eyelid's own process, as Core Audio knows it.
    private static var ownProcess: AudioObjectID? {
        var address = AudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        levels.withLock { $0 = [Float](repeating: 0, count: SpectrumAnalyzer.bands.count) }
    }

    deinit {
        stop()
    }

    /// Mixes the buffers down to mono and measures them. Runs on `queue`.
    private func receive(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }

        // Either one interleaved buffer, or one buffer a channel.
        let interleaved = buffers.count == 1 ? Int(max(first.mNumberChannels, 1)) : 1
        let frames = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size / interleaved, mono.count)
        mono.withUnsafeMutableBufferPointer { mono in
            mono.update(repeating: 0)
            var channels: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(max(buffer.mNumberChannels, 1))
                for channel in 0..<stride {
                    for frame in 0..<frames {
                        mono[frame] += data[frame * stride + channel]
                    }
                    channels += 1
                }
            }
            if channels > 1 {
                for frame in 0..<frames {
                    mono[frame] /= channels
                }
            }
            let samples = UnsafeBufferPointer(rebasing: mono[0..<frames])
            if analyzer.add(samples, sampleRate: sampleRate, into: &measured) {
                // Element by element, so neither array is copied.
                measured.withUnsafeBufferPointer { measured in
                    levels.withLockUnchecked { levels in
                        for band in levels.indices {
                            levels[band] = measured[band]
                        }
                    }
                }
            }
        }
    }
}
