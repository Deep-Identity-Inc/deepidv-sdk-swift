import Foundation
import Testing

@testable import DeepIDVCore

// DeviceFingerprint.resolve(store:) — the mint-once keychain logic, driven
// against an in-memory fake. The system keychain path is exercised only on
// device, same testing stance as the camera code.

private final class FakeKeychainStore: KeychainStore, @unchecked Sendable {
    var stored: [String: Data] = [:]
    var failWrites = false
    var duplicateOnWrite = false
    private(set) var writeCount = 0

    private func key(_ service: String, _ account: String) -> String {
        "\(service)/\(account)"
    }

    func read(service: String, account: String) throws -> Data? {
        stored[key(service, account)]
    }

    func write(service: String, account: String, data: Data) throws {
        writeCount += 1
        if failWrites { throw KeychainStoreError.writeFailed(status: -1) }
        if duplicateOnWrite {
            // Simulate losing the first-launch race: a winner wrote between
            // our read and our write.
            stored[key(service, account)] = Data("WINNER".utf8)
            throw KeychainStoreError.duplicateItem
        }
        stored[key(service, account)] = data
    }
}

private let storageKey = "com.deepidv.device-fingerprint/device-fingerprint"

@Test func returnsStoredValueWithoutWriting() {
    let store = FakeKeychainStore()
    store.stored[storageKey] = Data("ABC-123".utf8)

    #expect(DeviceFingerprint.resolve(store: store) == "ABC-123")
    #expect(store.writeCount == 0)
}

@Test func mintsAUUIDAndPersistsItWhenAbsent() {
    let store = FakeKeychainStore()

    let value = DeviceFingerprint.resolve(store: store)

    #expect(UUID(uuidString: value) != nil)
    #expect(store.stored[storageKey] == Data(value.utf8))
}

@Test func returnsTheMintedValueEvenWhenTheWriteFails() {
    let store = FakeKeychainStore()
    store.failWrites = true

    let value = DeviceFingerprint.resolve(store: store)

    #expect(UUID(uuidString: value) != nil)
    #expect(store.stored[storageKey] == nil)
}

@Test func reMintsWhenStoredDataIsNotUTF8() {
    let store = FakeKeychainStore()
    store.stored[storageKey] = Data([0xFF, 0xFE])  // invalid UTF-8

    let value = DeviceFingerprint.resolve(store: store)

    #expect(UUID(uuidString: value) != nil)
}

@Test func duplicateItemRaceReturnsTheWinnersValue() {
    let store = FakeKeychainStore()
    store.duplicateOnWrite = true

    #expect(DeviceFingerprint.resolve(store: store) == "WINNER")
}
