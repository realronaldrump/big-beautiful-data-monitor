import Foundation

/// One process row from a `nettop` sample.
public struct NettopRow: Sendable, Equatable {
    /// The process name as `nettop` prints it, truncated to 15 characters.
    public let name: String
    public let pid: Int32
    public let bytes: ByteCounts
}

/// Rows from one `nettop` sample (or part of one). The first sample after launch holds
/// lifetime totals rather than deltas, so it is marked as the baseline and must not be counted.
public struct NettopSample: Sendable, Equatable {
    public let rows: [NettopRow]
    public let isBaseline: Bool
}

public enum NettopEvent: Sendable, Equatable {
    case sample(NettopSample)
    /// The header did not match what this parser understands (for example after a macOS update).
    case unexpectedFormat(header: String)
}

/// Parses the CSV that `nettop -P -d -x -L 0 -J bytes_in,bytes_out` prints, line by line.
///
/// Each sample starts with the header `,bytes_in,bytes_out,` followed by one row per process,
/// such as `Google Chrome H.5286,16347566,9241821,`. Names can contain spaces, dots,
/// parentheses and (in theory) commas, so rows are read from the right.
public struct NettopParser: Sendable {
    public static let expectedHeader = ["", "bytes_in", "bytes_out"]

    private var rows: [NettopRow] = []
    private var inSample = false
    private var headersSeen = 0
    private var formatBroken = false

    public init() {}

    /// Feeds one line of output. Returns an event when a header line completes the previous sample.
    public mutating func feed(_ line: some StringProtocol) -> NettopEvent? {
        guard !formatBroken else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }

        if Self.isHeader(fields) {
            guard fields == Self.expectedHeader else {
                formatBroken = true
                rows = []
                return .unexpectedFormat(header: trimmed)
            }
            let finished = flush()
            headersSeen += 1
            inSample = true
            return finished
        }

        guard inSample, let row = Self.parseRow(fields) else { return nil }
        rows.append(row)
        return nil
    }

    /// Emits the rows collected so far. Safe to call when output goes quiet mid-sample:
    /// rows are deltas, so a sample delivered in two pieces adds up the same.
    public mutating func flush() -> NettopEvent? {
        guard inSample, !rows.isEmpty else { return nil }
        let sample = NettopSample(rows: rows, isBaseline: headersSeen <= 1)
        rows = []
        return .sample(sample)
    }

    static func isHeader(_ fields: [String]) -> Bool {
        fields.contains("bytes_in") || fields.first == "time"
    }

    static func parseRow(_ fields: [String]) -> NettopRow? {
        let numberCount = expectedHeader.count - 1
        guard fields.count > numberCount else { return nil }
        let label = fields.dropLast(numberCount).joined(separator: ",")
        guard let bytesIn = UInt64(fields[fields.count - 2]),
              let bytesOut = UInt64(fields[fields.count - 1]),
              let dot = label.lastIndex(of: "."),
              let pid = Int32(label[label.index(after: dot)...]) else { return nil }
        return NettopRow(name: String(label[..<dot]), pid: pid, bytes: ByteCounts(down: bytesIn, up: bytesOut))
    }
}
