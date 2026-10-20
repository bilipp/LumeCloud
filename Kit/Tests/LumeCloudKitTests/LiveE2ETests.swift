import Foundation
import LumeCloudKit
import Testing

/// End-to-end against a real server. Skipped unless `LUME_CLOUD_E2E_URL` is set:
///
///     LUME_CLOUD_E2E_URL=https://cloud-staging.getlume.org swift test --filter LiveE2ETests
///
/// Set `LUME_CLOUD_E2E_INVITE` too for an instance running `SIGNUP=invite`.
/// Every run creates a fresh account and deletes it at the end (also on failure).
@Suite(
    "Live E2E",
    .enabled(if: ProcessInfo.processInfo.environment["LUME_CLOUD_E2E_URL"] != nil, "set LUME_CLOUD_E2E_URL to run"),
    .serialized
)
struct LiveE2ETests {
    struct Timeout: Error {}

    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["LUME_CLOUD_E2E_URL"]!)!
    }

    static var invite: String? {
        ProcessInfo.processInfo.environment["LUME_CLOUD_E2E_INVITE"]
    }

    static func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Timeout()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    @Test func fullFlow() async throws {
        let anonymous = LumeCloudClient(baseURL: Self.baseURL, credentials: nil)
        let health = try await anonymous.health()
        #expect(health.ok)

        // Account + device A.
        let keys = LumeCloudKeys.generate()
        let created = try await anonymous.createAccount(authVerifier: keys.authVerifier, invite: Self.invite)
        #expect(created.accountId.count == 22)
        let deviceA = UUID()
        let clientA = anonymous.withCredentials(.init(accountId: created.accountId, keys: keys, deviceID: deviceA))

        do {
            try await runFlow(clientA: clientA, anonymous: anonymous, keys: keys, accountId: created.accountId, deviceA: deviceA)
        } catch {
            try? await clientA.deleteAccount()
            throw error
        }

        // Delete the account; every later call reads as deleted.
        try await clientA.deleteAccount()
        await #expect(throws: LumeCloudError.accountDeleted) { try await clientA.account() }
    }

    private func runFlow(
        clientA: LumeCloudClient,
        anonymous: LumeCloudClient,
        keys: LumeCloudKeys,
        accountId: String,
        deviceA: UUID
    ) async throws {
        let device = try await clientA.registerDevice(id: deviceA, name: "E2E A", platform: .current)
        #expect(device.id == deviceA)
        #expect(!device.revoked)

        // Socket first, so the push below produces a poke.
        let events = clientA.events()
        let firstPoke = Task { () -> Int? in
            for try await seq in events {
                return seq
            }
            return nil
        }
        defer { firstPoke.cancel() }
        try await Task.sleep(for: .seconds(2))

        // Push two sealed payloads.
        let profileID = UUID().uuidString
        let profile = LumeCloudPayload(type: "profile", key: "profile/\(profileID)", data: [
            "id": .string(profileID), "name": "E2E", "sortOrder": 0, "isChild": false, "updatedAt": 1,
        ])
        let content = LumeCloudPayload(type: "content", key: "content/\(profileID)/movie-e2e", data: [
            "contentId": "movie-e2e", "kindRaw": "movie", "watchProgress": 42.5, "isFavorite": true, "updatedAt": 2,
        ])
        let sealedProfile = try keys.seal(profile)
        let sealedContent = try keys.seal(content)
        let pushed = try await clientA.push([
            .upsert(rid: sealedProfile.rid, baseVersion: 0, ciphertext: sealedProfile.ciphertext),
            .upsert(rid: sealedContent.rid, baseVersion: 0, ciphertext: sealedContent.ciphertext),
        ])
        #expect(pushed.results.count == 2)
        for result in pushed.results {
            guard case let .ok(_, version, _) = result else {
                Issue.record("expected ok, got \(result)")
                continue
            }
            #expect(version == 1)
        }

        // The socket pokes with the new seq.
        let poke = try await Self.withTimeout(15) { try await firstPoke.value }
        #expect((poke ?? 0) > 0)

        // Pull and decrypt.
        let page = try await clientA.allChanges(since: 0)
        let byRID = Dictionary(page.records.map { ($0.rid, $0) }, uniquingKeysWith: { _, last in last })
        let pulledProfile = try #require(byRID[sealedProfile.rid])
        let pulledContent = try #require(byRID[sealedContent.rid])
        #expect(try keys.openPayload(#require(pulledProfile.ciphertext), rid: pulledProfile.rid) == profile)
        #expect(try keys.openPayload(#require(pulledContent.ciphertext), rid: pulledContent.rid) == content)
        let checkpoint = page.nextSeq

        // A stale baseVersion conflicts and returns the current record.
        var edited = profile
        edited.data["name"] = "E2E edited"
        let stale = try keys.seal(edited)
        let conflict = try await clientA.push([.upsert(rid: stale.rid, baseVersion: 0, ciphertext: stale.ciphertext)])
        guard case let .conflict(rid, current) = try #require(conflict.results.first) else {
            Issue.record("expected a conflict, got \(conflict.results)")
            return
        }
        #expect(rid == sealedProfile.rid)
        #expect(current.version == 1)
        #expect(try keys.openPayload(#require(current.ciphertext), rid: rid) == profile)

        // Delete one → tombstone in the feed.
        let deleted = try await clientA.push([.delete(rid: sealedContent.rid, baseVersion: 1)])
        guard case let .ok(_, deletedVersion, _) = try #require(deleted.results.first) else {
            Issue.record("expected ok, got \(deleted.results)")
            return
        }
        #expect(deletedVersion == 2)
        let tail = try await clientA.changes(since: checkpoint)
        let tombstone = try #require(tail.records.first { $0.rid == sealedContent.rid })
        #expect(tombstone.deleted)
        #expect(tombstone.ciphertext == nil)

        // Pairing: a second device joins with its own key pair.
        let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
        let ticket = try await anonymous.startPairing(publicKey: publicKey, deviceName: "E2E B", platform: .current)
        #expect(ticket.code.count == 6)
        #expect(try await anonymous.pairingResult(code: ticket.code, pollToken: ticket.pollToken) == .pending)

        let request = try await clientA.pairingRequest(code: ticket.code)
        #expect(request.publicKey == publicKey)
        #expect(request.deviceName == "E2E B")
        let grant = LumeCloudGrant(accountId: accountId, rootKey: keys.rootKey, serverURL: Self.baseURL)
        let sealedGrant = try LumeCloudPairing.seal(grant, to: request.publicKey, code: ticket.code)
        try await clientA.sealPairing(code: ticket.code, sealed: sealedGrant)
        await #expect(throws: LumeCloudError.pairingAlreadySealed) {
            try await clientA.sealPairing(code: ticket.code, sealed: sealedGrant)
        }

        var received: SealedGrant?
        for _ in 0 ..< 10 {
            if case let .sealed(sealed) = try await anonymous.pairingResult(code: ticket.code, pollToken: ticket.pollToken) {
                received = sealed
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        let opened = try LumeCloudPairing.open(#require(received), privateKey: privateKey, code: ticket.code)
        #expect(opened == grant)

        let keysB = try opened.keys()
        #expect(keysB == keys)
        let deviceB = UUID()
        let clientB = LumeCloudClient(
            baseURL: opened.serverURL,
            credentials: .init(accountId: opened.accountId, keys: keysB, deviceID: deviceB)
        )
        _ = try await clientB.registerDevice(id: deviceB, name: "E2E B", platform: .current)
        let pageB = try await clientB.allChanges(since: 0)
        let profileB = try #require(pageB.records.first { $0.rid == keysB.recordID(for: profile.key) })
        #expect(try keysB.openPayload(#require(profileB.ciphertext), rid: profileB.rid) == profile)
        // `since=0` returns the live set without tombstones.
        #expect(!pageB.records.contains { $0.rid == sealedContent.rid })

        let devices = try await clientA.devices()
        #expect(Set(devices.map(\.id)).isSuperset(of: [deviceA, deviceB]))

        // Revoking B locks it out.
        try await clientA.revokeDevice(id: deviceB)
        await #expect(throws: LumeCloudError.deviceRevoked) { try await clientB.account() }
    }
}
