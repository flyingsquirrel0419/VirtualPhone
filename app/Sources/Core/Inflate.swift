import Foundation

/// Raw DEFLATE (RFC 1951) decompression, as ZIP stores it.
///
/// Small and dependency-free so the IPA inspector runs the same on iOS and in
/// Linux tests. Only used on a few metadata files per archive (Info.plist, the
/// head of the executable), never on whole apps, so clarity beats speed.
public enum Inflate {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        case invalidCode
        case invalidDistance
        case outputLimit
    }

    /// Decompresses `input`; stops with `.outputLimit` past `limit` bytes, and
    /// returns early once `stopAfter` bytes are available (for header peeks).
    public static func decompress(_ input: [UInt8], limit: Int = 64 << 20, stopAfter: Int? = nil) throws -> [UInt8] {
        var reader = BitReader(input)
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, input.count * 4))
        var last = false
        while !last {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0: try stored(&reader, &out)
            case 1: try block(&reader, &out, lit: fixedLiteral, dist: fixedDistance, limit: limit)
            case 2:
                let (lit, dist) = try dynamicTables(&reader)
                try block(&reader, &out, lit: lit, dist: dist, limit: limit)
            default: throw Failure.invalidBlockType
            }
            if out.count > limit { throw Failure.outputLimit }
            if let stop = stopAfter, out.count >= stop { return Array(out.prefix(stop)) }
        }
        return out
    }

    // MARK: - Bits

    struct BitReader {
        let data: [UInt8]
        var pos = 0
        var bitBuf: UInt32 = 0
        var bitCount = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < data.count else { throw Failure.truncated }
                bitBuf |= UInt32(data[pos]) << UInt32(bitCount)
                pos += 1
                bitCount += 8
            }
            let value = Int(bitBuf & ((1 << UInt32(n)) - 1))
            bitBuf >>= UInt32(n)
            bitCount -= n
            return value
        }

        mutating func alignToByte() {
            bitBuf = 0
            bitCount = 0
        }
    }

    // MARK: - Huffman

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
        }

        /// Canonical decoding, one bit at a time (puff.c's approach).
        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try r.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalidCode
        }
    }

    static let fixedLiteral: Huffman = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return Huffman(lengths: l)
    }()
    static let fixedDistance = Huffman(lengths: [Int](repeating: 5, count: 30))

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func stored(_ r: inout BitReader, _ out: inout [UInt8]) throws {
        r.alignToByte()
        guard r.pos + 4 <= r.data.count else { throw Failure.truncated }
        let len = Int(r.data[r.pos]) | Int(r.data[r.pos + 1]) << 8
        let nlen = Int(r.data[r.pos + 2]) | Int(r.data[r.pos + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw Failure.invalidStoredLength }
        r.pos += 4
        guard r.pos + len <= r.data.count else { throw Failure.truncated }
        out.append(contentsOf: r.data[r.pos..<(r.pos + len)])
        r.pos += len
    }

    static func block(_ r: inout BitReader, _ out: inout [UInt8], lit: Huffman, dist: Huffman, limit: Int) throws {
        while true {
            let symbol = try lit.decode(&r)
            if symbol < 256 {
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < lengthBase.count else { throw Failure.invalidCode }
                let length = lengthBase[li] + (try r.bits(lengthExtra[li]))
                let di = try dist.decode(&r)
                guard di < distBase.count else { throw Failure.invalidDistance }
                let distance = distBase[di] + (try r.bits(distExtra[di]))
                guard distance <= out.count else { throw Failure.invalidDistance }
                let start = out.count - distance
                for i in 0..<length { out.append(out[start + i]) }
            }
            if out.count > limit { throw Failure.outputLimit }
        }
    }

    static func dynamicTables(_ r: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = try r.bits(5) + 257
        let hdist = try r.bits(5) + 1
        let hclen = try r.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { codeLengths[order[i]] = try r.bits(3) }
        let lencode = Huffman(lengths: codeLengths)

        var lengths: [Int] = []
        while lengths.count < hlit + hdist {
            let sym = try lencode.decode(&r)
            switch sym {
            case 0..<16: lengths.append(sym)
            case 16:
                guard let prev = lengths.last else { throw Failure.invalidCode }
                lengths += [Int](repeating: prev, count: 3 + (try r.bits(2)))
            case 17: lengths += [Int](repeating: 0, count: 3 + (try r.bits(3)))
            default: lengths += [Int](repeating: 0, count: 11 + (try r.bits(7)))
            }
        }
        guard lengths.count == hlit + hdist else { throw Failure.invalidCode }
        return (Huffman(lengths: Array(lengths[0..<hlit])), Huffman(lengths: Array(lengths[hlit...])))
    }
}
