import Accelerate
import Foundation
import os

/// An app's equalizer: a gain for each of ten bands, an octave apart, like Apple Music's.
struct EqualizerSettings: Codable, Equatable, Sendable {
    /// The middle of each band, in hertz.
    static let bands: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// How far a band goes up or down, in decibels.
    static let range: ClosedRange<Float> = -12...12

    static let flat = EqualizerSettings(gains: Array(repeating: 0, count: bands.count))

    /// One gain a band, in decibels.
    var gains: [Float]
    /// The preset these gains came from, until a band is moved on its own.
    var preset: EqualizerPreset?

    init(gains: [Float], preset: EqualizerPreset? = nil) {
        self.gains = gains.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) }
        self.preset = preset
    }

    init(_ preset: EqualizerPreset) {
        self.init(gains: preset.gains, preset: preset)
    }

    private enum CodingKeys: String, CodingKey {
        case gains
        case preset
    }

    /// Reads what an earlier or later build stored as well as it can: a band each, within the range, and no preset
    /// for one this build doesn't know.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? container.decode([Float].self, forKey: .gains)) ?? []
        let gains = (0..<Self.bands.count).map { stored.indices.contains($0) ? stored[$0] : 0 }
        let preset = try? container.decodeIfPresent(EqualizerPreset.self, forKey: .preset)
        self.init(gains: gains, preset: gains == preset?.gains ? preset : nil)
    }

    var isFlat: Bool {
        gains.allSatisfy { $0 == 0 }
    }

    /// What the whole signal is turned down by, so a band turned up doesn't push the sound past full scale and
    /// clip: as much as the highest band is up.
    var headroom: Float {
        let boost = gains.max() ?? 0
        return boost > 0 ? pow(10, -boost / 20) : 1
    }
}

/// Eyelid's own presets: simple curves for common needs, not copies of any other app's.
enum EqualizerPreset: String, Codable, CaseIterable, Sendable {
    case flat
    case bassBoost
    case bassReduce
    case trebleBoost
    case vocal
    case speech
    case loudness
    case rock

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .bassReduce: "Bass Reduce"
        case .trebleBoost: "Treble Boost"
        case .vocal: "Vocal"
        case .speech: "Speech"
        case .loudness: "Loudness"
        case .rock: "Rock"
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .bassReduce: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        // Voices sit between about 300 Hz and 4 kHz: those come forward, the lows step back.
        case .vocal: [-3, -2, -1, 0, 2, 3, 4, 3, 1, 0]
        // Podcasts and calls: the rumble below a voice goes, and its consonants come forward.
        case .speech: [-8, -6, -3, 0, 2, 4, 4, 2, 0, -2]
        // Quiet listening: the ear hears the lows and highs less at low volume.
        case .loudness: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        case .rock: [4, 3, 2, 1, -1, -1, 1, 2, 3, 4]
        }
    }
}

/// Biquad filter coefficients, from the Audio EQ Cookbook (Robert Bristow-Johnson, as published by the W3C:
/// https://www.w3.org/TR/audio-eq-cookbook/).
enum Biquad {
    /// A peaking filter: `gain` decibels at `frequency`, falling off over a width set by `q`. Returns b0, b1, b2, a1
    /// and a2, normalized so a0 is 1, for `y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`.
    static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosine = cos(w0)
        let a0 = 1 + alpha / a
        return [
            (1 + alpha * a) / a0,
            (-2 * cosine) / a0,
            (1 - alpha * a) / a0,
            (-2 * cosine) / a0,
            (1 - alpha / a) / a0,
        ]
    }

    /// An octave-wide band's Q.
    static let octaveQ = 1.41

    /// The coefficients of every band, one after another, as `vDSP_biquad_CreateSetup` takes them.
    static func equalizer(_ gains: [Float], sampleRate: Double) -> [Double] {
        zip(EqualizerSettings.bands, gains).flatMap { frequency, gain -> [Double] in
            // A band above what the sample rate can hold is left as it is.
            guard frequency < sampleRate * 0.45 else { return [1, 0, 0, 0, 0] }
            return peaking(frequency: frequency, gain: Double(gain), q: octaveQ, sampleRate: sampleRate)
        }
    }
}

