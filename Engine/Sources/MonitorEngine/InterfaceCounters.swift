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
    /// Readings for every interface, or only the physical ones (the cheap path used every second).
    public static func readAll(physicalOnly: Bool = false) -> [InterfaceReading] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var readings: [InterfaceReading] = []
        var entry = list
        while entry.pointee.if_index != 0, let cName = entry.pointee.if_name {
            let name = String(cString: cName)
            if !physicalOnly || isPhysical(name), let reading = reading(name: name, index: entry.pointee.if_index) {
                readings.append(reading)
            }
            entry += 1
        }
        return readings
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

    public init() {}

    /// What moved on physical interfaces since the previous call. The first call returns zero.
    public mutating func sample(_ readings: [InterfaceReading] = InterfaceCounters.readAll(physicalOnly: true)) -> InterfaceDelta {
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
