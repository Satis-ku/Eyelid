import AudioToolbox
import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AppVolume")

/// Plays one app at its own volume. A Core Audio tap takes the app's sound, which macOS then keeps from the output,
/// and Eyelid plays it to the output itself, quieter.
///
/// The app stays muted for as long as the tap is there, even while Eyelid isn't playing it: then the first moment of
/// a sound after a quiet spell is lost rather than heard at full volume. While the app is quiet, Eyelid stops playing
/// it, so the output, and the Mac, can sleep. Taps go with Eyelid, so if it quits the app is heard as before.
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
    /// Whether any sound has come through yet, as Core Audio's IO thread found it. Without the permission to hear
    /// apps, macOS sends only silence.
    private let heard = OSAllocatedUnfairLock(initialState: Heard())
    private struct Heard {
        var anything = false
        /// Frames played before anything was heard.
        var silentFrames = 0
    }
    /// The IO thread's own: what it found that `heard` doesn't have yet, and whether it has all of it.
    private var soundToReport = false
    private var framesToReport = 0
    private var hasHeardAnything = false
    private var sampleRate: Double = 48_000

    /// Whether Eyelid is playing the app now.
    private(set) var isRunning = false

    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Takes the app's sound and, if `isRunning`, starts playing it at `gain`, through `equalizer`. Returns nil if
    /// Core Audio refuses.
    init?(
        processes: [AudioObjectID],
        output: AudioDeviceID,
        outputUID: String,
        gain: Float,
        equalizer: EqualizerSettings = .flat,
        isRunning: Bool = true
    ) {
        self.processes = processes
        self.outputUID = outputUID
        description = CATapDescription(stereoMixdownOfProcesses: processes)
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
        setRunning(isRunning)
        guard self.isRunning == isRunning else {
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

    /// Starts or stops playing the app. The tap stays, and keeps the app muted.
    func setRunning(_ running: Bool) {
        guard running != isRunning, aggregateID != kAudioObjectUnknown, let procID else { return }
        let status = running ? AudioDeviceStart(aggregateID, procID) : AudioDeviceStop(aggregateID, procID)
        guard status == noErr else {
            logger.error("Could not \(running ? "start" : "stop", privacy: .public): \(status, privacy: .public)")
            return
        }
        isRunning = running
    }

    /// How long the tap has played nothing but silence, from its start, or nil once it has heard anything.
    var silence: Duration? {
        let heard = heard.withLock { $0 }
        guard !heard.anything else { return nil }
        return .seconds(Double(heard.silentFrames) / sampleRate)
    }

    /// Whether macOS keeps the app's sound from Eyelid. There's no way to ask (Apple's answer in the developer forums:
    /// https://developer.apple.com/forums/thread/756783); developers there report that setting a tap's description
    /// fails with `kAudioDevicePermissionsError` without the permission, and that's what this tries.
    func isHearingDenied() -> Bool {
        var address = AudioProperty.address(kAudioTapPropertyDescription)
        var value = Unmanaged.passUnretained(description)
        let status = AudioObjectSetPropertyData(
            tapID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size),
            &value
        )
        return status == kAudioDevicePermissionsError
    }

    private func start(output: AudioDeviceID) -> Bool {
        description.uuid = UUID()
        description.name = "Eyelid app volume"
        description.isPrivate = true
        // Muted for as long as the tap is there, not only while it's read: see the type's comment.
        description.muteBehavior = .muted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            logger.error("Could not create the tap: \(status, privacy: .public)")
            return false
        }

        let deviceInput = Self.inputStreams(of: output)
        deviceInputChannels = deviceInput.channels
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
        sampleRate = AudioProperty.value(
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
        turnOffInputStreams(deviceInput.streams)
        return true
    }

    /// Leaves out the output's own input, such as a headset's microphone: its streams come first in the aggregate's
    /// input, and running them would turn the microphone on for nothing.
    private func turnOffInputStreams(_ count: Int) {
        guard count > 0, let procID else { return }
        var address = AudioProperty.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size
        else { return }
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { data.deallocate() }
        let usage = data.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        // Which proc's usage to read goes in first.
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, data) == noErr else { return }
        let streams = Int(usage.pointee.mNumberStreams)
        let isOn = data.advanced(by: MemoryLayout.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for stream in 0..<min(count, streams) {
            isOn[stream] = 0
        }
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, data)
        if status != noErr {
            logger.error("Could not leave out the output's input: \(status, privacy: .public)")
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                if isRunning {
                    AudioDeviceStop(aggregateID, procID)
                }
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        isRunning = false
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Copies the app's sound to the output at the gain. Runs on Core Audio's IO thread.
    private func render(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>) {
        // Without waiting: if the main thread is setting a new gain right now, it's taken up at the next buffer.
        let target = gain.withLockIfAvailable { $0 } ?? appliedGain
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        if !hasHeardAnything {
            soundToReport = soundToReport || AppVolumeMixer.hasSound(inputs, skippingChannels: deviceInputChannels)
            framesToReport += AppVolumeMixer.frameCount(inputs)
            // If the main thread is reading it right now, this buffer is told with the next.
            let sound = soundToReport
            let frames = framesToReport
            let told = heard.withLockIfAvailable { heard -> Bool in
                heard.anything = sound
                heard.silentFrames += frames
                return true
            }
            if told == true {
                hasHeardAnything = sound
                framesToReport = 0
            }
        }
        AppVolumeMixer.render(
            inputs,
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

    /// A device's input streams, and their channels.
    private static func inputStreams(of device: AudioDeviceID) -> (streams: Int, channels: Int) {
        var address = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return (0, 0) }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return (0, 0) }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return (buffers.count, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
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

    /// Whether any of the input's channels, after the first `skippingChannels`, isn't silent.
    static func hasSound(_ input: UnsafeMutableAudioBufferListPointer, skippingChannels skip: Int) -> Bool {
        let frames = frameCount(input)
        for index in skip..<max(skip, channelCount(input)) {
            guard let (samples, stride) = channel(index, of: input) else { continue }
            for frame in 0..<frames where samples[frame * stride] != 0 {
                return true
            }
        }
        return false
    }

    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int(max($1.mNumberChannels, 1)) }
    }

    /// Frames in the list: the fewest any buffer holds. Buffers of streams left out have no data, and don't count.
    static func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var frames = Int.max
        for buffer in list where buffer.mData != nil {
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
