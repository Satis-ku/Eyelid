import CoreAudio
import Foundation
import Testing
@testable import Eyelid

/// Buffers of Float samples, laid out as Core Audio hands them over.
private final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// One buffer for each entry, with that many interleaved channels, `frames` long, filled by `sample(channel,
    /// frame)` counting channels across buffers.
    init(channels: [Int], frames: Int, sample: (Int, Int) -> Float = { _, _ in 9 }) {
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var first = 0
        for (index, count) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: count * frames)
            for frame in 0..<frames {
                for channel in 0..<count {
                    data[frame * count + channel] = sample(first + channel, frame)
                }
            }
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(count),
                mDataByteSize: UInt32(count * frames * MemoryLayout<Float>.size),
                mData: data
            )
            first += count
        }
    }

    /// Every frame of a channel, counting across buffers.
    func samples(_ channel: Int) -> [Float] {
        var first = 0
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            if channel < first + count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / count
                return (0..<frames).map { data[$0 * count + channel - first] }
            }
            first += count
        }
        return []
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

@Suite("Playing an app at its own volume")
struct AppVolumeMixerTests {
    @Test func stereoGoesToTheOutputAtTheGain() {
        let input = Buffers(channels: [2], frames: 4) { channel, frame in Float(frame + 1) * (channel == 0 ? 1 : -1) }
        let output = Buffers(channels: [1, 1], frames: 4)

        AppVolumeMixer.render(input.list, skippingChannels: 0, into: output.list, from: 0.5, to: 0.5)

        #expect(output.samples(0) == [0.5, 1, 1.5, 2])
        #expect(output.samples(1) == [-0.5, -1, -1.5, -2])
    }

    /// An output with a microphone, such as a headset, puts its own input before the tap's.
    @Test func theOutputsOwnInputIsSkipped() {
        let input = Buffers(channels: [1, 2], frames: 2) { channel, _ in channel == 0 ? 100 : Float(channel) }
        let output = Buffers(channels: [2], frames: 2)

        AppVolumeMixer.render(input.list, skippingChannels: 1, into: output.list, from: 1, to: 1)

        #expect(output.samples(0) == [1, 1])
        #expect(output.samples(1) == [2, 2])
    }

    @Test func aMonoOutputGetsBothChannels() {
        let input = Buffers(channels: [2], frames: 2) { channel, _ in channel == 0 ? 0.2 : 0.6 }
        let output = Buffers(channels: [1], frames: 2)

        AppVolumeMixer.render(input.list, skippingChannels: 0, into: output.list, from: 1, to: 1)

        #expect(output.samples(0).allSatisfy { abs($0 - 0.4) < 0.0001 })
    }

    /// A new volume ramps across the buffer rather than click.
    @Test func aChangeRamps() {
        let input = Buffers(channels: [2], frames: 4) { _, _ in 1 }
        let output = Buffers(channels: [2], frames: 4)

        AppVolumeMixer.render(input.list, skippingChannels: 0, into: output.list, from: 0, to: 1)

        #expect(output.samples(0) == [0, 0.25, 0.5, 0.75])
    }

    /// A headset's microphone is left out of the aggregate's input, and Core Audio hands its buffer over empty.
    @Test func anInputLeftOutDoesntCutTheSound() {
        let input = Buffers(channels: [1, 2], frames: 2) { channel, _ in Float(channel) }
        input.list[0].mData = nil
        input.list[0].mDataByteSize = 0
        let output = Buffers(channels: [2], frames: 2)

        AppVolumeMixer.render(input.list, skippingChannels: 1, into: output.list, from: 1, to: 1)

        #expect(output.samples(0) == [1, 1])
        #expect(output.samples(1) == [2, 2])
    }

    @Test func soundIsToldFromSilenceAfterTheOutputsOwnInput() {
        let silent = Buffers(channels: [1, 2], frames: 3) { channel, _ in channel == 0 ? 1 : 0 }
        let playing = Buffers(channels: [1, 2], frames: 3) { channel, frame in channel == 2 && frame == 2 ? 0.1 : 0 }

        #expect(!AppVolumeMixer.hasSound(silent.list, skippingChannels: 1))
        #expect(AppVolumeMixer.hasSound(playing.list, skippingChannels: 1))
    }

