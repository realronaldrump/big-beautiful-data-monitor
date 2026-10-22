import Darwin

/// Packets received (down) and sent (up). Same shape as bytes.
public typealias PacketCounts = ByteCounts

/// One interface's lifetime counters, as kept by the kernel.
public struct InterfaceReading: Sendable, Hashable {
    public let name: String
    public let bytes: ByteCounts
    public let packets: PacketCounts
}

/// What moved on the physical interfaces between two readings.
public struct InterfaceDelta: Sendable, Hashable {
    public var bytes: ByteCounts
    public var packets: PacketCounts

    public static let zero = InterfaceDelta(bytes: .zero, packets: .zero)
}

/// Reads the kernel's 64-bit interface byte counters.
///
/// Found by testing on macOS 27: the spec's `NET_RT_IFLIST2` (like `getifaddrs`) now returns only the
/// low 32 bits, rounded to 1 KB, so it wraps every 4 GB. The `net.link.generic.ifdata` sysctl
/// (`IFMIB_IFDATA`, the one `netstat -ib` uses) still returns the exact 64-bit counters, with no
/// entitlement or permission needed.
public enum InterfaceCounters {
    /// Readings for every interface, or only the physical ones.
    public static func readAll(physicalOnly: Bool = false) -> [InterfaceReading] {
        read(interfaces().filter { !physicalOnly || isPhysical($0.name) })
    }

    /// Every interface's name and index. Listing them asks the kernel for all ~35 interfaces,
    /// so the meter does this only every few seconds and reads just the physical ones in between.
    public static func interfaces() -> [(name: String, index: UInt32)] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var interfaces: [(name: String, index: UInt32)] = []
        var entry = list
        while entry.pointee.if_index != 0, let cName = entry.pointee.if_name {
            interfaces.append((String(cString: cName), entry.pointee.if_index))
            entry += 1
        }
        return interfaces
    }

    public static func read(_ interfaces: [(name: String, index: UInt32)]) -> [InterfaceReading] {
        interfaces.compactMap { reading(name: $0.name, index: $0.index) }
    }

    /// Wi-Fi, Ethernet and iPhone USB tethering all appear as `en*`; cellular as `pdp_ip*`.
    /// Loopback, VPN tunnels (`utun`, `ipsec`), AirDrop (`awdl`, `llw`), bridges and
    /// sharing interfaces are skipped so nothing counts twice.
    public static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    private static func reading(name: String, index: UInt32) -> InterfaceReading? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        let counters = data.ifmd_data
        return InterfaceReading(name: name,
                                bytes: ByteCounts(down: counters.ifi_ibytes, up: counters.ifi_obytes),
                                packets: PacketCounts(down: counters.ifi_ipackets, up: counters.ifi_opackets))
    }
}

/// Turns lifetime counters into per-call deltas for the physical interfaces.
public struct InterfaceMeter: Sendable {
    private var last: [String: InterfaceReading] = [:]
    private var primed = false
    private var physical: [(name: String, index: UInt32)] = []
    private var calls = 0

    public init() {}

    /// What moved on physical interfaces since the previous call. The first call returns zero.
    /// The list of interfaces is refreshed every five seconds (or when a read fails), so a newly
    /// plugged-in iPhone or Ethernet adapter is picked up within seconds.
    public mutating func sample() -> InterfaceDelta {
        if calls % 5 == 0 || physical.isEmpty {
            physical = InterfaceCounters.interfaces().filter { InterfaceCounters.isPhysical($0.name) }
        }
        calls += 1
        var readings = InterfaceCounters.read(physical)
        if readings.count != physical.count {
            physical = InterfaceCounters.interfaces().filter { InterfaceCounters.isPhysical($0.name) }
            readings = InterfaceCounters.read(physical)
        }
        return sample(readings)
    }

    /// The same, from readings taken elsewhere (for tests).
    public mutating func sample(_ readings: [InterfaceReading]) -> InterfaceDelta {
        var delta = InterfaceDelta.zero
        var current: [String: InterfaceReading] = [:]
        for reading in readings where InterfaceCounters.isPhysical(reading.name) {
            current[reading.name] = reading
            guard primed else { continue }
            let previous = last[reading.name] ?? reading
            delta.bytes += Self.difference(reading.bytes, previous.bytes)
            delta.packets += Self.difference(reading.packets, previous.packets)
        }
        last = current
        primed = true
        return delta
    }

    /// A counter that went backwards means the interface was reset; count from zero.
    private static func difference(_ new: ByteCounts, _ old: ByteCounts) -> ByteCounts {
        ByteCounts(down: new.down >= old.down ? new.down - old.down : new.down,
                   up: new.up >= old.up ? new.up - old.up : new.up)
    }
}
