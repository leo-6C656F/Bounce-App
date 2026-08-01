import CryptoKit
import Foundation
import Network
import Security

/// Mints and stores the self-signed TLS certificate the desktop view serves.
///
/// ## Why this file is hand-rolled ASN.1
///
/// iOS has **no public API to create a certificate.** `SecKeyCreateRandomKey`
/// gives a keypair and `SecKeyCreateSignature` will sign bytes, but nothing in
/// Security.framework will assemble and sign an X.509 structure — so the DER is
/// built by hand here. There is no shortcut: bundling a certificate instead
/// would put its private key in the IPA where anyone can extract it, which
/// defeats the entire point of encrypting the connection.
///
/// ## What this buys, and what it doesn't
///
/// **Encryption without authentication.** Somebody passively sniffing the
/// network — the realistic threat on café or office wifi — can no longer read
/// transcripts, the pairing code, or audio off the wire. An *active* attacker who
/// can redirect traffic (ARP spoofing) can still present their own certificate,
/// and the browser will show the same warning the user has already been trained
/// to click through.
///
/// The mitigation for that is `fingerprint`, which is shown in Settings: the user
/// can compare it against what the browser reports before accepting. That is the
/// only authentication available, because browsers expose no API for a page to
/// check its own certificate.
///
/// ## Identity formation
///
/// `SecIdentityCreate` is private API. The public route is to put the private key
/// and its matching certificate in the keychain and let iOS pair them into a
/// `SecIdentity` on lookup — which is why both are stored rather than held in
/// memory.
enum SelfSignedCertificate {

    private static let keyTag = "com.teampandora.Bounce.desktopTLS.key"
    private static let certLabel = "com.teampandora.Bounce.desktopTLS.cert"
    private static let coveredNamesKey = "desktopTLSCoveredNames"
    private static let commonName = "Bounce on this iPhone"
    /// Long enough that it isn't a recurring chore, short enough to be a
    /// credential rather than a permanent fixture.
    private static let validityDays = 365

