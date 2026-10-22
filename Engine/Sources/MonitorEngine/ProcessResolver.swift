import AppKit
import Darwin

/// Turns a process ID into the app a person would recognize, so
/// "Google Chrome Helper (Renderer)" becomes Google Chrome and `cloudd` becomes iCloud.
public final class ProcessResolver: @unchecked Sendable {
    public enum Method: String, Sendable {
        case responsibleApp = "responsible app"
        case enclosingBundle = "enclosing bundle"
        case parentProcess = "parent process"
        case nameTable = "name table"
        case unknown = "unknown"
    }

    public struct Resolution: Sendable {
        public let identity: AppIdentity
        public let method: Method
        /// The executable's full name, for debug logging only. Never shown in the UI.
        public let executableName: String
    }

    private struct CacheKey: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicros: UInt64
    }

    private let lock = NSLock()
    private var cache: [CacheKey: Resolution] = [:]
    /// The latest answer per process ID, for rows that arrive after their process has exited
    /// (a download tool's final bytes are often reported a moment after it quits).
    private var recent: [pid_t: (nettopName: String, resolution: Resolution)] = [:]
    private var bundleIDLookups: [String: AppIdentity?] = [:]

    /// Called once per unknown process in debug builds, so the name table can grow.
    public var logUnknown: (@Sendable (String) -> Void)?

    public init() {}

    /// The private `responsibility_get_pid_responsible_for_pid`, which Activity Monitor
    /// uses to group helpers under their app. Nil if a future macOS removes it.
    private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    public static var hasResponsibilityFunction: Bool { responsibleFor != nil }

    public func resolve(pid: pid_t, nettopName: String) -> Resolution {
        guard let info = Self.processInfo(pid) else {
            // The process already exited. Reuse what it resolved to while it ran, if we saw it.
            if let last = lock.withLock({ recent[pid] }), last.nettopName == nettopName {
                return last.resolution
            }
            if let named = FriendlyNames.lookup(truncated: nettopName) {
                return Resolution(identity: named, method: .nameTable, executableName: nettopName)
            }
            return Resolution(identity: .macSystem, method: .unknown, executableName: nettopName)
        }
        let key = CacheKey(pid: pid, startSeconds: info.startSeconds, startMicros: info.startMicros)
        if let cached = lock.withLock({ cache[key] }) {
            lock.withLock { recent[pid] = (nettopName, cached) }
            return cached
        }

        let resolution = resolveUncached(pid: pid, info: info, nettopName: nettopName)
        if resolution.method == .unknown { logUnknown?("\(resolution.executableName) (pid \(pid))") }

        lock.lock()
        // Drop entries for processes that are gone so the cache stays small.
        if cache.count > 2_000 { cache = cache.filter { Self.processInfo($0.key.pid) != nil } }
        if recent.count > 2_000 { recent = recent.filter { Self.processInfo($0.key) != nil } }
        cache[key] = resolution
        recent[pid] = (nettopName, resolution)
        lock.unlock()
        return resolution
    }

    private func resolveUncached(pid: pid_t, info: KernelProcessInfo, nettopName: String) -> Resolution {
        let path = Self.executablePath(pid)
        let executable = path.map { ($0 as NSString).lastPathComponent } ?? (info.name.isEmpty ? nettopName : info.name)

        // 1. Responsible app.
        if let responsibleFor = Self.responsibleFor {
            let responsible = responsibleFor(pid)
            if responsible > 0, responsible != pid,
               let responsiblePath = Self.executablePath(responsible),
               let app = appIdentity(containing: responsiblePath) {
                return Resolution(identity: app, method: .responsibleApp, executableName: executable)
            }
        }
        // 2. Enclosing app bundle (or a bundle-ID match for system extensions and helpers).
        if let path, let app = appIdentity(containing: path) {
            return Resolution(identity: app, method: .enclosingBundle, executableName: executable)
        }
        // 3. Parent processes, up to launchd.
        var parent = info.parentPID
        var hops = 0
        while parent > 1, hops < 16 {
            if let parentPath = Self.executablePath(parent), let app = appIdentity(containing: parentPath) {
                return Resolution(identity: app, method: .parentProcess, executableName: executable)
            }
            guard let parentInfo = Self.processInfo(parent) else { break }
            parent = parentInfo.parentPID
            hops += 1
        }
        // 4. Friendly name table.
        if let named = FriendlyNames.lookup(executable) ?? FriendlyNames.lookup(truncated: nettopName) {
            return Resolution(identity: named, method: .nameTable, executableName: executable)
        }
        return Resolution(identity: .macSystem, method: .unknown, executableName: executable)
    }

    // MARK: - Bundles

    /// The outermost `.app` in the path, or else an installed app whose bundle ID prefixes a
    /// reverse-DNS component of the path (system extensions live outside their app, e.g.
    /// `io.tailscale.ipn.macsys.network-extension` belongs to `io.tailscale.ipn.macsys`).
    func appIdentity(containing path: String) -> AppIdentity? {
        // Small helper apps tucked inside system frameworks (such as IMTransferAgent.app) are not
        // apps a person would recognize; they fall through to the friendly name table instead.
        if Self.isInsideSystemFramework(path) { return nil }
        if let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) {
            let appPath = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return identity(forAppAt: "/" + appPath)
        }
        for component in (path as NSString).pathComponents.reversed() where Self.looksLikeBundleID(component) {
            if let app = installedApp(matchingBundleIDPrefixOf: component) { return app }
        }
        return nil
    }

    private func identity(forAppAt appPath: String) -> AppIdentity? {
        let bundle = Bundle(path: appPath)
        let bundleID = bundle?.bundleIdentifier
        var name = FileManager.default.displayName(atPath: appPath)
        if name.hasSuffix(".app") { name.removeLast(4) }
        // Prefer the app's own display name ("Claude Code" rather than its "claude" file name).
        if let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary,
           let display = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
           display.lowercased() == name.lowercased() || name == name.lowercased() {
            name = display
        }
        return AppIdentity(key: bundleID ?? appPath, displayName: name, kind: .app,
                           bundleID: bundleID, bundlePath: appPath)
    }

    private func installedApp(matchingBundleIDPrefixOf component: String) -> AppIdentity? {
        var parts = component
            .replacingOccurrences(of: ".systemextension", with: "")
            .replacingOccurrences(of: ".appex", with: "")
            .replacingOccurrences(of: ".xpc", with: "")
            .split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            lock.lock()
            let known = bundleIDLookups[candidate]
            lock.unlock()
            if let known { if let app = known { return app } } else {
                let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate)
                    .flatMap { identity(forAppAt: $0.path) }
                lock.lock(); bundleIDLookups[candidate] = .some(found); lock.unlock()
                if let found { return found }
            }
            parts.removeLast()
        }
        return nil
    }

    static func isInsideSystemFramework(_ path: String) -> Bool {
        guard path.hasPrefix("/System/") || path.contains("/Cryptexes/") else { return false }
        guard let app = path.range(of: ".app/") ?? path.range(of: ".app", options: .backwards) else { return false }
        return path[..<app.lowerBound].contains(".framework/")
    }

    static func looksLikeBundleID(_ component: String) -> Bool {
        let dots = component.filter { $0 == "." }.count
        return dots >= 2 && !component.contains(" ") && component.first?.isLetter == true
    }

    // MARK: - Process information

    struct KernelProcessInfo {
        let parentPID: pid_t
        let startSeconds: UInt64
        let startMicros: UInt64
        let name: String
    }

    /// Parent, start time and short name from the `kern.proc.pid` sysctl, which works for every
    /// process. (`proc_pidinfo` is refused for processes owned by other users, such as daemons
    /// and network extensions.)
    static func processInfo(_ pid: pid_t) -> KernelProcessInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return KernelProcessInfo(parentPID: info.kp_eproc.e_ppid, startSeconds: UInt64(start.tv_sec),
                                 startMicros: UInt64(start.tv_usec), name: name)
    }

    /// Works for every process, including ones owned by other users.
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