    @Test func extraOutputChannelsAreSilent() {
        let input = Buffers(channels: [2], frames: 2) { _, _ in 1 }
        let output = Buffers(channels: [4], frames: 2)

        AppVolumeMixer.render(input.list, skippingChannels: 0, into: output.list, from: 1, to: 1)

        #expect(output.samples(2) == [0, 0])
        #expect(output.samples(3) == [0, 0])
    }
}

@MainActor
@Suite("Volumes of apps")
struct AppVolumesTests {
    final class FakeTap: AppVolumeTapping {
        let processes: [AudioObjectID]
        let outputUID: String
        var gain: Float
        var equalizer: EqualizerSettings
        var isRunning: Bool
        var isStopped = false
        var silence: Duration?
        var isDenied = false
        var timesAsked = 0

        init(_ request: AppVolumes.Request) {
            processes = request.processes
            outputUID = request.outputUID
            gain = request.gain
            equalizer = request.equalizer
            isRunning = request.isRunning
        }

        func setRunning(_ running: Bool) {
            isRunning = running
        }

        func isHearingDenied() -> Bool {
            timesAsked += 1
            return isDenied
        }

        func setGain(_ value: Float) {
            gain = value
        }

        func setEqualizer(_ settings: EqualizerSettings) {
            equalizer = settings
        }

        func stop() {
            isStopped = true
        }
    }

    final class World {
        var apps: [AudioApp] = []
        var output: (AudioDeviceID, String)? = (1, "speakers")
        var made: [FakeTap] = []
        var now = ContinuousClock.now
    }

    private let store = InMemorySettingsStore()
    private let world = World()

    private func makeVolumes() -> AppVolumes {
        let world = world
        return AppVolumes(
            defaults: store,
            apps: { world.apps },
            output: { world.output },
            makeTap: { request in
                let tap = FakeTap(request)
                world.made.append(tap)
                return tap
            },
            now: { world.now },
            checkInterval: .milliseconds(10)
        )
    }

    private func app(_ name: String, processes: [AudioObjectID], isPlaying: Bool = false) -> AudioApp {
        AudioApp(
            id: 1,
            name: name,
            bundleIdentifier: "com.example.\(name)",
            bundleURL: nil,
            icon: nil,
            processes: processes,
            isPlaying: isPlaying
        )
    }

    @Test func aQuieterAppPlaysThroughATap() throws {
        let volumes = makeVolumes()
        let music = app("Music", processes: [10, 11])
        world.apps = [music]

        volumes.setVolume(0.4, for: music)

        let tap = try #require(world.made.first)
        #expect(tap.processes == [10, 11])
        #expect(tap.outputUID == "speakers")
        #expect(tap.gain == 0.4)
        #expect(volumes.volume(for: music) == 0.4)
    }

    /// Switching paths leaves a gap, so a playing app back at full volume keeps its tap until it's quiet.
    @Test func backAtFullVolumeTheTapLingersWhileTheAppPlays() async throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.setVolume(0.4, for: world.apps[0])
        let tap = try #require(world.made.first)

        volumes.setVolume(1, for: world.apps[0])
        volumes.sync()
        #expect(!tap.isStopped)
        #expect(tap.gain == 1)

        world.apps = [app("Music", processes: [10], isPlaying: false)]
        await volumes.checkTask?.value