    enum Failure: LocalizedError {
        case keyGeneration(String)
        case publicKey
        case signing(String)
        case certificateStore(OSStatus)
        case identityMissing(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keyGeneration(let detail): return "Couldn't create an encryption key. \(detail)"
            case .publicKey: return "Couldn't read the new encryption key."
            case .signing(let detail): return "Couldn't sign the certificate. \(detail)"
            case .certificateStore(let status): return "Couldn't store the certificate (\(status))."
            case .identityMissing(let status): return "Couldn't load the stored certificate (\(status))."
            }
        }
    }

    // MARK: - Public surface

    /// The identity to hand Network.framework, minting a certificate if there
    /// isn't a usable one already.
    ///
    /// `names` are the hosts the browser might use — the phone's IPv4 addresses
    /// and its `.local` names. They go into the Subject Alternative Name, and a
    /// change in them (a new DHCP lease, a different network) forces a fresh
    /// certificate: a cert whose SAN doesn't cover the address in the URL is
    /// rejected by the browser even after the user accepts it once.
    static func identity(for names: Set<String>) throws -> sec_identity_t {
        let wanted = names.sorted().joined(separator: ",")
        let covered = UserDefaults.standard.string(forKey: coveredNamesKey)

        if covered == wanted, let existing = loadIdentity() {
            WebLog.log("reusing stored certificate for \(wanted)")
            return existing
        }

        // Loud on purpose. Minting generates an RSA keypair, and a name set that
        // changes between launches means doing it repeatedly — which also
        // invalidates every browser's stored exception. If this line appears on
        // every start, the name set is unstable and that is the bug to fix, not
        // the keygen cost.
        WebLog.log("minting certificate — covered=\(covered ?? "none") wanted=\(wanted)")
        discard()
        try mint(names: names)
        WebLog.log("minted certificate \(fingerprint ?? "?")")
        UserDefaults.standard.set(wanted, forKey: coveredNamesKey)

        guard let identity = loadIdentity() else {
            throw Failure.identityMissing(errSecItemNotFound)
        }
        return identity
    }

    /// SHA-256 of the stored certificate, colon-separated hex — the same digest
    /// a browser shows as the certificate's fingerprint, so the two can be
    /// compared by eye.
    static var fingerprint: String? {
        guard let der = storedCertificateDER() else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Drop the key and certificate. The next start mints a new pair, which
    /// invalidates every browser exception — the "forget" button in Settings.
    static func discard() {
        SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(keyTag.utf8),
        ] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certLabel,
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: coveredNamesKey)
    }

    // MARK: - Minting

    /// Build and sign the certificate. Split out from storage so the DER can be
    /// validated on its own — hand-written ASN.1 fails silently, producing bytes
    /// that a `SecCertificate` will happily wrap and no browser will accept.
    static func certificateDER(signedBy privateKey: SecKey, names: Set<String>) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw Failure.publicKey }

        let tbs = try tbsCertificate(publicKeyPKCS1: [UInt8](pkcs1), names: names)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data? else {
            throw Failure.signing(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        return Data(DER.sequence([
            tbs,
            DER.sequence([DER.oid(OID.sha256WithRSA), DER.null()]),
            DER.bitString([UInt8](signature)),
        ]))
    }

    private static func mint(names: Set<String>) throws {
        let privateKey = try makeKeyPair()
        let certificate = try certificateDER(signedBy: privateKey, names: names)

        guard let secCert = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw Failure.certificateStore(errSecDecode)
        }
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: certLabel,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Failure.certificateStore(status)
        }
    }

    private static func makeKeyPair() throws -> SecKey {
        // RSA rather than EC: `SecKeyCopyExternalRepresentation` hands back a
        // PKCS#1 `RSAPublicKey` that drops straight into a SubjectPublicKeyInfo,
        // and PKCS#1 v1.5 signatures need no further wrapping. Keygen cost is
        // paid once and then cached in the keychain.
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Data(keyTag.utf8),
                // The server only runs in the foreground, so it never needs the
                // key while locked. Same posture as the Plaud credentials.
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure.keyGeneration(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return key
    }

    // MARK: - Certificate body

    private static func tbsCertificate(publicKeyPKCS1: [UInt8], names: Set<String>) throws -> [UInt8] {
        // Serial must be a positive INTEGER. 16 random bytes with the top bit
        // cleared avoids needing a leading zero pad.
        var serial = [UInt8](repeating: 0, count: 16)
        for index in serial.indices { serial[index] = UInt8.random(in: 0...255) }
        serial[0] &= 0x7F
        if serial[0] == 0 { serial[0] = 1 }

        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])]),
            DER.set([DER.sequence([DER.oid(OID.organization), DER.utf8String("Bounce")])]),
        ])

        // Backdate slightly so a browser whose clock is behind the phone's
        // doesn't reject a certificate that isn't valid yet.
        let notBefore = Date().addingTimeInterval(-3600)
        let notAfter = Date().addingTimeInterval(Double(validityDays) * 86400)

        return DER.sequence([
            DER.explicit(tag: 0, DER.integer([2])),              // v3
            DER.integer(serial),
            DER.sequence([DER.oid(OID.sha256WithRSA), DER.null()]),
            name,                                                // issuer == subject
            DER.sequence([DER.utcTime(notBefore), DER.utcTime(notAfter)]),
            name,
            DER.sequence([
                DER.sequence([DER.oid(OID.rsaEncryption), DER.null()]),
                DER.bitString(publicKeyPKCS1),
            ]),
            DER.explicit(tag: 3, DER.sequence(extensions(for: names))),
        ])
    }

    private static func extensions(for names: Set<String>) -> [[UInt8]] {
        // Subject Alternative Name. A browser validates the URL's host against
        // *this*, not against the Common Name — modern browsers ignore CN
        // entirely — so an IP the user might type has to be in here as an
        // iPAddress, not as a dNSName.
        var generalNames: [[UInt8]] = []
        for name in names.sorted() {
            if let packed = ipv4Bytes(name) {
                generalNames.append(DER.implicit(tag: 7, packed))       // iPAddress
            } else {
                generalNames.append(DER.implicit(tag: 2, [UInt8](name.utf8)))  // dNSName
            }
        }

        return [
            extensionEntry(OID.subjectAltName, critical: false,
                           value: DER.sequence(generalNames)),
            extensionEntry(OID.basicConstraints, critical: true,
                           value: DER.sequence([])),                    // cA = false
            // digitalSignature + keyEncipherment; 5 unused trailing bits.
            extensionEntry(OID.keyUsage, critical: true,
                           value: DER.encode(tag: 0x03, [0x05, 0xA0])),
            extensionEntry(OID.extendedKeyUsage, critical: false,
                           value: DER.sequence([DER.oid(OID.serverAuth)])),
        ]
    }

    private static func extensionEntry(_ oid: [UInt8], critical: Bool, value: [UInt8]) -> [UInt8] {
        var parts: [[UInt8]] = [DER.oid(oid)]
        if critical { parts.append(DER.boolean(true)) }   // DEFAULT FALSE — omit when false
        parts.append(DER.octetString(value))
        return DER.sequence(parts)
    }

    private static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    // MARK: - Keychain reads

    private static func loadIdentity() -> sec_identity_t? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let identity = item as! SecIdentity? else { return nil }
        return sec_identity_create(identity)
    }

    private static func storedCertificateDER() -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let certificate = item as! SecCertificate? else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }
}

