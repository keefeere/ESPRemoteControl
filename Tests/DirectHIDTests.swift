import Foundation

@main
struct DirectHIDTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        keyboardTransitions()
        mouseTransitions()
        notificationBackpressure()
        hostSelection()
        descriptorSizes()
        print("PASS: HID reports, held input, FIFO backpressure, host isolation, boot mode, descriptor sizes")
    }

    static func keyboardTransitions() {
        var state = HIDInputState()
        let ctrlA = state.keyDown(4, modifiers: 1)
        check(Array(ctrlA.data) == [1, 0, 4, 0, 0, 0, 0, 0], "Ctrl+A layout")
        let tapB = state.tap(5, modifiers: 2)
        check(Array(tapB[0].data) == [2, 0, 4, 5, 0, 0, 0, 0], "Temporary Shift+B preserves held A")
        check(tapB[1] == ctrlA && state.keyboard == ctrlA, "Tap restores held modifiers and keys")
        let repeatA = state.tap(4, modifiers: 1)
        check(repeatA.count == 3 && repeatA[0].data[2] == 0 && repeatA[1] == ctrlA, "Repeated held key has a release edge")
        let modifiersOnly = state.tap(0, modifiers: 5)
        check(modifiersOnly[0].data[0] == 5 && modifiersOnly[1] == ctrlA, "Modifier-only layout shortcut restores state")
        for key in UInt8(5)...UInt8(10) { _ = state.keyDown(key, modifiers: 0) }
        check(Array(state.keyboard.data.suffix(6)) == [1, 1, 1, 1, 1, 1], "Seven-key rollover is explicit")
        _ = state.keyUp(10)
        check(Array(state.keyboard.data.suffix(6)) == [4, 5, 6, 7, 8, 9], "Releasing rollover restores held keys")
        let reset = state.releaseAll()
        check(reset[0].data == Data(repeating: 0, count: 8), "Release clears keyboard")
        check(reset[1].data == Data(repeating: 0, count: 5), "Release clears mouse")
    }

    static func mouseTransitions() {
        var state = HIDInputState()
        _ = state.buttonDown(1)
        let drag = state.mouse(dx: -12, dy: 9, wheel: -3, pan: 7)
        check(Array(drag.data) == [1, 244, 9, 253, 7], "Drag preserves left button and signed axes")
        let rightClick = state.click(2)
        check(rightClick[0].data[0] == 3 && rightClick[1].data[0] == 1, "Right click preserves held left button")
        check(state.mouse(dx: -128).data[1] == 129, "Mouse delta respects descriptor minimum")
        check(state.buttonUp(7).data == Data(repeating: 0, count: 5), "Release all buttons")
    }

    static func notificationBackpressure() {
        let state = HIDInputState()
        var expected: [HIDInputReport] = []
        for i in 0..<1_000 {
            expected += state.tap(UInt8(4 + i % 26), modifiers: UInt8(i % 2))
            if i % 9 == 0 { expected.append(state.mouse(dx: 1, dy: -1)) }
        }
        var queue = HIDReportQueue()
        check(queue.append(expected), "Long input accepted")
        var delivered: [HIDInputReport] = []
        var attempts = 0
        while !queue.isEmpty {
            attempts += 1
            let before = queue.count
            let blocked = attempts % 4 == 1
            _ = queue.sendNext { report in
                if blocked { return false }
                delivered.append(report)
                return true
            }
            check(queue.count == before - (blocked ? 0 : 1), "A rejected notification stays queued")
        }
        check(delivered == expected, "Every press/release and mouse event arrives in order")
        var bounded = HIDReportQueue(capacity: 2)
        check(bounded.append(state.tap(4, modifiers: 0)), "One complete tap fits")
        check(!bounded.append([state.mouse()]) && bounded.count == 2, "Overflow is atomic")
        bounded.removeAll()
        check(bounded.isEmpty, "Disconnect drops queued input")
        check(bounded.append(state.tap(5, modifiers: 0)), "New session starts clean")
        var newSession: [HIDInputReport] = []
        while !bounded.isEmpty { _ = bounded.sendNext { newSession.append($0); return true } }
        check(newSession == state.tap(5, modifiers: 0), "Old keystrokes cannot leak into a new session")
    }

    static func hostSelection() {
        let first = UUID(), second = UUID()
        var session = HIDHostSession(preferredHost: nil, allowsPairing: true)
        check(!session.isReady, "A Bluetooth link is not an HID subscription")
        check(session.subscribe(.keyboard, from: first), "First host selected")
        check(!session.isReady, "Wait for mouse too")
        check(!session.subscribe(.mouse, from: second), "Do not combine two hosts' subscriptions")
        check(session.subscribe(.mouse, from: first) && session.isReady, "Both reports ready on selected host")
        session.unsubscribe(.bootKeyboard, from: first)
        check(session.isReady, "Unrelated boot subscription does not remove report subscription")
        session.bootProtocol = true
        check(!session.isReady, "Boot mode needs boot subscriptions")
        _ = session.subscribe(.bootKeyboard, from: first)
        _ = session.subscribe(.bootMouse, from: first)
        check(session.isReady, "Boot keyboard and mouse ready")
        session.suspended = true
        check(!session.isReady, "Host suspend prevents input")
        session.disconnect(first)
        check(session.host == nil && session.subscriptions.isEmpty && !session.bootProtocol, "Disconnect clears connection state")
        check(!session.allows(second) && session.allows(first), "Reconnect stays pinned to selected host")
        session = HIDHostSession(preferredHost: second, allowsPairing: true)
        check(!session.allows(first), "Phone-initiated connection is pinned before subscription")
        _ = session.subscribe(.keyboard, from: second)
        _ = session.subscribe(.mouse, from: second)
        check(session.isReady, "Explicitly selected second host works")
        session = HIDHostSession(preferredHost: nil, allowsPairing: false)
        check(!session.allows(first), "Closed pairing window rejects new hosts")
    }

    /// Parse HID short items independently of the encoder. The host will use
    /// these bit counts when decoding input, so descriptor/payload drift fails.
    static func descriptorSizes() {
        let bytes = [UInt8](RemoteHIDDescriptor.reportMap)
        var index = 0, size = 0, count = 0, report = 0
        var input: [Int: Int] = [:], output: [Int: Int] = [:]
        while index < bytes.count {
            let prefix = Int(bytes[index]); index += 1
            let length = (prefix & 3) == 3 ? 4 : (prefix & 3)
            check(index + length <= bytes.count, "Truncated HID item")
            var value = 0
            for offset in 0..<length { value |= Int(bytes[index + offset]) << (offset * 8) }
            index += length
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            if type == 1 {
                if tag == 7 { size = value }
                if tag == 8 { report = value }
                if tag == 9 { count = value }
            } else if type == 0 {
                if tag == 8 { input[report, default: 0] += size * count }
                if tag == 9 { output[report, default: 0] += size * count }
            }
        }
        check(input == [1: 64, 2: 40], "Report map must describe eight keyboard and five mouse bytes")
        check(output == [1: 8], "Keyboard LED output is one byte")
    }
}
