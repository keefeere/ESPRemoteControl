import Foundation

@main
struct MouseButtonMaskTests {
    static func main() {
        precondition(HIDMouseButton.mask(forOrdinal: 1) == 0x01, "Left button ordinal must map to HID bit 0")
        precondition(HIDMouseButton.mask(forOrdinal: 2) == 0x02, "Right button ordinal must map to HID bit 1")
        precondition(HIDMouseButton.mask(forOrdinal: 3) == 0x04, "Middle button ordinal must map to HID bit 2")
        precondition(HIDMouseButton.mask(forOrdinal: 0) == nil, "Button zero is invalid")
        precondition(HIDMouseButton.mask(forOrdinal: 4) == nil, "Only the three advertised mouse buttons are valid")

        let state = HIDInputState()
        let middle = state.click(HIDMouseButton.middleMask)
        precondition(middle.count == 2, "A click must contain press and release reports")
        precondition(middle[0].data[0] == 0x04, "Middle click must assert only HID button bit 2")
        precondition(middle[1].data[0] == 0x00, "Middle click must release all temporary button bits")

        print("PASS: logical mouse buttons map to HID button masks, including middle = 0x04")
    }
}
