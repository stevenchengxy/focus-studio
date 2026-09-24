import Foundation

/// Splits a byte stream into lines for the control channel's NDJSON framing.
///
/// - Lines end at a line feed (0x0A) and only there. Bytes are never
///   decoded here, so a multi-byte character split across two reads, or
///   U+2028 / U+2029 inside a JSON string, pass through untouched.
/// - A carriage return before the line feed is dropped; lines that are
///   empty or hold only spaces, tabs and carriage returns are skipped.
/// - A line longer than ``maximumLineLength`` bytes (not counting its line
///   feed) is an error as soon as that many bytes arrived without one; the
///   framer is then unusable and the connection should close.
/// - Any number of complete lines, and a partial one, may arrive in one read.
public struct LineFramer: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case lineTooLong(limit: Int)
    }

    public let maximumLineLength: Int
    /// Bytes after the last line feed seen.
    private var pending: [UInt8] = []
    /// How much of `pending` is known to hold no line feed.
    private var scanned = 0
    private var failed = false

    public init(maximumLineLength: Int = ControlChannel.maximumLineLength) {
        self.maximumLineLength = max(1, maximumLineLength)
    }

    /// The bytes waiting for their line feed.
    public var bufferedByteCount: Int { pending.count }

    /// Adds bytes read from the stream and returns the lines they complete,
    /// in order, without line feeds or trailing carriage returns.
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        if failed { throw Failure.lineTooLong(limit: maximumLineLength) }
        pending.append(contentsOf: bytes)
        var lines: [Data] = []
        var lineStart = 0
        var index = scanned
        while index < pending.count {
            if pending[index] == 0x0A {
                if index - lineStart > maximumLineLength { return try fail() }
                if let line = Self.line(pending[lineStart..<index]) { lines.append(line) }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart > 0 { pending.removeFirst(lineStart) }
        scanned = pending.count
        if pending.count > maximumLineLength { return try fail() }
        return lines
    }

    /// At end of stream: the last line when it had no line feed (skipped if
    /// blank), and the framer is empty again.
    public mutating func finish() -> Data? {
        defer {
            pending.removeAll()
            scanned = 0
        }
        guard !failed, !pending.isEmpty else { return nil }
        return Self.line(pending[...])
    }

    private mutating func fail() throws -> [Data] {
        failed = true
        pending.removeAll()
        scanned = 0
        throw Failure.lineTooLong(limit: maximumLineLength)
    }

    private static func line(_ bytes: ArraySlice<UInt8>) -> Data? {
        var end = bytes.endIndex
        if end > bytes.startIndex, bytes[end - 1] == 0x0D { end -= 1 }
        let line = bytes[bytes.startIndex..<end]
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
        return Data(line)
    }
}