// MARK: - OIDs

/// Object identifiers as their DER *content* bytes, i.e. without the `06 len`
/// header — `DER.oid` adds that.
private enum OID {
    static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let organization: [UInt8] = [0x55, 0x04, 0x0A]
    static let subjectAltName: [UInt8] = [0x55, 0x1D, 0x11]
    static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13]
    static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F]
    static let extendedKeyUsage: [UInt8] = [0x55, 0x1D, 0x25]
    static let serverAuth: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
}

// MARK: - DER

/// The sliver of DER needed to write one X.509 certificate. Not a general
/// encoder — no indefinite lengths, no parsing.
private enum DER {

    static func encode(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    /// Definite-form length: short form below 128, otherwise a byte count
    /// followed by big-endian bytes.
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        encode(tag: 0x30, items.flatMap { $0 })
    }
    static func set(_ items: [[UInt8]]) -> [UInt8] {
        encode(tag: 0x31, items.flatMap { $0 })
    }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        // A leading byte ≥ 0x80 would read as negative in two's complement.
        let padded = (bytes.first ?? 0) >= 0x80 ? [0x00] + bytes : bytes
        return encode(tag: 0x02, padded)
    }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        encode(tag: 0x03, [0x00] + bytes)   // 0 unused trailing bits
    }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        encode(tag: 0x04, bytes)
    }
    static func null() -> [UInt8] { [0x05, 0x00] }
    static func oid(_ content: [UInt8]) -> [UInt8] { encode(tag: 0x06, content) }
    static func utf8String(_ text: String) -> [UInt8] { encode(tag: 0x0C, [UInt8](text.utf8)) }
    static func boolean(_ value: Bool) -> [UInt8] { [0x01, 0x01, value ? 0xFF : 0x00] }

    /// `[n] EXPLICIT` — a constructed context-specific tag wrapping the encoding.
    static func explicit(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        encode(tag: 0xA0 | tag, content)
    }
    /// `[n] IMPLICIT` — the context tag *replaces* the base type's tag, which is
    /// how `GeneralName`'s dNSName and iPAddress are encoded.
    static func implicit(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        encode(tag: 0x80 | tag, content)
    }

    /// X.509 `Time` is UTCTime for years before 2050, `YYMMDDHHMMSSZ`.
    static func utcTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            (parts.year ?? 2000) % 100, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return encode(tag: 0x17, [UInt8](text.utf8))
    }
}
