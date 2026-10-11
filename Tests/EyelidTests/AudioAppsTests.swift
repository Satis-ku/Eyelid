import Foundation
import Testing
@testable import Eyelid

@Suite("Apps playing")
struct AudioAppsTests {
    /// Yandex Music plays through its helper, Chrome through two, and Siri's speech service has no app.
    private let owners: [pid_t: pid_t] = [11: 10, 21: 20, 22: 20, 30: 30]
    private let names: [pid_t: String] = [10: "Yandex Music", 20: "Google Chrome", 40: "Arc"]

    private func apps(_ processes: [pid_t]) -> [AudioApp] {
        AudioApps.apps(playing: processes, responsible: { owners[$0] ?? -1 }) { pid in
            names[pid].map { AudioApp(id: pid, name: $0, bundleURL: nil, icon: nil) }
        }
    }

    @Test func helpersCountAsTheirApp() {
        #expect(apps([11]).map(\.name) == ["Yandex Music"])
    }

    @Test func eachAppOnceByName() {
        #expect(apps([21, 11, 22]).map(\.name) == ["Google Chrome", "Yandex Music"])
    }

    @Test func servicesWithoutAnAppAreLeftOut() {
        #expect(apps([30]).isEmpty)
    }

    /// When macOS can't tell who's responsible, the process stands for itself.
    @Test func unknownOwnerStandsForItself() {
        #expect(apps([40]).map(\.name) == ["Arc"])
    }
}
