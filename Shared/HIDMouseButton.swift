enum HIDMouseButton {
    static let leftMask: UInt8 = 0x01
    static let rightMask: UInt8 = 0x02
    static let middleMask: UInt8 = 0x04

    /// UI code addresses mouse buttons by their conventional ordinal number
    /// (1 = left, 2 = right, 3 = middle), while the HID mouse report stores
    /// buttons as bits. Keeping that conversion in one place prevents ordinal
    /// 3 (0b011) from accidentally pressing left + right instead of middle.
    static func mask(forOrdinal ordinal: UInt8) -> UInt8? {
        switch ordinal {
        case 1: leftMask
        case 2: rightMask
        case 3: middleMask
        default: nil
        }
    }
}
