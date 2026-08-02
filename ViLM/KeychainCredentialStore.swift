// KeychainCredentialStore.swift
// Keychain-backed PluginCredentialStore (epic D6).
//
// Lives in the app target rather than LibraryCore: Keychain access is entangled
// with entitlements and the code-signing identity, and LibraryCore's tests run
// in environments that have neither. Core declares the protocol and defaults to
// an in-memory store; this supplies the real one.
//
// A credential is stored per plugin id, NEVER in UserDefaults, never in a
// repository, never in a build.

import Foundation
import Security
import LibraryCore

final class KeychainCredentialStore: PluginCredentialStore, @unchecked Sendable {

    /// Namespaces these entries so they cannot collide with anything else the
    /// app stores, and so a plugin credential is identifiable in Keychain Access.
    private let service: String

    init(service: String = "com.vilm.plugin-credential") {
        self.service = service
    }

    private func query(for pluginId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pluginId,
        ]
    }

    func credential(for pluginId: String) -> String? {
        var query = query(for: pluginId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func setCredential(_ value: String?, for pluginId: String) {
        guard let value, !value.isEmpty else {
            removeCredential(for: pluginId)
            return
        }
        let data = Data(value.utf8)
        let query = query(for: pluginId)

        // Update in place when an entry exists; SecItemAdd would fail with
        // errSecDuplicateItem and silently leave the old credential behind.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // Available after first unlock, and not synced to other devices —
            // a credential belongs to this install, not to an iCloud account.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func removeCredential(for pluginId: String) {
        SecItemDelete(query(for: pluginId) as CFDictionary)
    }
}
