import Foundation
import CryptoKit
import Security
import LocalAuthentication

enum UpdateSigningKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.netunstick.update-signing",
        kSecAttrAccount as String: "ed25519-release-v1",
    ]

    static func load(create: Bool = false) throws -> Curve25519.Signing.PrivateKey {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        // A locked or inaccessible Keychain must fail promptly, never leave a headless
        // release job indefinitely waiting for a hidden system dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound, create else {
            throw NSError(domain: "NetUnstick.UpdateSigningKey", code: Int(status))
        }
        let key = Curve25519.Signing.PrivateKey()
        var item = query
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrLabel as String] = "NetUnstick Update Signing (Ed25519)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: "NetUnstick.UpdateSigningKey", code: Int(added)) }
        return key
    }
}
