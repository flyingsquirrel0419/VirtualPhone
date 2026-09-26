import Foundation

/// JSON as QMP sends it. Decoded with JSONDecoder, which — unlike
/// JSONSerialization — tells booleans from numbers on every platform.
public indirect enum QMPValue: Equatable, Sendable, Decodable {
    case string(String), number(Double), bool(Bool), null
    case array([QMPValue]), object([String: QMPValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([QMPValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: QMPValue].self)) }
    }

    public subscript(key: String) -> QMPValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
}

/// QEMU Machine Protocol: newline-delimited JSON over a socket.
public enum QMPMessage: Equatable, Sendable {
    case greeting(version: String)
    case success(QMPValue)
    case error(klass: String, description: String)
    case event(name: String, data: QMPValue?)
}

public enum QMPCodec {
    public enum DecodeError: Error, Equatable { case notJSON, unknown(String) }

    /// One command line, including the newline. Arguments are strings or
    /// numbers, which is all VirtualPhone sends.
    public static func command(_ name: String, arguments: [String: String] = [:]) -> Data {
        var object: [String: Any] = ["execute": name]
        if !arguments.isEmpty { object["arguments"] = arguments }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> QMPMessage {
        guard case .object(let o)? = try? JSONDecoder().decode(QMPValue.self, from: line) else {
            throw DecodeError.notJSON
        }
        if let qmp = o["QMP"] {
            let v = qmp["version"]?["qemu"]
            let parts = ["major", "minor", "micro"].map { String(v?[$0]?.intValue ?? 0) }
            return .greeting(version: parts.joined(separator: "."))
        }
        if let name = o["event"]?.stringValue { return .event(name: name, data: o["data"]) }
        if let error = o["error"] {
            return .error(klass: error["class"]?.stringValue ?? "?", description: error["desc"]?.stringValue ?? "")
        }
        if let ret = o["return"] { return .success(ret) }
        throw DecodeError.unknown(String(decoding: line.prefix(200), as: UTF8.self))
    }

    /// The `status` field of a `query-status` reply ("running", "paused", …).
    public static func status(from reply: QMPMessage) -> String? {
        if case .success(let value) = reply { return value["status"]?.stringValue }
        return nil
    }
}
