import CoreAudio

/// Reading and writing CoreAudio object properties.
enum AudioProperty {
    /// Whether this Mac can tap apps' sound, for the equalizer and for apps' own volumes: macOS 14.2 and later.
    static var canTapProcesses: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func string(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> String? {
        let value: Unmanaged<CFString>?? = Self.value(address, of: object)
        return value??.takeRetainedValue() as String?
    }

    static func array<T>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func isSettable(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    static func set<T>(_ value: T, _ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        let status = withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
        return status == noErr
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let device: AudioDeviceID? = value(
            address(kAudioHardwarePropertyDefaultOutputDevice),
            of: AudioObjectID(kAudioObjectSystemObject)
        )
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }
}

extension UInt32 {
    /// A four-character code such as `'hdpn'`, which CoreAudio uses for transport types and data sources.
    init(fourCharacterCode code: StaticString) {
        precondition(code.utf8CodeUnitCount == 4, "A four-character code needs exactly four characters")
        let bytes = UnsafeBufferPointer(start: code.utf8Start, count: 4)
        self = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
