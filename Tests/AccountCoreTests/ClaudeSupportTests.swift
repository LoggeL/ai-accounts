import Foundation
import Testing
@testable import AccountCore

private final class MemoryClaudeVault: ClaudeCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data
    private var writes = 0
    init(_ value: Data) { self.value = value }
    func read(service: String, allowPrompt: Bool) throws -> Data { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ data: Data, service: String) throws { lock.lock(); defer { lock.unlock() }; value = data; writes += 1 }
    func remove(service: String) throws {}
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
}

private struct ClaudeSwitchFixture {
    let root: URL
    let store: Store
    let configURL: URL
    let original: Data
    let vault = MemoryClaudeVault(Data("old-keychain-login".utf8))
    let target = Data("saved-keychain-login".utf8)
    init() throws {
        let temp = NSTemporaryDirectory()
        root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp)
            .appendingPathComponent("claude-switch-test-" + UUID().uuidString)
        store = Store(base: root, activeHome: root)
        configURL = root.appendingPathComponent(".claude.json")
        original = Data(#"{"oauthAccount":{"emailAddress":"old@example.test"},"projects":{"keep":7},"userID":"installation","cachedUsageUtilization":{"accountUuid":"old"},"unknown":"preserved"}"#.utf8)
        try store.write(original, to: configURL)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func install(verify: @escaping @Sendable () async throws -> Void = {}) async throws {
        try await ClaudeSwitchTransaction.install(credential: target,
            account: .object(["emailAddress": .string("new@example.test")]),
            configURL: configURL, service: "test", vault: vault, store: store, verify: verify)
    }
}

struct ClaudeSupportTests {
    @Test func statusProcessCompletesAndDrainsOutput() async throws {
        let (data, status) = try await ClaudeProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'saved-profile-status'"], environment: [:],
            directory: URL(fileURLWithPath: "/private/tmp"), timeout: 2)
        #expect(status == 0 && String(decoding: data, as: UTF8.self) == "saved-profile-status")
    }
    @Test func statusTimeoutIsBounded() async throws {
        let start = Date()
        do {
            _ = try await ClaudeProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"], environment: [:], directory: URL(fileURLWithPath: "/private/tmp"), timeout: 0.1)
            Issue.record("Expected timeout")
        } catch {}
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func statusCancellationDrainsChild() async throws {
        let start = Date()
        let task = Task {
            try await ClaudeProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"], environment: [:], directory: URL(fileURLWithPath: "/private/tmp"), timeout: 20)
        }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func parsesSeparateClaudeWindowsAndFractionalReset() throws {
        let data = Data(#"{"five_hour":{"utilization":23.5,"resets_at":"2026-10-06T19:00:00.123+00:00"},"seven_day":{"utilization":100,"resets_at":"2026-10-07T01:00:00Z"}}"#.utf8)
        let usage = try ClaudeUsageParser.parse(data, fetchedAt: Date())
        #expect(usage.fiveHourRemaining == 76.5)
        #expect(usage.weeklyRemaining == 0)
        #expect(usage.fiveHourReset != nil && usage.weeklyReset != nil)
        #expect(usage.fiveHourWindowMinutes == 300 && usage.weeklyWindowMinutes == 10080)
    }
    @Test func missingWindowsDoNotInventQuotaOrReset() throws {
        let usage = try ClaudeUsageParser.parse(Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8), fetchedAt: Date())
        #expect(usage.fiveHourRemaining == nil && usage.fiveHourWindowMinutes == nil)
        #expect(usage.weeklyRemaining == 100 && usage.weeklyReset == nil)
    }
    @Test func invalidPercentagesAreRejected() throws {
        #expect(throws: (any Error).self) {
            try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":101},"seven_day":{"utilization":-1}}"#.utf8), fetchedAt: Date())
        }
        #expect(throws: (any Error).self) {
            try ClaudeUsageParser.parse(Data("[]".utf8), fetchedAt: Date())
        }
    }
    @Test func sameEmailDifferentOrganizationDoesNotMatch() {
        let a = ClaudeRecord(id: "a", name: "A", email: "same@example.test", accountID: "user", organizationID: "first")
        let b = ClaudeRecord(id: "b", name: "B", email: "same@example.test", accountID: "user", organizationID: "second")
        #expect(!a.matches(b))
    }
    @Test func keychainProfilesAreIsolatedAndStable() {
        #expect(ClaudeKeychain.service(configDirectory: nil) == "Claude Code-credentials")
        #expect(ClaudeKeychain.service(configDirectory: URL(fileURLWithPath: "/tmp/a")) == "Claude Code-credentials-d9b741ea")
        #expect(ClaudeKeychain.service(configDirectory: URL(fileURLWithPath: "/tmp/a")) !=
                ClaudeKeychain.service(configDirectory: URL(fileURLWithPath: "/tmp/b")))
    }
    @Test func switchReusesSavedCredentialAndPreservesConversations() async throws {
        let f = try ClaudeSwitchFixture(); defer { f.clean() }
        try await f.install()
        #expect(try f.vault.read(service: "test", allowPrompt: false) == f.target)
        let config = try JSONDecoder().decode(J.self, from: Data(contentsOf: f.configURL))
        #expect(config["oauthAccount"]?["emailAddress"]?.string == "new@example.test")
        #expect(config["projects"]?["keep"]?.number == 7)
        #expect(config["userID"]?.string == "installation")
        #expect(config["unknown"]?.string == "preserved")
        #expect(config["cachedUsageUtilization"] == nil)
        #expect(f.vault.count() == 1)
        let text = try String(contentsOf: f.configURL, encoding: .utf8)
        #expect(!text.contains("keychain-login"))
    }
    @Test func failedVerificationRestoresCredentialAndConfigExactly() async throws {
        let f = try ClaudeSwitchFixture(); defer { f.clean() }
        do { try await f.install { throw AccountError.message("verification failed") }; Issue.record("Expected failure") } catch {}
        #expect(try f.vault.read(service: "test", allowPrompt: false) == Data("old-keychain-login".utf8))
        #expect(try Data(contentsOf: f.configURL) == f.original)
        #expect(f.vault.count() == 2)
    }
    @Test func linkedConfigCannotModifyCredential() async throws {
        let f = try ClaudeSwitchFixture(); defer { f.clean() }
        let link = f.root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.configURL)
        do {
            try await ClaudeSwitchTransaction.install(credential: f.target, account: .object([:]),
                configURL: link, service: "test", vault: f.vault, store: f.store, verify: {})
            Issue.record("Expected symlink rejection")
        } catch {}
        #expect(f.vault.count() == 0)
        #expect(try Data(contentsOf: f.configURL) == f.original)
    }
    @Test func malformedConfigCannotModifyCredential() async throws {
        let f = try ClaudeSwitchFixture(); defer { f.clean() }
        try f.store.write(Data("[]".utf8), to: f.configURL)
        do { try await f.install(); Issue.record("Expected invalid config failure") } catch {}
        #expect(f.vault.count() == 0)
    }
    @Test func tokenRenewalPreservesFieldsAndRotatesRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"saved","expiresAt":0,"subscriptionType":"max"},"other":{"preserved":true}}"#.utf8)
        let response = Data(#"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"scope":"user:profile user:inference"}"#.utf8)
        let data = try ClaudeTokenRenewal.merge(credential: credential, response: response, now: now)
        let root = try JSONDecoder().decode(J.self, from: data)
        #expect(root["claudeAiOauth"]?["accessToken"]?.string == "renewed")
        #expect(root["claudeAiOauth"]?["refreshToken"]?.string == "rotated")
        #expect(root["claudeAiOauth"]?["expiresAt"]?.number == 1_800_003_600_000)
        #expect(root["claudeAiOauth"]?["subscriptionType"]?.string == "max")
        #expect(root["other"]?.object != nil)
    }
    @Test func tokenRenewalRetainsRefreshTokenWhenOmitted() throws {
        let credential = Data(#"{"claudeAiOauth":{"refreshToken":"saved"}}"#.utf8)
        let result = try ClaudeTokenRenewal.merge(credential: credential,
            response: Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8), now: Date())
        #expect(try JSONDecoder().decode(J.self, from: result)["claudeAiOauth"]?["refreshToken"]?.string == "saved")
        #expect(throws: (any Error).self) {
            try ClaudeTokenRenewal.merge(credential: credential, response: Data(#"{"access_token":"","expires_in":-1}"#.utf8), now: Date())
        }
    }
}
