import Foundation
import Darwin
import SpawnSupport

/// Runs one long-lived `nettop` child and delivers per-process byte deltas.
///
/// Three things about `nettop` on macOS 27, found by testing, shape this class:
/// - Its output is block-buffered when written to a pipe (samples arrive in ~6 s bursts),
///   so it writes to a pseudo-terminal instead, which makes it line-buffered.
/// - It spins at ~140% CPU when its standard input reaches end-of-file (a GUI app's stdin
///   is /dev/null), so stdin is the same pseudo-terminal, which simply never has input.
/// - An orphaned `nettop` keeps running (and spins). Making the pseudo-terminal its controlling
///   terminal means the kernel sends it SIGHUP the moment this process dies, even in a crash.
public final class NettopSampler: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case running
        case restarting(after: TimeInterval)
        /// `nettop`'s output format changed; per-app numbers are unavailable until the parser is updated.
        case unsupportedFormat(header: String)
    }

    /// Called on `queue` with each sample's rows and the time it arrived. Baseline samples are not delivered.
    public var onSample: (@Sendable (NettopSample, Date) -> Void)?
    public var onStatus: (@Sendable (Status) -> Void)?

    public let queue: DispatchQueue
    public private(set) var interval: Int
    private var status: Status = .stopped

    private var childPID: pid_t = 0
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var watchdog: DispatchSourceTimer?
    private var flushItem: DispatchWorkItem?
    private var restartItem: DispatchWorkItem?

    private var parser = NettopParser()
    private var pending = Data()
    private var lastOutput = Date.distantPast
    private var wantsRunning = false
    private var failures = 0

    /// Restart delays after `nettop` exits or stalls: 1 s, 5 s, 30 s, then every 5 minutes.
    static let backoff: [TimeInterval] = [1, 5, 30, 300]

    public init(interval: Int = 1, queue: DispatchQueue = DispatchQueue(label: "nettop.sampler")) {
        self.interval = max(1, interval)
        self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            wantsRunning = true
            failures = 0
            if childPID == 0 { launch() }
        }
    }

    public func stop() {
        queue.async { [self] in
            wantsRunning = false
            restartItem?.cancel()
            terminateChild()
            setStatus(.stopped)
        }
    }

    /// Changing the interval restarts the child, which is cheap.
    public func setInterval(_ seconds: Int) {
        queue.async { [self] in
            let seconds = max(1, seconds)
            guard seconds != interval else { return }
            interval = seconds
            guard wantsRunning, case .running = status else { return }
            terminateChild()
            launch()
        }
    }

    // MARK: - Child process

    private func arguments() -> [String] {
        // -P per-process summaries, -d deltas, -x raw numbers, -n no name lookups,
        // -L 0 endless CSV, -t wifi/wired skips loopback, -J only the two byte columns.
        ["nettop", "-P", "-d", "-x", "-n", "-L", "0", "-s", String(interval),
         "-t", "wifi", "-t", "wired", "-J", "bytes_in,bytes_out"]
    }

    private func launch() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard wantsRunning, childPID == 0 else { return }

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return scheduleRestart() }

        // Raw mode: no echo and no "\r\n" translation.
        var attributes = termios()
        tcgetattr(slave, &attributes)
        cfmakeraw(&attributes)
        tcsetattr(slave, TCSANOW, &attributes)
        let slavePath = String(cString: ptsname(master))

        let args = arguments()
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        // The child opens the terminal by path, so keep our copy open until it is stopped.
        let pid = bbdm_spawn_with_tty("/usr/bin/nettop", &cArgs, slavePath)
        guard pid > 0 else {
            close(slave)
            close(master)
            return scheduleRestart()
        }

        childPID = pid
        masterFD = master
        slaveFD = slave
        parser = NettopParser()
        pending.removeAll()
        lastOutput = Date()
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        read.setCancelHandler { close(master) }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.childExited(pid) }
        exit.resume()
        exitSource = exit

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        watchdog = timer

        setStatus(.running)
    }

    private func terminateChild() {
        dispatchPrecondition(condition: .onQueue(queue))
        flushItem?.cancel()
        watchdog?.cancel(); watchdog = nil
        exitSource?.cancel(); exitSource = nil
        readSource?.cancel(); readSource = nil
        masterFD = -1
        if slaveFD >= 0 { close(slaveFD); slaveFD = -1 }
        if childPID > 0 {
            kill(childPID, SIGTERM)
            reap(childPID)
            childPID = 0
        }
    }

    private func reap(_ pid: pid_t) {
        let reaper = DispatchQueue.global(qos: .utility)
        reaper.async {
            var status: Int32 = 0
            // nettop exits promptly on SIGTERM; escalate if it does not.
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(50_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    private func childExited(_ pid: pid_t) {
        guard pid == childPID else { return }
        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, WNOHANG)
        childPID = 0
        terminateChild()
        if case .unsupportedFormat = status { return }
        scheduleRestart()
    }

    private func checkForStall() {
        // A healthy child prints a header every interval; allow generous slack before restarting.
        let limit = TimeInterval(interval * 3 + 5)
        guard childPID > 0, Date().timeIntervalSince(lastOutput) > limit else { return }
        terminateChild()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsRunning else { return }
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        failures += 1
        setStatus(.restarting(after: delay))
        let item = DispatchWorkItem { [weak self] in self?.launch() }
        restartItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Output

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(masterFD, &chunk, chunk.count)
            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
                lastOutput = Date()
                continue
            }
            // EIO or end-of-file means the child closed its terminal; the exit source handles the rest.
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                readSource?.cancel(); readSource = nil
            }
            break
        }
        processLines()
        // Each sample arrives as one burst. Deliver it once output goes quiet instead of
        // waiting a whole interval for the next header.
        flushItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushParser() }
        flushItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    private func processLines() {
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let event = parser.feed(line) { handle(event) }
        }
    }

    private func flushParser() {
        if let event = parser.flush() { handle(event) }
    }

    private func handle(_ event: NettopEvent) {
        switch event {
        case .sample(let sample):
            if !sample.isBaseline { failures = 0 }
            guard !sample.isBaseline else { return }
            onSample?(sample, Date())
        case .unexpectedFormat(let header):
            // Fall back to totals only. Restarting would not help; this needs a parser update.
            setStatus(.unsupportedFormat(header: header))
            wantsRunning = false
            terminateChild()
        }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatus?(new)
    }
}
