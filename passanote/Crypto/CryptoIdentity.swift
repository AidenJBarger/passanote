import Foundation
import CryptoKit
import Security

/// Stable local identity:
/// - Curve25519 static keypair for Noise — Keychain (kSecAttrAccessibleAfterFirstUnlock
///   so background BLE wakes can use it)
/// - Peer UUID + nickname — UserDefaults
final class CryptoIdentity {
    static let shared = CryptoIdentity()

    private static let keychainService = "com.passanote.noise"
    private static let keychainAccount = "static-key"
    private static let peerIDDefaultsKey = "passanote.peerID"
    static let nicknameDefaultsKey = "passanote.nickname"
    static let nicknameDraftDefaultsKey = "passanote.nickname.draft"

    let peerID: PeerID
    let staticKey: Curve25519.KeyAgreement.PrivateKey

    var staticPublicKeyData: Data {
        staticKey.publicKey.rawRepresentation
    }

    /// Committed nickname — set when the user finishes the setup screen.
    var nickname: String {
        get { UserDefaults.standard.string(forKey: Self.nicknameDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.nicknameDefaultsKey) }
    }

    /// In-progress nickname while typing; autosaved without starting Bluetooth.
    var nicknameDraft: String {
        get { UserDefaults.standard.string(forKey: Self.nicknameDraftDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.nicknameDraftDefaultsKey) }
    }

    private init() {
        // Peer UUID: generated once, stored in UserDefaults
        if let stored = UserDefaults.standard.string(forKey: Self.peerIDDefaultsKey),
           let peerID = PeerID(string: stored) {
            self.peerID = peerID
        } else {
            let peerID = PeerID()
            UserDefaults.standard.set(peerID.id, forKey: Self.peerIDDefaultsKey)
            self.peerID = peerID
        }

        // Static Noise keypair: generated once, stored in Keychain
        if let keyData = Self.loadKeyData(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) {
            self.staticKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            Self.storeKeyData(key.rawRepresentation)
            self.staticKey = key
        }
    }

    // MARK: - Keychain

    private static func loadKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func storeKeyData(_ data: Data) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
