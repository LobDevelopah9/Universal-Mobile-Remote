import Foundation
import RemoteCore
import Security
import SwiftASN1
import X509

/// The app-wide TLS client identity for Android TV: an RSA-2048 key that never leaves
/// Keychain plus a self-signed certificate for it. The TV remembers this certificate
/// after pairing, so it has to stay the same for the life of the install.
struct ClientIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateDER: Data
    let publicNumbers: RSAPublicNumbers

    static let keyTag = Data("com.example.remote.androidtv.client-key".utf8)
    static let certificateLabel = "Remote Android TV client"

    private static let cache = Locked<ClientIdentity?>(nil)

    static func shared() throws -> ClientIdentity {
        try cache.withLock { cached in
            if let cached { return cached }
            let identity = try loadOrCreate()
            cached = identity
            return identity
        }
    }

    private static func loadOrCreate() throws -> ClientIdentity {
        if let identity = try findIdentity() {
            return try ClientIdentity(identity: identity)
        }
        let key = try findPrivateKey() ?? createPrivateKey()
        let der = try SelfSignedCertificate.make(privateKey: key, commonName: AndroidTVMessages.serviceName)
        try storeCertificate(der)
        guard let identity = try findIdentity() else {
            throw DriverError.protocolError("Couldn't create the TLS client identity")
        }
        return try ClientIdentity(identity: identity)
    }

    private init(identity: SecIdentity) throws {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DriverError.protocolError("Keychain identity has no certificate (\(status))")
        }
        self.identity = identity
        certificateDER = SecCertificateCopyData(certificate) as Data
        publicNumbers = try RSAPublicNumbers(certificateDER: Array(certificateDER))
    }

    private static var platformAttributes: [String: Any] {
        #if os(macOS)
        [kSecUseDataProtectionKeychain as String: true]
        #else
        [:]
        #endif
    }

    private static func findIdentity() throws -> SecIdentity? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certificateLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query.merge(platformAttributes) { $1 }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { return nil }
            return (result as! SecIdentity)
        case errSecItemNotFound:
            return nil
        default:
            throw DriverError.protocolError("Keychain identity lookup failed (\(status))")
        }
    }

    private static func findPrivateKey() throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        query.merge(platformAttributes) { $1 }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else { return nil }
            return (result as! SecKey)
        case errSecItemNotFound:
            return nil
        default:
            throw DriverError.protocolError("Keychain key lookup failed (\(status))")
        }
    }

    private static func createPrivateKey() throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        privateAttributes.merge(platformAttributes) { $1 }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        attributes.merge(platformAttributes) { $1 }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw DriverError.protocolError("Key generation failed")
        }
        return key
    }

    private static func storeCertificate(_ der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw DriverError.protocolError("Generated certificate is invalid")
        }
        var delete: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
        ]
        delete.merge(platformAttributes) { $1 }
        SecItemDelete(delete as CFDictionary)

        var add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certificateLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        add.merge(platformAttributes) { $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DriverError.protocolError("Couldn't store the client certificate (\(status))")
        }
    }
}

enum SelfSignedCertificate {
    /// A v3 self-signed certificate (SHA-256 with RSA), valid for ten years.
    static func make(privateKey: SecKey, commonName: String, now: Date = Date()) throws -> Data {
        let key = try Certificate.PrivateKey(privateKey)
        let name = try DistinguishedName { CommonName(commonName) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: key
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }
}
