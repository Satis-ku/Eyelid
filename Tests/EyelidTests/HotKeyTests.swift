import AppKit
import Carbon.HIToolbox
import Testing
@testable import Eyelid

@MainActor
@Suite("Keyboard shortcuts")
struct HotKeyTests {
    @Test func needsCommandOptionOrControl() {
        #expect(HotKey(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.shift]) == nil)
        #expect(HotKey(keyCode: UInt16(kVK_ANSI_V), modifierFlags: []) == nil)
        #expect(HotKey(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command, .shift]) == .clipboardDefault)
        #expect(HotKey(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.option]) != nil)
    }

    @Test func readsLikeAMenuShortcut() {
        // A letter reads as the current keyboard layout has it, such as Y for Z on a German one, so only the
        // modifiers are certain.
        #expect(HotKey.clipboardDefault.displayString.hasPrefix("⇧⌘"))
        #expect(HotKey.liveActivityDefault.displayString.hasPrefix("⌥"))
        let all = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(all.displayString == "⌃⌥⇧⌘Space")
        #expect(HotKey(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey)).displayString == "⌥F5")
    }

    /// Settings tells a clash between two of Eyelid's own shortcuts from one with another app.
    @Test func aShortcutTakenByAnotherOfEyelidsSaysSo() throws {
        let center = HotKeyCenter()
        // Unlikely to be anyone else's.
        let hotKey = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey))
        let first = try #require(center.register(hotKey) {})
        defer { center.unregister(first) }

        let shortcut = Shortcut(center: center, isEnabled: { true }, hotKey: { hotKey })

        #expect(shortcut.isTaken)
        #expect(shortcut.isTakenByEyelid)
        #expect(shortcut.problem?.contains("Eyelid") == true)
    }
}
