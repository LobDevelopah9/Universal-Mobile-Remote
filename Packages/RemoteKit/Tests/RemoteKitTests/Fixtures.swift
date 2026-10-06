import Foundation
import Testing

enum Fixtures {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    struct AndroidTV: Decodable {
        struct Pairing: Decodable {
            var code: String
            var mismatchedCode: String
            var secret: String
        }

        struct Message: Decodable {
            var name: String
            var direction: String
            var payload: String
            var framed: String?
        }

        var clientCertDer: String
        var serverCertDer: String
        var pairing: Pairing
        var messages: [Message]

        func message(_ name: String) throws -> Message {
            try #require(messages.first { $0.name == name }, "fixture message \(name)")
        }
    }

    static func androidTV() throws -> AndroidTV {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AndroidTV.self, from: data("androidtv", "json"))
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
