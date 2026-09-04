import Foundation

protocol InputTransport: AnyObject {
    func start()
    func stop(completion: @escaping () -> Void)
    func releaseAllInput()
    func setModifiers(_ mask: UInt8)
    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8)
    func sendKeyUp(keycode: UInt8)
    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8)
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)])
    func sendMouseMove(dx: Int8, dy: Int8)
    func sendMouseScroll(dx: Int8, dy: Int8)
    func sendMouseClick(button: UInt8)
    func sendMouseButtonDown(button: UInt8)
    func sendMouseButtonUp(button: UInt8)
}
