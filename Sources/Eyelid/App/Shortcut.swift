import Observation

/// Keeps a global shortcut registered while it's turned on, and follows changes to it in Settings: the clipboard
/// history's, the translator's, and the one that hides the live activity.
@MainActor
@Observable
final class Shortcut {
    @ObservationIgnored var onPress: (@MainActor () -> Void)?

    /// Whether another app, or another of Eyelid's shortcuts, already has the shortcut, so it does nothing here.
    private(set) var isTaken = false
    /// Whether it's another of Eyelid's shortcuts that has it.
    private(set) var isTakenByEyelid = false

    /// What Settings says when the shortcut does nothing, if it does.
    var problem: String? {
        guard isTaken else { return nil }
        return isTakenByEyelid
            ? "Another of Eyelid's shortcuts uses this. Choose a different one."
            : "Another app already uses this shortcut. Choose a different one."
    }
    /// Set while Settings records a new shortcut, so pressing the current one records it instead of acting on it.
    var isSuspended = false

    @ObservationIgnored private let center: HotKeyCenter
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let hotKey: @MainActor () -> HotKey
    @ObservationIgnored private var registration: HotKeyCenter.Registration?

    /// `isEnabled` and `hotKey` read settings, which are followed as they change.
    init(center: HotKeyCenter, isEnabled: @escaping @MainActor () -> Bool, hotKey: @escaping @MainActor () -> HotKey) {
        self.center = center
        self.isEnabled = isEnabled
        self.hotKey = hotKey
        follow()
    }

    private func follow() {
        withObservationTracking {
            update(isOn: isEnabled() && !isSuspended, hotKey: hotKey())
        } onChange: { [weak self] in
            // `onChange` runs before the new value is stored, so read it on the next turn of the main actor.
            Task { @MainActor in
                self?.follow()
            }
        }
    }

    private func update(isOn: Bool, hotKey: HotKey) {
        if let registration {
            center.unregister(registration)
            self.registration = nil
        }
        guard isOn else {
            isTaken = false
            isTakenByEyelid = false
            return
        }
        registration = center.register(hotKey) { [weak self] in
            self?.onPress?()
        }
        isTaken = registration == nil
        isTakenByEyelid = isTaken && center.isRegistered(hotKey)
    }
}