/// Runs the bands over the sound on Core Audio's real-time thread. The gains are set from the main thread and taken
/// up at the next buffer; nothing is allocated or waited on while the sound plays.
final class EqualizerFilter: @unchecked Sendable {
    /// Channels it filters: stereo.
    static let channels = 2
    /// The most frames a buffer has. Core Audio's buffers are far shorter.
    static let maxFrames = 8_192

    /// Only touched on the main thread, to work out coefficients.
    private var sampleRate: Double
    private var gains: [Float]
    private let sections = vDSP_Length(EqualizerSettings.bands.count)
    private let setup: vDSP_biquad_Setup
    /// Each channel's filter state: 2 values a section and 2 more.
    private let delays: [UnsafeMutablePointer<Float>]
    private let scratch: UnsafeMutablePointer<Float>
    private let coefficients: UnsafeMutablePointer<Double>
    /// New gains waiting for the IO thread, set from the main thread. The IO thread only copies them out: the array
    /// stays here, so it's never released, or freed, on that thread.
    private struct Pending {
        var coefficients: [Double]
        /// Whether any band is off 0 dB. A 0 dB band's coefficients aren't zeros, so this comes from the gains.
        var isActive: Bool
        var isNew = false
    }
    private let pending: OSAllocatedUnfairLock<Pending>
    /// Only touched on the IO thread.
    private var isActive = false

    init?(sampleRate: Double, gains: [Float]) {
        self.sampleRate = sampleRate
        self.gains = gains
        let initial = Biquad.equalizer(gains, sampleRate: sampleRate)
        let count = vDSP_Length(EqualizerSettings.bands.count)
        guard let setup = initial.withUnsafeBufferPointer({ vDSP_biquad_CreateSetup($0.baseAddress!, count) }) else {
            return nil
        }
        self.setup = setup
        let delayLength = 2 * Int(count) + 2
        delays = (0..<Self.channels).map { _ in
            let delay = UnsafeMutablePointer<Float>.allocate(capacity: delayLength)
            delay.initialize(repeating: 0, count: delayLength)
            return delay
        }
        scratch = .allocate(capacity: Self.maxFrames)
        coefficients = .allocate(capacity: initial.count)
        coefficients.initialize(from: initial, count: initial.count)
        let active = !gains.allSatisfy { $0 == 0 }
        isActive = active
        pending = OSAllocatedUnfairLock(initialState: Pending(coefficients: initial, isActive: active))
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
        delays.forEach { $0.deallocate() }
        scratch.deallocate()
        coefficients.deallocate()
    }

    /// Takes new gains, from the main thread.
    func setGains(_ gains: [Float]) {
        self.gains = gains
        let new = Pending(
            coefficients: Biquad.equalizer(gains, sampleRate: sampleRate),
            isActive: !gains.allSatisfy { $0 == 0 },
            isNew: true
        )
        // The array this replaces is released here, on the main thread.
        pending.withLock { $0 = new }
    }

    /// Works the bands out again for the output's new sample rate, from the main thread, so they stay where they are.
    func setSampleRate(_ rate: Double) {
        guard rate != sampleRate, rate > 0 else { return }
        sampleRate = rate
        setGains(gains)
    }

    /// Takes up new gains, if any came, before a buffer. On the IO thread; if the main thread holds the lock, the gains
    /// wait for the next buffer rather than the sound for the lock.
    func update() {
        let wasActive = isActive
        let coefficients = coefficients
        let active = pending.withLockIfAvailableUnchecked { pending -> Bool? in
            guard pending.isNew else { return nil }
            pending.isNew = false
            pending.coefficients.withUnsafeBufferPointer { new in
                coefficients.update(from: new.baseAddress!, count: new.count)
            }
            return pending.isActive
        } ?? nil
        guard let active else { return }
        isActive = active
        vDSP_biquad_SetCoefficientsDouble(setup, coefficients, 0, sections)
        if isActive, !wasActive {
            // Old state from before a pause in filtering would pop.
            for delay in delays {
                delay.update(repeating: 0, count: 2 * Int(sections) + 2)
            }
        }
    }

    /// Filters one channel in place: `frames` samples, `stride` apart.
    func process(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
        guard isActive, channel < Self.channels, frames <= Self.maxFrames else { return }
        vDSP_biquad(setup, delays[channel], samples, vDSP_Stride(stride), scratch, 1, vDSP_Length(frames))
        for frame in 0..<frames {
            samples[frame * stride] = scratch[frame]
        }
    }
}
