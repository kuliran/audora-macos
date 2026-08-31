import Foundation

/// Ephemeral notifications that immutable Sessions became authoritative.
///
/// The first active iterator subscribes when it is created; an additional
/// concurrent iterator completes immediately. Notifications are delivered in
/// FIFO order with one buffered receipt. If that slot is full, publication
/// suspends until the subscriber advances or cancels; receipts are never
/// coalesced. There is no replay: persisted Library state remains the source of
/// truth across subscriber and process lifetimes.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct SessionSealedNotifications: AsyncSequence, Sendable {
    public typealias Element = SessionSealedReceipt

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let subscription: SessionSealedNotificationSubscription?

        fileprivate init(subscription: SessionSealedNotificationSubscription?) {
            self.subscription = subscription
        }

        public mutating func next() async -> SessionSealedReceipt? {
            guard let subscription else { return nil }
            return await subscription.next()
        }
    }

    private let channel: SessionSealedNotificationChannel

    init(channel: SessionSealedNotificationChannel) {
        self.channel = channel
    }

    /// A completed notification sequence for implementations that never emit
    /// recording receipts.
    public static var finished: SessionSealedNotifications {
        let channel = SessionSealedNotificationChannel()
        channel.finish()
        return SessionSealedNotifications(channel: channel)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(subscription: channel.subscribe())
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private final class SessionSealedNotificationSubscription: @unchecked Sendable {
    private let channel: SessionSealedNotificationChannel
    private let subscriberID: UInt64

    init(channel: SessionSealedNotificationChannel, subscriberID: UInt64) {
        self.channel = channel
        self.subscriberID = subscriberID
    }

    func next() async -> SessionSealedReceipt? {
        await withTaskCancellationHandler {
            await channel.next(for: subscriberID)
        } onCancel: {
            channel.cancelSubscriber(subscriberID)
        }
    }

    deinit {
        channel.cancelSubscriber(subscriberID)
    }
}

/// Lock-confined implementation hidden behind `SessionSealedNotifications`.
/// `DefaultRecordingFeature` is its only producer. The channel retains at most
/// one delivered receipt; further publication work remains suspended at this
/// seam until capacity is available or the subscription ends.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class SessionSealedNotificationChannel: @unchecked Sendable {
    private struct PendingProducer {
        let receipt: SessionSealedReceipt
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct SubscriberState {
        var buffer: [SessionSealedReceipt] = []
        var waitingConsumer: CheckedContinuation<SessionSealedReceipt?, Never>?
        // `DefaultRecordingFeature` serializes publication, so at most one
        // producer may be suspended behind the single buffered receipt.
        var waitingProducer: PendingProducer?
    }

    private static let capacity = 1
    private static let maximumSubscribers = 1

    private let lock = NSLock()
    private var isFinished = false
    private var subscribers: [UInt64: SubscriberState] = [:]
    private var nextSubscriberID: UInt64 = 1

    fileprivate func subscribe() -> SessionSealedNotificationSubscription? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished,
              subscribers.count < Self.maximumSubscribers
        else { return nil }
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1
        subscribers[subscriberID] = SubscriberState()
        return SessionSealedNotificationSubscription(
            channel: self,
            subscriberID: subscriberID
        )
    }

    func send(_ receipt: SessionSealedReceipt) async {
        // A strictly reread Session is already authoritative. Once its
        // publication reaches this boundary, caller cancellation must not turn
        // the downstream receipt into a lossy effect or establish false
        // dedupe. Backpressure ends when the subscriber advances or cancels.
        let subscriberIDs = currentSubscriberIDs()
        for subscriberID in subscriberIDs {
            await enqueue(receipt, for: subscriberID)
        }
    }

    func finish() {
        var consumers: [CheckedContinuation<SessionSealedReceipt?, Never>] = []
        var producers: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        for subscriber in subscribers.values {
            if let consumer = subscriber.waitingConsumer {
                consumers.append(consumer)
            }
            if let producer = subscriber.waitingProducer {
                producers.append(producer.continuation)
            }
        }
        subscribers.removeAll(keepingCapacity: false)
        lock.unlock()
        for consumer in consumers { consumer.resume(returning: nil) }
        for producer in producers { producer.resume() }
    }

    fileprivate func next(for subscriberID: UInt64) async -> SessionSealedReceipt? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var result: SessionSealedReceipt??
                var resumedProducer: CheckedContinuation<Void, Never>?
                lock.lock()
                if Task.isCancelled || isFinished || subscribers[subscriberID] == nil {
                    result = .some(nil)
                } else if var subscriber = subscribers[subscriberID],
                          !subscriber.buffer.isEmpty
                {
                    let receipt = subscriber.buffer.removeFirst()
                    if let producer = subscriber.waitingProducer {
                        subscriber.waitingProducer = nil
                        subscriber.buffer.append(producer.receipt)
                        resumedProducer = producer.continuation
                    }
                    subscribers[subscriberID] = subscriber
                    result = .some(receipt)
                } else if var subscriber = subscribers[subscriberID] {
                    if let previous = subscriber.waitingConsumer {
                        subscriber.waitingConsumer = nil
                        subscribers[subscriberID] = subscriber
                        lock.unlock()
                        previous.resume(returning: nil)
                        continuation.resume(returning: nil)
                        cancelSubscriber(subscriberID)
                        return
                    }
                    subscriber.waitingConsumer = continuation
                    subscribers[subscriberID] = subscriber
                }
                lock.unlock()
                resumedProducer?.resume()
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: {
            cancelSubscriber(subscriberID)
        }
    }

    fileprivate func cancelSubscriber(_ subscriberID: UInt64) {
        var consumer: CheckedContinuation<SessionSealedReceipt?, Never>?
        var producers: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let subscriber = subscribers.removeValue(forKey: subscriberID) {
            consumer = subscriber.waitingConsumer
            if let producer = subscriber.waitingProducer {
                producers.append(producer.continuation)
            }
        }
        lock.unlock()
        consumer?.resume(returning: nil)
        for producer in producers { producer.resume() }
    }

    private func currentSubscriberIDs() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }
        return subscribers.keys.sorted()
    }

    private func enqueue(
        _ receipt: SessionSealedReceipt,
        for subscriberID: UInt64
    ) async {
        await withCheckedContinuation { continuation in
            var waitingConsumer: CheckedContinuation<SessionSealedReceipt?, Never>?
            var completesImmediately = false
            lock.lock()
            if isFinished || subscribers[subscriberID] == nil {
                completesImmediately = true
            } else if var subscriber = subscribers[subscriberID] {
                if let consumer = subscriber.waitingConsumer {
                    subscriber.waitingConsumer = nil
                    waitingConsumer = consumer
                    completesImmediately = true
                } else if subscriber.buffer.count < Self.capacity {
                    subscriber.buffer.append(receipt)
                    completesImmediately = true
                } else if subscriber.waitingProducer == nil {
                    subscriber.waitingProducer = PendingProducer(
                        receipt: receipt,
                        continuation: continuation
                    )
                } else {
                    // The Application producer fence makes this unreachable.
                    // Fail closed without growing storage if an implementation
                    // violates the single-producer seam.
                    assertionFailure("concurrent Session-seal publication")
                    completesImmediately = true
                }
                subscribers[subscriberID] = subscriber
            }
            lock.unlock()
            waitingConsumer?.resume(returning: receipt)
            if completesImmediately { continuation.resume() }
        }
    }
}
