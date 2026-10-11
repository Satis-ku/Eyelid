import Accelerate
import Foundation
import Testing
@testable import Eyelid

@Suite("Equalizer")
struct EqualizerTests {
    /// The header doesn't say how vDSP orders a section's coefficients, so this pins it: b0, b1, b2, a1, a2, with the
    /// a terms subtracted, as the Audio EQ Cookbook writes the difference equation.
    @Test func vDSPRunsTheCookbooksDifferenceEquation() throws {
        let c = Biquad.peaking(frequency: 1_000, gain: 6, q: 1.41, sampleRate: 48_000)
        let setup = try #require(vDSP_biquad_CreateSetup(c, 1))
        defer { vDSP_biquad_DestroySetup(setup) }
        let input: [Float] = (0..<64).map { Float(sin(Double($0) * 0.7) + ($0 == 3 ? 1 : 0)) }
        var delay = [Float](repeating: 0, count: 4)
        var output = [Float](repeating: 0, count: input.count)
        vDSP_biquad(setup, &delay, input, 1, &output, 1, vDSP_Length(input.count))

        var expected: [Double] = []
        for n in input.indices {
            let x = { (k: Int) in k >= 0 ? Double(input[k]) : 0 }
            let y = { (k: Int) in k >= 0 ? expected[k] : 0 }
            expected.append(c[0] * x(n) + c[1] * x(n - 1) + c[2] * x(n - 2) - c[3] * y(n - 1) - c[4] * y(n - 2))
        }

        for (actual, wanted) in zip(output, expected) {
            #expect(abs(Double(actual) - wanted) < 1e-4)
        }
    }

    /// The level of a sine after the filter, in decibels against before.
    private func gain(at frequency: Double, gains: [Float], sampleRate: Double = 48_000) throws -> Double {
        gain(at: frequency, through: try #require(EqualizerFilter(sampleRate: sampleRate, gains: gains)), sampleRate: sampleRate)
    }

    private func gain(at frequency: Double, through filter: EqualizerFilter, sampleRate: Double) -> Double {
        let frames = 4_096
        var samples = (0..<frames).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
        // Several buffers, so the filter settles.
        for _ in 0..<4 {
            var buffer = (0..<frames).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
            filter.process(&buffer, stride: 1, frames: frames, channel: 0)
            samples = buffer
        }
        let peak = samples[(frames / 2)...].map(abs).max() ?? 0
        return 20 * log10(Double(peak))
    }

    @Test func aBandTurnsItsFrequencyUpByItsGain() throws {
        var gains = EqualizerSettings.flat.gains
        gains[5] = 6

        #expect(abs(try gain(at: 1_000, gains: gains) - 6) < 0.3)
        #expect(abs(try gain(at: 31, gains: gains)) < 0.3)
    }

    @Test func flatLeavesTheSoundAsItIs() throws {
        #expect(abs(try gain(at: 440, gains: EqualizerSettings.flat.gains)) < 0.01)
    }

    /// A 0 dB band's coefficients aren't zeros, so whether to filter comes from the gains.
    @Test func flatGainsSetLaterStopFiltering() throws {
        let filter = try #require(EqualizerFilter(sampleRate: 48_000, gains: EqualizerPreset.rock.gains))
        filter.setGains(EqualizerSettings.flat.gains)
        filter.update()
        var samples = (0..<512).map { Float(sin(Double($0) * 0.3)) }
        let original = samples

        filter.process(&samples, stride: 1, frames: samples.count, channel: 0)

        #expect(samples == original)
    }

    @Test func gainsSetLaterAreTakenUp() throws {
        let filter = try #require(EqualizerFilter(sampleRate: 48_000, gains: EqualizerSettings.flat.gains))
        var gains = EqualizerSettings.flat.gains
        gains[5] = 6
        filter.setGains(gains)
        filter.update()
        var samples = (0..<512).map { Float(sin(2 * .pi * 1_000 * Double($0) / 48_000)) }
        let original = samples

        filter.process(&samples, stride: 1, frames: samples.count, channel: 0)

        #expect(samples != original)
    }

    /// AirPods drop their sample rate for a call: the bands stay at their frequencies.
    @Test func aNewSampleRateKeepsTheBandsWhereTheyAre() throws {
        var gains = EqualizerSettings.flat.gains
        gains[5] = 6
        let filter = try #require(EqualizerFilter(sampleRate: 48_000, gains: gains))

        filter.setSampleRate(24_000)
        filter.update()

        #expect(abs(gain(at: 1_000, through: filter, sampleRate: 24_000) - 6) < 0.3)
    }

    @Test func bandsAboveWhatTheRateHoldsAreLeftAlone() {
        let coefficients = Biquad.equalizer(EqualizerPreset.trebleBoost.gains, sampleRate: 22_050)

        #expect(Array(coefficients.suffix(5)) == [1, 0, 0, 0, 0])
    }

    @Test func boostsGetHeadroomSoNothingClips() {
        let settings = EqualizerSettings(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, -3])

        #expect(abs(20 * log10(settings.headroom) + 6) < 0.001)
        #expect(EqualizerSettings(gains: [-3, 0, 0, 0, 0, 0, 0, 0, 0, 0]).headroom == 1)
    }

    @Test func gainsStayInRange() {
        let settings = EqualizerSettings(gains: [20, -20, 0, 0, 0, 0, 0, 0, 0, 0])

        #expect(settings.gains[0] == 12)
        #expect(settings.gains[1] == -12)
    }

    @Test(arguments: EqualizerPreset.allCases)
    func presetsHaveEveryBandInRange(_ preset: EqualizerPreset) {
        #expect(preset.gains.count == EqualizerSettings.bands.count)
        #expect(preset.gains.allSatisfy(EqualizerSettings.range.contains))
    }

    @Test func storedSettingsComeBackAsTheyWere() throws {
        let settings = EqualizerSettings(.vocal)
        let data = try JSONEncoder().encode(settings)

        #expect(try JSONDecoder().decode(EqualizerSettings.self, from: data) == settings)
    }

    /// Another build may store other bands or presets: what fits is kept, and nothing is lost to what doesn't.
    @Test func storedSettingsFromAnotherBuildAreMadeToFit() throws {
        let json = #"{"gains": [20, 3, 3], "preset": "someFuturePreset"}"#

        let settings = try JSONDecoder().decode(EqualizerSettings.self, from: Data(json.utf8))

        #expect(settings.gains == [12, 3, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(settings.preset == nil)
    }
}
