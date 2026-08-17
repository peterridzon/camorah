import Foundation

/// Minimal protobuf wire-format codec.
///
/// The Orah camera speaks proto2 (see `proto/CamAPI.proto`), but we only ever
/// exchange a handful of small messages. Hand-rolling the wire format keeps the
/// app free of a `protoc` toolchain and a swift-protobuf dependency — the whole
/// contract lives in `CamAPI.swift` next door.

enum WireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

// MARK: - Writer

struct ProtoWriter {
    private(set) var data = Data()

    private mutating func tag(_ field: Int, _ type: WireType) {
        appendVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, .varint)
        appendVarint(value)
    }

    mutating func varint(_ field: Int, _ value: Int) {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, .lengthDelimited)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Writes an embedded message; the body builds it into a nested writer.
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        body(&nested)
        bytes(field, nested.data)
    }

    static func build(_ body: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        body(&w)
        return w.data
    }
}

// MARK: - Reader

enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)

    var asUInt64: UInt64? {
        if case .varint(let v) = self { return v }
        return nil
    }

    var asInt: Int? {
        guard let v = asUInt64 else { return nil }
        return Int(Int64(bitPattern: v))
    }

    var asData: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }

    var asString: String? {
        guard let d = asData else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum ProtoError: Error, CustomStringConvertible {
    case truncated
    case unknownWireType(UInt8)
    case malformedVarint

    var description: String {
        switch self {
        case .truncated: return "protobuf message truncated"
        case .unknownWireType(let t): return "unknown protobuf wire type \(t)"
        case .malformedVarint: return "malformed varint"
        }
    }
}

struct ProtoReader {
    /// Walks every field in `data`, handing each to `visit` as (fieldNumber, value).
    /// Unknown fields are surfaced too — callers simply ignore what they don't need,
    /// which is exactly proto2's forward-compatibility rule.
    static func walk(_ data: Data, _ visit: (Int, ProtoValue) throws -> Void) throws {
        var i = data.startIndex
        let end = data.endIndex

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < end else { throw ProtoError.truncated }
                guard shift < 64 else { throw ProtoError.malformedVarint }
                let byte = data[i]
                i = data.index(after: i)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return result
        }

        while i < end {
            let key = try readVarint()
            let field = Int(key >> 3)
            guard let wire = WireType(rawValue: UInt8(key & 0x07)) else {
                throw ProtoError.unknownWireType(UInt8(key & 0x07))
            }

            switch wire {
            case .varint:
                try visit(field, .varint(try readVarint()))

            case .fixed64:
                guard data.index(i, offsetBy: 8, limitedBy: end) != nil else { throw ProtoError.truncated }
                var v: UInt64 = 0
                for shift in stride(from: 0, to: 64, by: 8) {
                    v |= UInt64(data[i]) << UInt64(shift)
                    i = data.index(after: i)
                }
                try visit(field, .fixed64(v))

            case .fixed32:
                guard data.index(i, offsetBy: 4, limitedBy: end) != nil else { throw ProtoError.truncated }
                var v: UInt32 = 0
                for shift in stride(from: 0, to: 32, by: 8) {
                    v |= UInt32(data[i]) << UInt32(shift)
                    i = data.index(after: i)
                }
                try visit(field, .fixed32(v))

            case .lengthDelimited:
                let length = Int(try readVarint())
                guard length >= 0, let stop = data.index(i, offsetBy: length, limitedBy: end) else {
                    throw ProtoError.truncated
                }
                try visit(field, .bytes(Data(data[i..<stop])))
                i = stop
            }
        }
    }
}
