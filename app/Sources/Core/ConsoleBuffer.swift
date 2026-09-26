import Foundation

/// The guest's serial console as lines of text.
///
/// Bytes arrive in arbitrary chunks, so a line can be split across two feeds
/// and a UTF-8 sequence across two reads. Terminal escapes are removed, `\r\n`
/// and bare `\r` end a line, and only the most recent `capacity` lines are
/// kept — a guest can print megabytes during boot.
public struct ConsoleBuffer: Sendable {
    public let capacity: Int
    public private(set) var lines: [String] = []
    /// The line still being written (no newline yet).
    public private(set) var pending = ""
    public private(set) var totalBytes = 0
    private var carry: [UInt8] = []
    private var lastWasCR = false

    public init(capacity: Int = 5000) {
        self.capacity = max(1, capacity)
    }

    /// Adds bytes; returns the lines they completed.
    @discardableResult
    public mutating func feed(_ bytes: [UInt8]) -> [String] {
        totalBytes += bytes.count
        var data = carry + bytes
        carry = Self.incompleteUTF8Suffix(of: data)
        if !carry.isEmpty { data.removeLast(carry.count) }

        var completed: [String] = []
        var current = [UInt8]()
        func flush() {
            let text = pending + Self.stripEscapes(String(decoding: current, as: UTF8.self))
            completed.append(text)
            pending = ""
            current.removeAll(keepingCapacity: true)
        }
        for byte in data {
            switch byte {
            case 0x0A: // \n — ends a line, unless it completes a \r\n already ended
                if lastWasCR { lastWasCR = false; continue }
                flush()
            case 0x0D:
                flush()
                lastWasCR = true
                continue
            default:
                current.append(byte)
            }
            lastWasCR = false
        }
        pending += Self.stripEscapes(String(decoding: current, as: UTF8.self))

        lines.append(contentsOf: completed)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        return completed
    }

    public mutating func clear() {
        lines.removeAll()
        pending = ""
        carry.removeAll()
        lastWasCR = false
    }

    /// Everything, for export: complete lines plus the pending one.
    public var text: String {
        (lines + (pending.isEmpty ? [] : [pending])).joined(separator: "\n")
    }

    /// Removes ANSI/VT100 control sequences (CSI, OSC) and other C0 controls
    /// except tab, so the text is safe to show and to search.
    public static func stripEscapes(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c.value {
            case 0x1B:
                guard let next = it.next() else { return String(out) }
                if next == "[" { // CSI: parameters, then a final byte 0x40–0x7E
                    while let p = it.next(), !(0x40...0x7E).contains(p.value) {}
                } else if next == "]" { // OSC: until BEL or ESC \
                    while let p = it.next() {
                        if p.value == 0x07 { break }
                        if p.value == 0x1B { _ = it.next(); break }
                    }
                }
            case 0x09:
                out.append(c)
            case 0x00...0x1F, 0x7F:
                continue
            default:
                out.append(c)
            }
        }
        return String(out)
    }

    /// Bytes at the end that start a UTF-8 sequence not yet complete.
    static func incompleteUTF8Suffix(of data: [UInt8]) -> [UInt8] {
        var i = data.count - 1
        var seen = 0
        while i >= 0, seen < 4 {
            let b = data[i]
            if b & 0xC0 == 0x80 { seen += 1; i -= 1; continue } // continuation byte
            let need: Int
            if b & 0xE0 == 0xC0 { need = 2 } else if b & 0xF0 == 0xE0 { need = 3 } else if b & 0xF8 == 0xF0 { need = 4 } else { return [] }
            return (seen + 1) < need ? Array(data[i...]) : []
        }
        return []
    }
}
