// DeepIDVCore › Device

import Foundation
import Security

/// A stable, opaque per-device identifier for the anti-cheat check's
/// multi-account linkage (`checkAntiCheat(deviceFingerprint:)`).
///
/// Minted once as a random UUID and persisted in the keychain, so it survives
/// app reinstalls (keychain items outlive app deletion) while staying
/// per-device (`ThisDeviceOnly` accessibility — a backup restored onto a new
/// phone reads as a new device). It is **not** derived from hardware or user
/// data: no permissions, no fingerprinting, just a first-party identifier for
/// fraud prevention — declare it as a collected device ID with the
/// fraud-prevention purpose in your privacy manifest.
///
/// Treat it as linkage *signal*, not security: a wiped device or a cleared
/// keychain mints a fresh value, and the backend weighs it alongside the
/// face-dedup check rather than trusting it alone.
///
/// Opt-in — the SDK never attaches it automatically:
///
/// ```swift
/// let result = try await client.checkAntiCheat(
///     sessionID: sessionID, image: image,
///     deviceFingerprint: DeviceFingerprint.current())
/// ```
public enum DeviceFingerprint {
    /// The device's stable fingerprint. Resolved once per process (reading or
    /// minting the keychain value) and cached; never throws.
    public static func current() -> String {
        cached
    }

    /// One-time resolution via Swift's thread-safe `static let` init. Also
    /// keeps the value stable for the process even when keychain persistence
    /// failed (the minted value is simply re-minted next launch).
    private static let cached: String = resolve(store: SystemKeychainStore())

    static let service = "com.deepidv.device-fingerprint"
    static let account = "device-fingerprint"

    /// The mint-once logic, seam-injected for hermetic tests: stored value →
    /// return it; absent/undecodable → mint a UUID and best-effort persist;
    /// lost first-launch race (`duplicateItem`) → the winner's value is
    /// canonical.
    package static func resolve(store: KeychainStore) -> String {
        if let value = storedValue(in: store) { return value }
        let minted = UUID().uuidString
        do {
            try store.write(service: service, account: account, data: Data(minted.utf8))
        } catch KeychainStoreError.duplicateItem {
            if let value = storedValue(in: store) { return value }
        } catch {
            // Best-effort persistence — fall through and return the minted
            // value, stable for this process via `cached`.
        }
        return minted
    }

    private static func storedValue(in store: KeychainStore) -> String? {
        guard let data = try? store.read(service: service, account: account),
            let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }
}

/// Errors a ``KeychainStore`` can raise. `duplicateItem` signals the
/// first-launch race: another thread/process wrote the item between our read
/// and our write.
package enum KeychainStoreError: Error, Equatable {
    case duplicateItem
    case writeFailed(status: OSStatus)
}

/// Minimal keychain seam so ``DeviceFingerprint``'s mint-once logic tests
/// hermetically — same pattern as `HTTPTransport`.
package protocol KeychainStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
}

/// Production store: generic-password items via `SecItem`. Read failures are
/// treated as "absent" (best-effort — the caller re-mints rather than
/// crashing a signup over keychain weather).
struct SystemKeychainStore: KeychainStore {
    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(service: String, account: String, data: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Device-only on purpose: a backup restored onto NEW hardware
            // should mint a fresh fingerprint.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeychainStoreError.duplicateItem }
        guard status == errSecSuccess else {
            throw KeychainStoreError.writeFailed(status: status)
        }
    }
}
