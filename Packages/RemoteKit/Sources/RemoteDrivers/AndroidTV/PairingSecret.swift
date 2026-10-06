import CryptoKit
import Foundation
import RemoteCore
import SwiftASN1

/// An RSA public key's modulus and exponent as minimal big-endian bytes.
struct RSAPublicNumbers: Sendable, Equatable {
    var modulus: [UInt8]
    var exponent: [UInt8]

    /// Accepts PKCS#1 `RSAPublicKey` (what `SecKeyCopyExternalRepresentation` returns)
    /// or X.509 `SubjectPublicKeyInfo` DER.
    init(modulus: [UInt8], exponent: [UInt8]) {
        self.modulus = modulus
        self.exponent = exponent
    }

    init(publicKeyDER: [UInt8]) throws {
        self = try Self.parse(publicKeyDER)
    }

    private static func parse(_ der: [UInt8]) throws -> RSAPublicNumbers {
        let root = try DER.parse(der)
        guard case .constructed(let children) = root.content else {
            throw DriverError.protocolError("RSA key is not a SEQUENCE")
        }
        let nodes = Array(children)
        if nodes.count == 2, nodes[0].identifier == .sequence, nodes[1].identifier == .bitString {
            // SubjectPublicKeyInfo: unwrap the BIT STRING holding the PKCS#1 key.
            let bits = try ASN1BitString(derEncoded: nodes[1])
            return try parse(Array(bits.bytes))
        }
        guard nodes.count == 2 else { throw DriverError.protocolError("RSA key has \(nodes.count) fields") }
        return RSAPublicNumbers(modulus: try unsignedInteger(nodes[0]), exponent: try unsignedInteger(nodes[1]))
    }

    /// Reads the public key out of a DER X.509 certificate.
    init(certificateDER: [UInt8]) throws {
        let root = try DER.parse(certificateDER)
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
        guard case .constructed(let certFields) = root.content,
              let tbs = Array(certFields).first,
              case .constructed(let tbsFields) = tbs.content
        else { throw DriverError.protocolError("Malformed certificate") }
        // TBSCertificate: [0] version?, serial, signature, issuer, validity, subject, subjectPublicKeyInfo, …
        var fields = Array(tbsFields)
        if fields.first?.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) {
            fields.removeFirst()
        }
        guard fields.count > 5 else { throw DriverError.protocolError("Malformed certificate") }
        try self.init(publicKeyDER: Array(fields[5].encodedBytes))
    }

    private static func unsignedInteger(_ node: ASN1Node) throws -> [UInt8] {
        guard node.identifier == .integer, case .primitive(let bytes) = node.content else {
            throw DriverError.protocolError("Expected INTEGER")
        }
        var value = Array(bytes)
        while value.count > 1, value.first == 0 { value.removeFirst() }
        return value
    }
}

/// The Polo pairing secret: SHA-256 over both RSA keys and the last two bytes of the
/// code. The code's first byte must equal the hash's first byte, which lets the
/// client reject a mistyped code before sending anything.
enum PairingSecret {
    static func compute(client: RSAPublicNumbers, server: RSAPublicNumbers, code: String) throws -> Data {
        let codeBytes = try decode(code)
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: codeBytes.dropFirst())
        let digest = Data(hash.finalize())
        guard digest.first == codeBytes.first else { throw DriverError.pairingCodeMismatch }
        return digest
    }

    static func decode(_ code: String) throws -> [UInt8] {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isHexDigit) else {
            throw DriverError.pairingCodeMismatch
        }
        var bytes: [UInt8] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            bytes.append(UInt8(trimmed[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }
}
