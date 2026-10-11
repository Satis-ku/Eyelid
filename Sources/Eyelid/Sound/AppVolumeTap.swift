import AudioToolbox
import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AppVolume")

/// Plays one app at its own volume. A Core Audio tap takes the app's sound, which macOS then keeps from the output
/// while Eyelid reads it, and Eyelid plays it to the output itself, quieter.
///
/// macOS mutes the app only while the tap is read, so if Eyelid quits or stops, the app is heard as before.
@available(macOS 14.2, *)
final class AppVolumeTap: @unchecked Sendable {
    /// The app's processes with sound, which the tap mixes.
    let processes: [AudioObjectID]
    /// The output the sound goes to.
    let outputUID: String

    /// The gain, from 0 to 1: the volume, less the equalizer's headroom. Set from the main thread and read on Core
    /// Audio's.
    private let gain: OSAllocatedUnfairLock<Float>
    /// Only touched on the main thread, to work out `gain`.
    private var volume: Float
    private var headroom: Float
    /// The app's equalizer, once the aggregate's sample rate is known.
    private var equalizer: EqualizerFilter?
    private var equalizerSettings: EqualizerSettings
    /// The gain the last buffer ended at. A change ramps across one buffer, rather than click. Only touched on Core
    /// Audio's IO thread.
    private var appliedGain: Float
    /// The output device's own input channels, which come before the tap's in the aggregate's input.
    private var deviceInputChannels = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Starts playing the app at `gain`, through `equalizer`, or returns nil if Core Audio refuses.
    init?(
        processes: [AudioObjectID],
        output: AudioDeviceID,
        outputUID: String,
        gain: Float,
        equalizer: EqualizerSettings = .flat
    ) {
        self.processes = processes
        self.outputUID = outputUID
        volume = gain
        headroom = equalizer.headroom
        equalizerSettings = equalizer
        let effective = gain * equalizer.headroom
        self.gain = OSAllocatedUnfairLock(initialState: effective)
        appliedGain = effective
        guard start(output: output) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    func setGain(_ value: Float) {
        volume = min(max(value, 0), 1)
        let effective = volume * headroom
        gain.withLock { $0 = effective }
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        equalizerSettings = settings
        headroom = settings.headroom
        equalizer?.setGains(settings.gains)
        setGain(volume)
    }

    private func start(output: AudioDeviceID) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Eyelid app volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            logger.error("Could not create the tap: \(status, privacy: .public)")
            return false
        }

        deviceInputChannels = Self.channelCount(of: output, scope: kAudioObjectPropertyScopeInput)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eyelid app volume",
            kAudioAggregateDeviceUIDKey: OutputDevice.ownDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // The output keeps time, and the tap follows it.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            logger.error("Could not create the aggregate device: \(status, privacy: .public)")
            return false
        }
        let sampleRate: Float64 = AudioProperty.value(
            AudioProperty.address(kAudioDevicePropertyNominalSampleRate),
            of: aggregateID
        ) ?? 48_000
        equalizer = EqualizerFilter(sampleRate: sampleRate, gains: equalizerSettings.gains)

        // No dispatch queue: the block runs on Core Audio's real-time IO thread, as playback must. Through a queue the
        // output came late whenever the main thread was busy, such as redrawing the slider, and the sound stuttered.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, output, _ in
            self?.render(input, into: output)
        }
        guard status == noErr else {
            logger.error("Could not create the IO proc: \(status, privacy: .public)")
            return false
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            logger.error("Could not start: \(status, privacy: .public)")
            return false
        }
        return true
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
    }

    /// Copies the app's sound to the output at the gain. Runs on Core Audio's IO thread.
    private func render(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>) {
        let target = gain.withLockUnchecked { $0 }
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        AppVolumeMixer.render(
            UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
            skippingChannels: deviceInputChannels,
            into: outputs,
            from: appliedGain,
            to: target
        )
        appliedGain = target
        if let equalizer {
            equalizer.update()
            let frames = AppVolumeMixer.frameCount(outputs)
            for channel in 0..<min(EqualizerFilter.channels, AppVolumeMixer.channelCount(outputs)) {
                guard let (samples, stride) = AppVolumeMixer.channel(channel, of: outputs) else { continue }
                equalizer.process(samples, stride: stride, frames: frames, channel: channel)
            }
        }
    }

    private static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The arithmetic of playing an app's sound at a gain, apart from Core Audio, so it can be tested.
enum AppVolumeMixer {
    /// Writes the input's channels, after the first `skippingChannels`, to the output's at a gain that moves from
    /// `start` to `end` across the buffer. Stereo goes to the first two output channels, and to a mono output as one;
    /// other channels are silent. Allocates nothing, since it runs on Core Audio's real-time thread.
    static func render(
        _ input: UnsafeMutableAudioBufferListPointer,
        skippingChannels skip: Int,
        into output: UnsafeMutableAudioBufferListPointer,
        from start: Float,
        to end: Float
    ) {
        for buffer in output {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        let inputChannels = channelCount(input) - skip
        let outputChannels = channelCount(output)
        guard inputChannels > 0, outputChannels > 0 else { return }

        let frames = min(frameCount(input), frameCount(output))
        guard frames > 0 else { return }
        let step = (end - start) / Float(frames)

        for outputChannel in 0..<outputChannels {
            guard let (destination, destinationStride) = channel(outputChannel, of: output) else { continue }
            if outputChannels == 1, inputChannels >= 2 {
                guard let (left, leftStride) = channel(skip, of: input),
                      let (right, rightStride) = channel(skip + 1, of: input)
                else { continue }
                for frame in 0..<frames {
                    let gain = start + step * Float(frame)
                    destination[frame * destinationStride] =
                        (left[frame * leftStride] + right[frame * rightStride]) * 0.5 * gain
                }
            } else if outputChannel < inputChannels,
                      let (source, sourceStride) = channel(skip + outputChannel, of: input) {
                for frame in 0..<frames {
                    destination[frame * destinationStride] = source[frame * sourceStride] * (start + step * Float(frame))
                }
            }
        }
    }

    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int(max($1.mNumberChannels, 1)) }
    }

    /// Frames in the list: the fewest any buffer holds.
    static func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var frames = Int.max
        for buffer in list {
            let channels = Int(max(buffer.mNumberChannels, 1))
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        }
        return frames == .max ? 0 : frames
    }

    /// The first sample of a channel, counting across buffers, and the step to the next frame's.
    static func channel(
        _ index: Int,
        of list: UnsafeMutableAudioBufferListPointer
    ) -> (UnsafeMutablePointer<Float>, Int)? {
        var first = 0
        for buffer in list {
            let channels = Int(max(buffer.mNumberChannels, 1))
            if index < first + channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                return (data + (index - first), channels)
            }
            first += channels
        }
        return nil
    }
}
