import Foundation
import RemoteCore

/// Android TV Remote v2 frames every protobuf message with a varint length prefix.
/// Reads can split anywhere, including inside the varint, so this buffers.
struct VarintFramer: Sendable {
    static let maximumMessageSize = 1 << 20

    private var buffer = Data()

    static func frame(_ payload: Data) -> Data {
        var out = encodeVarint(UInt64(payload.count))
        out.append(payload)
        return out
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    /// Appends received bytes and returns every message that is now complete.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while true {
            guard let (length, headerSize) = try Self.decodeVarint(buffer) else { break }
            guard length <= Self.maximumMessageSize else {
                throw DriverError.protocolError("Frame too large: \(length) bytes")
            }
            let start = buffer.startIndex + headerSize
            guard buffer.count - headerSize >= length else { break }
            messages.append(Data(buffer[start..<(start + length)]))
            buffer = Data(buffer[(start + length)...])
        }
        return messages
    }

    /// Returns nil when more bytes are needed.
    static func decodeVarint(_ data: Data) throws -> (value: Int, size: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            result |= UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 {
                return (Int(result), index - data.startIndex)
            }
            shift += 7
            if shift > 28 { throw DriverError.protocolError("Corrupt frame length") }
        }
        return nil
    }
}
