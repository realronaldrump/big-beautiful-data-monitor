import CoreGraphics
import Foundation
import Network

/// The kind of network the Mac is on, from `NWPathMonitor`. An iPhone hotspot shows up as an
/// "expensive" path, whether it is joined over Wi-Fi or USB.
public enum NetworkKind: String, Sendable, Codable, CaseIterable {
    case wifi
    case wired
    case hotspot
    case other
    case offline
}

public final class NetworkKindMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var kind: NetworkKind = .offline

    public init(queue: DispatchQueue = DispatchQueue(label: "network.kind")) {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.kind(of: path)
            self?.lock.withLock { self?.kind = kind }
        }
        monitor.start(queue: queue)
        kind = Self.kind(of: monitor.currentPath)
    }

    deinit { monitor.cancel() }

    public var current: NetworkKind { lock.withLock { kind } }

    static func kind(of path: NWPath) -> NetworkKind {
        guard path.status == .satisfied else { return .offline }
        if path.isExpensive { return .hotspot }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}

/// Seconds since the last keyboard or mouse input. Reading this needs no permission.
public enum IdleClock {
    public static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Asks the window server only every few seconds and counts up in between. Idle only matters
    /// per minute, so being a few seconds behind changes nothing that is shown.
    public struct Cached: Sendable {
        private var value: TimeInterval = 0
        private var checked = Date.distantPast

        public init() {}

        public mutating func secondsSinceInput(now: Date = Date()) -> TimeInterval {
            let elapsed = now.timeIntervalSince(checked)
            guard elapsed >= 5 else { return value + elapsed }
            value = IdleClock.secondsSinceInput()
            checked = now
            return value
        }
    }

    /// A minute counts as idle when nobody touched the Mac for all of it.
    public static let idleThreshold: TimeInterval = 60
}
