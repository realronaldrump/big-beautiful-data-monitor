import Foundation
import MonitorEngine

/// Ties the live engine to storage: every second's tick goes into the 15-minute live buffer and
/// the minute ledger, and each completed minute is saved in one transaction, off the engine's queue.
public final class UsageRecorder: @unchecked Sendable {
    public let engine: UsageEngine
    public let database: UsageDatabase?

    /// Every tick, after it has been recorded. Called on the engine's queue.
    public var onTick: (@Sendable (UsageTick) -> Void)?
    /// Minutes just saved. Called on the recorder's write queue.
    public var onSaved: (@Sendable ([MinuteSummary]) -> Void)?
    /// Storage errors never interrupt recording; they are only reported here (debug logging).
    public var onError: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var ledger = MinuteLedger()
    private var buffer = LiveBuffer()
    private let writeQueue = DispatchQueue(label: "usage.recorder.write", qos: .utility)

    public init(engine: UsageEngine, database: UsageDatabase?) {
        self.engine = engine
        self.database = database
        engine.onTick = { [weak self] tick in self?.receive(tick) }
    }

    public func start() {
        engine.start()
    }

    /// Stops sampling and saves everything collected so far (on quit and on sleep).
    public func stop() {
        engine.stop()
        flush()
    }

    /// Saves the still-open minutes now and waits until they are written. Safe to call from `onTick`.
    public func flush() {
        let minutes = lock.withLock { ledger.close() }
        writeQueue.sync { save(minutes) }
    }

    /// The live buffer, for the ribbon and the Now view.
    public var live: LiveBuffer {
        lock.withLock { buffer }
    }

    /// Bytes in minutes that are not saved yet; add these to stored totals for an up-to-the-second "today".
    public var unsaved: (total: ByteCounts, apps: [AppIdentity: ByteCounts]) {
        lock.withLock { ledger.unsaved }
    }

    private func receive(_ tick: UsageTick) {
        let completed = lock.withLock {
            buffer.append(tick)
            return ledger.add(tick)
        }
        if !completed.isEmpty {
            writeQueue.async { [self] in save(completed) }
        }
        onTick?(tick)
    }

    private func save(_ minutes: [MinuteSummary]) {
        guard !minutes.isEmpty else { return }
        do {
            try database?.save(minutes)
            onSaved?(minutes)
        } catch {
            onError?(error)
        }
    }
}
