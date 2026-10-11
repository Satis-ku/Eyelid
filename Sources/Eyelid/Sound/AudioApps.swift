import AppKit
import CoreAudio

/// The process macOS holds responsible for another: an app for its helpers, such as Yandex Music or Chrome for the
/// helper process that sends their sound. Private, but stable for years and widely used.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibilityGetPIDResponsibleForPID(_ pid: pid_t) -> pid_t

/// An app sending sound to an output right now.
struct AudioApp: Identifiable, Equatable {
    /// The app's process.
    let id: pid_t
    let name: String
    let bundleURL: URL?
    let icon: NSImage?

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

/// Which apps are sending sound right now, as Core Audio sees it (macOS 14.2 and later). No permission is needed: it
/// says which apps play, not what.
enum AudioApps {
    /// The apps playing, by name, with Eyelid and the system's own services left out. Empty before macOS 14.2.
    @MainActor
    static func playing() -> [AudioApp] {
        guard #available(macOS 14.2, *) else { return [] }
        let processes: [AudioObjectID] = AudioProperty.array(
            AudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID(kAudioObjectSystemObject)
        )
        let playing = processes.compactMap { process -> pid_t? in
            let running: UInt32 = AudioProperty.value(
                AudioProperty.address(kAudioProcessPropertyIsRunningOutput),
                of: process
            ) ?? 0
            guard running != 0 else { return nil }
            return AudioProperty.value(AudioProperty.address(kAudioProcessPropertyPID), of: process)
        }
        let own = ProcessInfo.processInfo.processIdentifier
        return apps(playing: playing, responsible: responsibilityGetPIDResponsibleForPID) { pid in
            // Apps only: daemons such as Siri's speech service have no app, and helpers have none of their own.
            guard pid != own,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy != .prohibited,
                  let name = app.localizedName
            else { return nil }
            return AudioApp(id: pid, name: name, bundleURL: app.bundleURL, icon: app.icon)
        }
    }

    /// The app behind each process playing, each once, by name. A process whose responsible one can't be told stands
    /// for itself.
    static func apps(
        playing processes: [pid_t],
        responsible: (pid_t) -> pid_t,
        app: (pid_t) -> AudioApp?
    ) -> [AudioApp] {
        var seen = Set<pid_t>()
        var apps: [AudioApp] = []
        for process in processes {
            let owner = responsible(process)
            let pid = owner > 0 ? owner : process
            guard seen.insert(pid).inserted, let found = app(pid) else { continue }
            apps.append(found)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
