import CoreAudio
import Foundation
import Testing
@testable import Eyelid

@Suite("Apps playing")
struct AudioAppsTests {
    /// Yandex Music plays through its helper, Chrome through two, and Siri's speech service has no app.
    private let owners: [pid_t: pid_t] = [11: 10, 21: 20, 22: 20, 30: 30]
    private let names: [pid_t: String] = [10: "Yandex Music", 20: "Google Chrome", 40: "Arc"]

    private func apps(_ playing: [pid_t], idle: [pid_t] = []) -> [AudioApp] {
        let processes = playing.map { AudioApps.AudioProcess(object: AudioObjectID($0 * 100), pid: $0, isPlaying: true) }
            + idle.map { AudioApps.AudioProcess(object: AudioObjectID($0 * 100), pid: $0, isPlaying: false) }
        return AudioApps.apps(processes, responsible: { owners[$0] ?? -1 }) { pid in
            names[pid].map { AudioApp(id: pid, name: $0, bundleIdentifier: nil, bundleURL: nil, icon: nil) }
        }
    }

    @Test func helpersCountAsTheirApp() {
        #expect(apps([11]).map(\.name) == ["Yandex Music"])
    }

    @Test func eachAppOnceByName() {
        #expect(apps([21, 11, 22]).map(\.name) == ["Google Chrome", "Yandex Music"])
    }

    /// A tap for an app's volume takes all its processes with sound, playing or not yet.
    @Test func anAppGathersItsProcesses() throws {
        let chrome = try #require(apps([21], idle: [22]).first)

        #expect(chrome.processes == [2_100, 2_200])
        #expect(chrome.isPlaying)
        #expect(apps([], idle: [22]).first?.isPlaying == false)
    }

    @Test func servicesWithoutAnAppAreLeftOut() {
        #expect(apps([30]).isEmpty)
    }

    /// When macOS can't tell who's responsible, the process stands for itself.
    @Test func unknownOwnerStandsForItself() {
        #expect(apps([40]).map(\.name) == ["Arc"])
    }

    /// Looking an app up takes a while, so a process without one is asked about once, however many it has.
    @Test func aProcessWithoutAnAppIsLookedUpOnce() {
        var lookups = 0
        let processes = [30, 30, 30].map { AudioApps.AudioProcess(object: AudioObjectID($0), pid: $0, isPlaying: true) }

        let found = AudioApps.apps(processes, responsible: { $0 }) { _ in
            lookups += 1
            return nil
        }

        #expect(found.isEmpty)
        #expect(lookups == 1)
    }

    @Test func namesSortAsFinderSortsThem() {
        let processes = [9, 10].map { AudioApps.AudioProcess(object: AudioObjectID($0), pid: $0, isPlaying: true) }

        let found = AudioApps.apps(processes, responsible: { $0 }) { pid in
            AudioApp(id: pid, name: "App \(pid == 9 ? 10 : 9)", bundleIdentifier: nil, bundleURL: nil, icon: nil)
        }

        #expect(found.map(\.name) == ["App 9", "App 10"])
    }
}
