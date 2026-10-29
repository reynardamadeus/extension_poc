//
//  SecureLink.swift
//  Shared by the Mac app and the Watch app.
//
//  Pairing and encryption for the Bluetooth link:
//  • Pairing: both devices create a key pair and swap public keys (P-256 ECDH).
//    Each computes the same secret, a 256-bit key and a 4-digit code from it.
//    The user checks the codes match and approves on the Mac (protects
//    against a device in the middle).
//  • Every reconnect: the Mac sends a random challenge; the watch answers with
//    an HMAC made with the shared key. No answer → no data.
//  • All error lists and commands are encrypted with AES-GCM.
//

import CryptoKit
import Foundation
import Security

nonisolated enum SecureLink {

    static func newKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    static func publicKeyString(_ key: P256.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Shared key + 4-digit comparison code. Both devices get the same values.
    static func derive(myKey: P256.KeyAgreement.PrivateKey,
                       theirPublicKey: String) -> (key: SymmetricKey, code: String)? {
        guard let data = Data(base64Encoded: theirPublicKey),
              let theirs = try? P256.KeyAgreement.PublicKey(rawRepresentation: data),
              let secret = try? myKey.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let salt = Data("ErrorRelay pairing v1".utf8)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("key".utf8), outputByteCount: 32)
        let codeBytes = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                       sharedInfo: Data("code".utf8), outputByteCount: 4)
        let number = codeBytes.withUnsafeBytes { raw in
            raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        } % 10_000
        return (key, String(format: "%04d", number))
    }

    // MARK: Encryption

    static func seal(_ plaintext: Data, key: SymmetricKey) -> String? {
        (try? AES.GCM.seal(plaintext, using: key))?.combined?.base64EncodedString()
    }

    static func open(_ text: String, key: SymmetricKey) -> Data? {
        guard let data = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: Challenge / response

    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    static func proof(nonce: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)).base64EncodedString()
    }

    static func verify(proof: String, nonce: String, key: SymmetricKey) -> Bool {
        guard let data = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(data, authenticating: Data(nonce.utf8), using: key)
    }
}

/// Stores pairing keys in the Keychain.
nonisolated enum KeyStore {
    private static let service = "ErrorRelay"

    static func save(_ key: SymmetricKey, account: String) {
        delete(account: account)
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    /// Small text values (the watch's ID): kept in the Keychain because it survives
    /// reinstalling the app, unlike UserDefaults.
    static func saveString(_ text: String, account: String) {
        save(SymmetricKey(data: Data(text.utf8)), account: account)
    }

    static func loadString(account: String) -> String? {
        load(account: account).map { key in key.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
