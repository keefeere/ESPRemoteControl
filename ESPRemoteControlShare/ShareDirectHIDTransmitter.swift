import Combine
import Foundation

protocol ShareTextTransmitter: AnyObject {
    var onStatusChange: ((String) -> Void)? { get set }

    func send(
        _ taps: [(modifiers: UInt8, keycode: UInt8)],
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func cancel()
}

/// Uses the same HOGP peripheral as the app's “Прямий Bluetooth” input mode.
/// The extension has its own preferences container, so its selected host is
/// intentionally remembered separately from the app's host selection.
final class ShareDirectHIDTransmitter: ShareTextTransmitter {
    enum TransmitError: LocalizedError {
        case hostUnavailable
        case queueRejected

        var errorDescription: String? {
            switch self {
            case .hostUnavailable:
                "Комп’ютер не підключився через прямий Bluetooth"
            case .queueRejected:
                "Не вдалося поставити текст у чергу Bluetooth"
            }
        }
    }

    var onStatusChange: ((String) -> Void)?

    private let transport = DirectHIDTransport(hostKey: "shareDirectHID.selectedHost")
    private var subscriptions = Set<AnyCancellable>()
    private var pendingTaps: [(modifiers: UInt8, keycode: UInt8)] = []
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completionWorkItem: DispatchWorkItem?
    private var hasEnqueuedInput = false

    init() {
        transport.$statusText
            .removeDuplicates()
            .sink { [weak self] status in self?.onStatusChange?(status) }
            .store(in: &subscriptions)

        transport.$isReady
            .removeDuplicates()
            .sink { [weak self] isReady in
                guard isReady else { return }
                self?.enqueuePendingInput()
            }
            .store(in: &subscriptions)
    }

    func send(
        _ taps: [(modifiers: UInt8, keycode: UInt8)],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard self.completion == nil else { return }
        pendingTaps = taps
        self.completion = completion
        onStatusChange?("Запуск прямого Bluetooth…")
        transport.start()
        enqueuePendingInput()

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(TransmitError.hostUnavailable))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
    }

    func cancel() {
        timeoutWorkItem?.cancel()
        completionWorkItem?.cancel()
        completion = nil
        transport.stop { }
    }

    private func enqueuePendingInput() {
        guard !hasEnqueuedInput, completion != nil, transport.isReady else { return }
        hasEnqueuedInput = true
        timeoutWorkItem?.cancel()
        onStatusChange?("Надсилання \(pendingTaps.count) клавіш напряму…")
        let deliveryTimeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(TransmitError.queueRejected))
        }
        timeoutWorkItem = deliveryTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deliveryTimeout)
        let accepted = transport.sendKeyTaps(pendingTaps, whenDrained: { [weak self] in
            self?.scheduleSuccessfulCompletion()
        })
        if !accepted {
            finish(.failure(TransmitError.queueRejected))
        }
    }

    private func scheduleSuccessfulCompletion() {
        guard completionWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.success(()))
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        timeoutWorkItem?.cancel()
        completionWorkItem?.cancel()
        self.completion = nil
        transport.stop {
            completion(result)
        }
    }
}