        #expect(tap.isStopped)
        #expect(volumes.taps.isEmpty)
        #expect(volumes.checkTask == nil)
    }

    // MARK: - Every app playing through Eyelid

    @Test func whileRoutingEveryAppPlayingHasATapAtFullVolume() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true), app("Chat", processes: [20])]

        volumes.routesPlayingApps = true

        #expect(world.made.count == 1)
        let tap = try #require(world.made.first)
        #expect(tap.processes == [10])
        #expect(tap.gain == 1)
    }

    /// The point of routing: turning a playing app down changes its gain, with no new tap.
    @Test func whileRoutingAVolumeChangeOnlyChangesTheGain() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.routesPlayingApps = true
        let tap = try #require(world.made.first)

        volumes.setVolume(0.3, for: world.apps[0])
        #expect(tap.gain == 0.3)
        volumes.setVolume(1, for: world.apps[0])
        volumes.sync()

        #expect(world.made.count == 1)
        #expect(tap.gain == 1)
        #expect(!tap.isStopped)
    }

    @Test func whileRoutingAQuietAppKeepsItsTapForAWhile() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.routesPlayingApps = true
        let tap = try #require(world.made.first)

        world.apps = [app("Music", processes: [10], isPlaying: false)]
        world.now += .seconds(60)
        volumes.sync()
        #expect(!tap.isStopped)

        world.now += volumes.quietGrace
        volumes.sync()
        #expect(tap.isStopped)
    }

    /// Hiding the live activity turns routing off to stop listening, so playing apps don't keep their taps.
    @Test func turningRoutingOffStopsTapsAtOnceEvenWhilePlaying() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.routesPlayingApps = true
        let tap = try #require(world.made.first)

        volumes.routesPlayingApps = false

        #expect(tap.isStopped)
        #expect(volumes.taps.isEmpty)
    }

    @Test func turningRoutingOffLeavesOnlyAppsTurnedDown() {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true), app("Video", processes: [20], isPlaying: true)]
        volumes.routesPlayingApps = true
        volumes.setVolume(0.5, for: world.apps[1])
        world.apps = [app("Music", processes: [10]), app("Video", processes: [20])]

        volumes.routesPlayingApps = false

        #expect(world.made.filter { !$0.isStopped }.map(\.processes) == [[20]])
    }

    @Test func backAtFullVolumeTheTapGoesOnceLetGo() throws {
        let volumes = makeVolumes()
        let music = app("Music", processes: [10])
        world.apps = [music]
        volumes.setVolume(0.4, for: music)
        let tap = try #require(world.made.first)

        volumes.setVolume(1, for: music)
        #expect(tap.gain == 1)
        #expect(!tap.isStopped)

        volumes.sync()
        #expect(tap.isStopped)
        #expect(volumes.taps.isEmpty)
    }

    @Test func aNewOutputOrHelperGetsANewTap() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10])]
        volumes.setVolume(0.5, for: world.apps[0])

        let first = try #require(world.made.first)

        world.output = (2, "airpods")
        volumes.sync()
        try #require(world.made.count == 2)
        #expect(first.isStopped)
        #expect(world.made[1].outputUID == "airpods")

        world.apps = [app("Music", processes: [10, 12])]
        volumes.sync()
        try #require(world.made.count == 3)
        #expect(world.made[2].processes == [10, 12])
        #expect(world.made[2].gain == 0.5)
    }

    @Test func volumesAreKeptAndTapsStartWhenTheAppDoes() throws {
        let music = app("Music", processes: [10])
        let first = makeVolumes()
        first.setVolume(0.3, for: music)
        #expect(world.made.isEmpty)

        let relaunched = makeVolumes()
        world.apps = [music]
        relaunched.sync()

        #expect(relaunched.volume(for: music) == 0.3)
        #expect(world.made.first?.gain == 0.3)
    }

    @Test func withoutAnOutputNothingIsTapped() {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10])]
        world.output = nil

        volumes.setVolume(0.5, for: world.apps[0])

        #expect(world.made.isEmpty)
    }

    // MARK: - Equalizers

    @Test func anEqualizerPlaysTheAppThroughATap() throws {
        let volumes = makeVolumes()
        let music = app("Music", processes: [10])
        world.apps = [music]

        volumes.setEqualizer(EqualizerSettings(.bassBoost), for: music)

        let tap = try #require(world.made.first)
        #expect(tap.equalizer == EqualizerSettings(.bassBoost))
        #expect(tap.gain == 1)
    }

    @Test func aFlatEqualizerIsForgotten() throws {
        let volumes = makeVolumes()
        let music = app("Music", processes: [10])
        world.apps = [music]
        volumes.setEqualizer(EqualizerSettings(.rock), for: music)
        let tap = try #require(world.made.first)

        volumes.setEqualizer(.flat, for: music)
        #expect(tap.equalizer == .flat)
        #expect(volumes.equalizers.isEmpty)
        #expect(makeVolumes().equalizer(for: music) == .flat)

        volumes.sync()
        #expect(tap.isStopped)
    }

    @Test func equalizersAreKept() {
        let music = app("Music", processes: [10])
        makeVolumes().setEqualizer(EqualizerSettings(.vocal), for: music)

        #expect(makeVolumes().equalizer(for: music) == EqualizerSettings(.vocal))
    }

    @Test func changingTheEqualizerOfATappedAppKeepsItsTap() throws {
        let volumes = makeVolumes()
        let music = app("Music", processes: [10], isPlaying: true)
        world.apps = [music]
        volumes.setVolume(0.5, for: music)
        let tap = try #require(world.made.first)

        volumes.setEqualizer(EqualizerSettings(.rock), for: music)

        #expect(world.made.count == 1)
        #expect(tap.equalizer == EqualizerSettings(.rock))
    }

    // MARK: - Letting the output sleep

    @Test func aTapForAnAppNotHeardYetOnlyKeepsItMuted() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10])]

        volumes.setVolume(0.5, for: world.apps[0])

        let tap = try #require(world.made.first)
        #expect(!tap.isRunning)
    }

    /// A quiet app keeps its tap, so its next sound is caught, but the tap stops playing it once a pause is long.
    @Test func aQuietAppsTapStopsPlayingItAfterAWhile() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.setVolume(0.5, for: world.apps[0])
        let tap = try #require(world.made.first)
        #expect(tap.isRunning)

        world.apps = [app("Music", processes: [10])]
        world.now += volumes.quietGrace - .milliseconds(20)
        volumes.sync()
        #expect(tap.isRunning)
        // Looks again as the pause gets long.
        #expect(volumes.checkDelay == .milliseconds(20))

        world.now += .milliseconds(20)
        volumes.sync()
        #expect(!tap.isRunning)
        #expect(!tap.isStopped)

        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.sync()
        #expect(tap.isRunning)
        #expect(world.made.count == 1)
    }

    @Test func checksAreOftenWhilePlayingAndRareOtherwise() {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.setVolume(0.5, for: world.apps[0])
        #expect(volumes.checkDelay == volumes.checkInterval)

        world.apps = [app("Music", processes: [10])]
        world.now += volumes.quietGrace
        volumes.sync()
        #expect(volumes.checkDelay == volumes.checkInterval * 5)
    }

    @Test func withNothingToDoNothingIsChecked() {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]

        volumes.sync()

        #expect(world.made.isEmpty)
        #expect(volumes.checkTask == nil)
    }

    // MARK: - Without the permission to hear apps

    /// Without the permission, a tap hears silence and keeps its app silent, so apps go back to playing on their own.
    @Test func whenMacOSWontLetEyelidHearAppsTheyPlayOnTheirOwn() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.setVolume(0.5, for: world.apps[0])
        let tap = try #require(world.made.first)
        tap.silence = AppVolumes.silenceTimeout
        tap.isDenied = true

        world.now += AppVolumes.silenceTimeout
        volumes.sync()

        #expect(volumes.isHearingDenied)
        #expect(tap.isStopped)
        #expect(volumes.taps.isEmpty)
        #expect(volumes.checkTask == nil)

        volumes.setVolume(0.4, for: world.apps[0])
        #expect(!volumes.isHearingDenied)
        #expect(world.made.count == 2)
    }

    /// An app may well play silence, so a silent tap only leads to asking, once.
    @Test func aSilentTapIsAskedAboutOnce() throws {
        let volumes = makeVolumes()
        world.apps = [app("Music", processes: [10], isPlaying: true)]
        volumes.setVolume(0.5, for: world.apps[0])
        let tap = try #require(world.made.first)
        tap.silence = AppVolumes.silenceTimeout

        volumes.sync()
        #expect(tap.timesAsked == 0)

        world.now += AppVolumes.silenceTimeout
        volumes.sync()
        volumes.sync()

        #expect(tap.timesAsked == 1)
        #expect(!volumes.isHearingDenied)
        #expect(!tap.isStopped)
    }
}
