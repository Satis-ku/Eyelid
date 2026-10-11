import AppKit
import CoreAudio

/// The process macOS holds responsible for another: an app for its helpers, such as Yandex Music or Chrome for the
/// helper process that sends their sound. Private, but stable for years and widely used.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibilityGetPIDResponsibleForPID(_ pid: pid_t) -> pid_t

/// An app with sound, and its processes that have it, such as its helpers.
struct AudioApp: Identifiable, Equatable {
    /// The app's process.
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let icon: NSImage?
    /// Core Audio's objects for the app's processes with sound: the app's own, its helpers', or both.
    var processes: [AudioObjectID] = []
    /// Whether any of them is sending sound to an output right now.
    var isPlaying = false

    /// What its volume is remembered by.
    var volumeKey: String {
        bundleIdentifier ?? name
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processes == rhs.processes && lhs.isPlaying == rhs.isPlaying
    }
}

/// Which apps are sending sound right now, as Core Audio sees it (macOS 14.2 and later). No permission is needed: it
/// says which apps play, not what.
enum AudioApps {
    /// The apps playing, by name, with Eyelid and the system's own services left out. Empty before macOS 14.2.
    @MainActor
    static func playing() -> [AudioApp] {
        all(withIcons: true).filter(\.isPlaying)
    }

    /// Every app with a process Core Audio knows, playing or not, by name. Icons take a while to load, so only what
    /// shows them asks for them.
    @MainActor
    static func all(withIcons: Bool = false) -> [AudioApp] {
        guard #available(macOS 14.2, *) else { return [] }
        let objects: [AudioObjectID] = AudioProperty.array(
            AudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID(kAudioObjectSystemObject)
        )
        let processes = objects.compactMap { object -> AudioProcess? in
            guard let pid: pid_t = AudioProperty.value(AudioProperty.address(kAudioProcessPropertyPID), of: object)
            else { return nil }
            let running: UInt32 = AudioProperty.value(
                AudioProperty.address(kAudioProcessPropertyIsRunningOutput),
                of: object
            ) ?? 0
            return AudioProcess(object: object, pid: pid, isPlaying: running != 0)
        }
        let own = ProcessInfo.processInfo.processIdentifier
        return apps(processes, responsible: responsibilityGetPIDResponsibleForPID) { pid in
            // Apps only: daemons such as Siri's speech service have no app, and helpers have none of their own.
            guard pid != own,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy != .prohibited,
                  let name = app.localizedName
            else { return nil }
            return AudioApp(
                id: pid,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                icon: withIcons ? app.icon : nil
            )
        }
    }

    /// A process Core Audio knows.
    struct AudioProcess: Equatable {
        let object: AudioObjectID
        let pid: pid_t
        let isPlaying: Bool
    }

    /// The app behind each process, each once with all its processes, by name. A process whose responsible one
    /// can't be told stands for itself.
    static func apps(
        _ processes: [AudioProcess],
        responsible: (pid_t) -> pid_t,
        app: (pid_t) -> AudioApp?
    ) -> [AudioApp] {
        var order: [pid_t] = []
        var found: [pid_t: AudioApp] = [:]
        var unknown = Set<pid_t>()
        for process in processes {
            let owner = responsible(process.pid)
            let pid = owner > 0 ? owner : process.pid
            guard !unknown.contains(pid) else { continue }
            if found[pid] == nil {
                guard let new = app(pid) else {
                    unknown.insert(pid)
                    continue
                }
                found[pid] = new
                order.append(pid)
            }
            found[pid]?.processes.append(process.object)
            if process.isPlaying {
                found[pid]?.isPlaying = true
            }
        }
        return order.compactMap { found[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
