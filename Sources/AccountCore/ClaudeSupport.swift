import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin

enum ClaudeUsageParser {
    static func parse(_ data: Data, fetchedAt: Date) throws -> AccountUsage {
        let root = try JSONDecoder().decode(J.self, from: data)
        guard root.object != nil else { throw AccountError.message("Ungültige Claude-Limitdaten.") }
        func remaining(_ key: String) -> Double? {
            guard let value = root[key]?["utilization"]?.number, value.isFinite,
                  (0...100).contains(value) else { return nil }
            return 100 - value
        }
        func reset(_ key: String) -> Date? {
            guard let text = root[key]?["resets_at"]?.string else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        let five = remaining("five_hour"), week = remaining("seven_day")
        guard five != nil || week != nil else { throw AccountError.message("Claude liefert derzeit keine unterstützten Limits.") }
        return AccountUsage(fiveHourRemaining: five, weeklyRemaining: week,
            fiveHourReset: reset("five_hour"), weeklyReset: reset("seven_day"), fetchedAt: fetchedAt,
            fiveHourWindowMinutes: five == nil ? nil : 300, weeklyWindowMinutes: week == nil ? nil : 10080)
    }
}

enum ClaudeTokenRenewal {
    static func merge(credential: Data, response: Data, now: Date) throws -> Data {
        guard var root = try JSONDecoder().decode(J.self, from: credential).object,
              var oauth = root["claudeAiOauth"]?.object,
              let oldRefresh = oauth["refreshToken"]?.string else {
            throw AccountError.message("Keine erneuerbare Claude-Anmeldung vorhanden.")
        }
        let result = try JSONDecoder().decode(J.self, from: response)
        guard let access = result["access_token"]?.string, !access.isEmpty,
              let duration = result["expires_in"]?.number, duration.isFinite, duration > 0 else {
            throw AccountError.message("Claude-Anmeldung konnte nicht erneuert werden.")
        }
        oauth["accessToken"] = .string(access)
        oauth["refreshToken"] = result["refresh_token"] ?? .string(oldRefresh)
        oauth["expiresAt"] = .number((now.timeIntervalSince1970 + duration) * 1000)
        if let scope = result["scope"]?.string { oauth["scopes"] = .array(scope.split(separator: " ").map { .string(String($0)) }) }
        root["claudeAiOauth"] = .object(oauth)
        return try JSONEncoder().encode(J.object(root))
    }
}

struct ClaudeRecord: Codable, Sendable {
    let id: String
    var name: String
    let email: String
    let accountID: String
    let organizationID: String
    func matches(_ other: ClaudeRecord) -> Bool {
        accountID == other.accountID && organizationID == other.organizationID
    }
    static func fromConfig(_ config: J, id: String, name: String? = nil) throws -> ClaudeRecord {
        guard let account = config["oauthAccount"],
              let accountID = account["accountUuid"]?.string, UUID(uuidString: accountID) != nil,
              let org = account["organizationUuid"]?.string, UUID(uuidString: org) != nil,
              let email = account["emailAddress"]?.string, !email.isEmpty else {
            throw AccountError.message("Keine Claude-Abonnement-Anmeldung gefunden.")
        }
        return ClaudeRecord(id: id, name: name ?? account["displayName"]?.string ?? "Claude",
            email: email, accountID: accountID, organizationID: org)
    }
}

protocol ClaudeCredentialVault: Sendable {
    func read(service: String, allowPrompt: Bool) throws -> Data
    func write(_ data: Data, service: String) throws
    func remove(service: String) throws
}

struct ClaudeKeychain: ClaudeCredentialVault {
    private static let interactionLock = NSLock()
    static func service(configDirectory: URL?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let path = configDirectory.path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()]
    }
    func read(service: String, allowPrompt: Bool) throws -> Data {
        Self.interactionLock.lock()
        var originalInteraction: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&originalInteraction)
        SecKeychainSetUserInteractionAllowed(allowPrompt)
        defer {
            SecKeychainSetUserInteractionAllowed(originalInteraction.boolValue)
            Self.interactionLock.unlock()
        }
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
            // Legacy generic-password ACLs ignore LAContext alone.
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                throw AccountError.message("Schlüsselbundzugriff fehlt. Klicke auf Aktualisieren und erlaube Codex Konten den Zugriff auf die Claude-Anmeldung.")
            }
            throw AccountError.message("Claude-Anmeldung im Schlüsselbund nicht verfügbar (\(status)). Bitte erneut anmelden.")
        }
        return data
    }
    func write(_ data: Data, service: String) throws {
        let q = query(service)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccountError.message("Claude-Anmeldung konnte nicht im Schlüsselbund gespeichert werden (\(status)).") }
    }
    func remove(service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.message("Die neue Claude-Anmeldung konnte nicht entfernt werden (\(status)).")
        }
    }
}

/// Changes only the account metadata; local projects and settings remain intact.
enum ClaudeSwitchTransaction {
    static func install(credential: Data, account: J, configURL: URL, service: String,
                        vault: any ClaudeCredentialVault, store: Store,
                        verify: @Sendable () async throws -> Void) async throws {
        let originalCredential = try vault.read(service: service, allowPrompt: true)
        let originalConfig = try Data(contentsOf: configURL)
        guard var config = try JSONDecoder().decode(J.self, from: originalConfig).object else {
            throw AccountError.message("Claude-Konfiguration ist beschädigt.")
        }
        config["oauthAccount"] = account
        for key in ["cachedUsageUtilization", "cachedExtraUsageDisabledReason", "orgModelDefaultCache",
                    "modelAccessCache", "cachedGrowthBookFeatures", "cachedGrowthBookFeaturesAt"] {
            config.removeValue(forKey: key)
        }
        var installed = false
        do {
            try Task.checkCancellation()
            try store.check(configURL)
            try vault.write(credential, service: service); installed = true
            try store.write(JSONEncoder().encode(J.object(config)), to: configURL)
            try await verify()
        } catch {
            if installed {
                do {
                    try vault.write(originalCredential, service: service)
                    try store.write(originalConfig, to: configURL)
                } catch {
                    throw AccountError.message("Claude-Wechsel fehlgeschlagen. Wiederherstellen fehlgeschlagen: \(safeMessage(error))")
                }
            }
            throw error
        }
    }
}

private final class ClaudeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var status: Int32?
    private var eof = false
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data.prefix(max(0, 1_048_576 - bytes.count))) }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func finish(_ code: Int32) { lock.lock(); defer { lock.unlock() }; status = code }
    func exitStatus() -> Int32? { lock.lock(); defer { lock.unlock() }; return status }
    func finishOutput() { lock.lock(); defer { lock.unlock() }; eof = true }
    func outputFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return eof }
}

/// Termination callbacks avoid Foundation's run-loop-dependent waitUntilExit in a GUI app.
enum ClaudeProcessRunner {
    static func run(executable: URL, arguments: [String], environment: [String: String],
                    directory: URL, timeout: TimeInterval) async throws -> (Data, Int32) {
        let process = Process(), output = Pipe(), capture = ClaudeCapture()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { capture.finish($0.terminationStatus) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; capture.finishOutput() }
            else { capture.append(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? output.fileHandleForReading.close()
        }
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while capture.exitStatus() == nil {
                try Task.checkCancellation()
                guard Date() < deadline else { throw AccountError.message("Claude-Anmeldung oder Statusabfrage hat das Zeitlimit erreicht.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            for _ in 0..<20 {
                if capture.exitStatus() != nil { break }
                // Cancellation must not turn this cleanup delay into a busy loop.
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for _ in 0..<20 {
                if capture.exitStatus() != nil { break }
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            }
            throw error
        }
        // Allow the reader to collect the final bytes without an unbounded pipe read.
        for _ in 0..<20 {
            if capture.outputFinished() { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let code = capture.exitStatus() else { throw AccountError.message("Claude-Prozessende konnte nicht bestätigt werden.") }
        return (capture.value(), code)
    }
}

private final class ClaudeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor ClaudeAccountService {
    private let store: Store
    private let activeDirectory: URL
    private let activeConfig: URL
    private let activeService: String
    private let vault: any ClaudeCredentialVault
    private var usage: [String: AccountUsage] = [:]
    private var errors: [String: String] = [:]
    private var busy = false
    private var lockFD: Int32 = -1
    private var notice: String?
    private var blockedUntil: Date?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        activeDirectory = override ?? home.appendingPathComponent(".claude")
        activeConfig = override?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json")
        activeService = ClaudeKeychain.service(configDirectory: override)
        store = Store(base: home.appendingPathComponent("Library/Application Support/Codex Konten/Claude"),
                      activeHome: activeDirectory)
        vault = ClaudeKeychain()
        let cacheURL = store.base.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([String: AccountUsage].self, from: data) { usage = cached }
    }

    private func begin() throws {
        guard !busy else { throw AccountError.message("Ein Claude-Kontovorgang läuft bereits.") }
        try store.check(store.base)
        try FileManager.default.createDirectory(at: store.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = store.base.appendingPathComponent(".lock"); try store.check(url)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AccountError.message("Claude-Kontosperre nicht verfügbar.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw AccountError.message("Eine andere Instanz verwaltet gerade die Claude-Konten.") }
        lockFD = fd; busy = true
    }
    private func end() { if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }; busy = false }
    private var registryURL: URL { store.base.appendingPathComponent("profiles.json") }
    private func records() throws -> [ClaudeRecord] {
        try store.check(registryURL)
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return [] }
        return try JSONDecoder().decode([ClaudeRecord].self, from: Data(contentsOf: registryURL))
    }
    private func save(_ records: [ClaudeRecord]) throws { try store.write(JSONEncoder().encode(records), to: registryURL) }
    private func profile(_ record: ClaudeRecord) throws -> URL { try store.profile(record.id) }
    private func config(_ url: URL) throws -> J {
        try store.check(url)
        return try JSONDecoder().decode(J.self, from: Data(contentsOf: url))
    }
    private func locate() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let paths: [String?] = [env["CLAUDE_CLI_PATH"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] +
            (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        guard let path = paths.compactMap({ $0 }).first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AccountError.message("Claude Code fehlt. Installiere Claude Code oder setze CLAUDE_CLI_PATH.")
        }
        return URL(fileURLWithPath: path)
    }
    private func environment(directory: URL?, isolated: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let directory { env["CLAUDE_CONFIG_DIR"] = directory.path } else { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        if isolated {
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                        "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_CLIENT_ID", "ANTHROPIC_PROFILE",
                        "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID"] { env.removeValue(forKey: key) }
        }
        return env
    }
    private func activeOverride() -> URL? {
        activeService == ClaudeKeychain.service(configDirectory: nil) ? nil : activeDirectory
    }
    private func run(_ arguments: [String], directory: URL?, isolated: Bool = false,
                     timeout: TimeInterval = 15) async throws -> (Data, Int32) {
        try await ClaudeProcessRunner.run(executable: locate(), arguments: arguments,
            environment: environment(directory: directory, isolated: isolated), directory: store.base, timeout: timeout)
    }
    private func current() async throws -> ClaudeRecord? {
        guard FileManager.default.fileExists(atPath: activeConfig.path) else { return nil }
        let (data, status) = try await run(["auth", "status"], directory: activeOverride())
        guard status == 0 else { return nil }
        let auth = try JSONDecoder().decode(J.self, from: data)
        guard auth["authMethod"]?.string == "claude.ai" else {
            throw AccountError.message("Claude Code nutzt keine Abonnement-Anmeldung. API-Schlüssel und Cloud-Anbieter werden hier nicht umgeschaltet.")
        }
        let record = try ClaudeRecord.fromConfig(config(activeConfig), id: "current")
        guard auth["email"]?.string?.lowercased() == record.email.lowercased(),
              auth["orgId"]?.string == record.organizationID else {
            throw AccountError.message("Claude-Status und lokale Kontoidentität stimmen nicht überein.")
        }
        return ClaudeRecord(id: "current-" + record.accountID + "-" + record.organizationID,
            name: record.name, email: record.email, accountID: record.accountID, organizationID: record.organizationID)
    }
    private func cachedUsage(_ config: J, record: ClaudeRecord) -> AccountUsage? {
        guard let cache = config["cachedUsageUtilization"], cache["accountUuid"]?.string == record.accountID,
              let ms = cache["fetchedAtMs"]?.number, ms.isFinite, let value = cache["utilization"] else { return nil }
        return try? ClaudeUsageParser.parse(JSONEncoder().encode(value), fetchedAt: Date(timeIntervalSince1970: ms / 1000))
    }
    private func snapshotUnlocked() async throws -> AccountSnapshot {
        let saved = try records()
        var active: ClaudeRecord?
        var stateNotice = notice
        do { active = try await current() }
        catch { stateNotice = safeMessage(error) }
        var all = saved
        if let active, !all.contains(where: { $0.matches(active) }) { all.insert(active, at: 0) }
        let rows = all.map { record -> SavedAccountView in
            let isActive = active.map(record.matches) ?? false
            let fallback = isActive ? (try? config(activeConfig)).flatMap { cachedUsage($0, record: record) } : nil
            return SavedAccountView(id: record.id, displayName: record.name, email: record.email,
                isActive: isActive, usage: usage[record.id] ?? fallback, error: errors[record.id], provider: .claude)
        }
        return AccountSnapshot(accounts: rows, cliPath: try? locate().path, currentAccountLabel: active?.name,
            notice: stateNotice)
    }
    public func snapshot() async throws -> AccountSnapshot {
        try begin(); defer { end() }
        return try await snapshotUnlocked()
    }
    private func request(path: String, token: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        request.timeoutInterval = 20
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.290", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let seconds = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                blockedUntil = Date().addingTimeInterval(min(3600, max(60, seconds)))
                throw AccountError.message("Claude begrenzt die Abfragen. Bitte später aktualisieren.")
            }
            throw AccountError.message(status == 401 || status == 403 ?
                "Claude-Anmeldung abgelaufen oder ohne Zugriff. Bitte erneut anmelden." : "Claude-Abfrage fehlgeschlagen (HTTP \(status)).")
        }
        guard data.count <= 4_194_304 else { throw AccountError.message("Claude-Antwort ist zu groß.") }
        return data
    }
    private func token(_ credential: Data) throws -> String {
        let root = try JSONDecoder().decode(J.self, from: credential)
        guard let token = root["claudeAiOauth"]?["accessToken"]?.string, !token.isEmpty else {
            throw AccountError.message("Keine Claude-Abonnement-Anmeldung im Schlüsselbund.")
        }
        return token
    }
    private func renewed(_ credential: Data, service: String) async throws -> Data {
        let root = try JSONDecoder().decode(J.self, from: credential).object ?? [:]
        guard let oauth = root["claudeAiOauth"]?.object,
              let expires = oauth["expiresAt"]?.number, expires / 1000 < Date().timeIntervalSince1970 + 60 else { return credential }
        guard let refresh = oauth["refreshToken"]?.string else { throw AccountError.message("Claude-Anmeldung abgelaufen. Bitte erneut anmelden.") }
        var payload: [String: J] = ["grant_type": .string("refresh_token"), "refresh_token": .string(refresh),
            "client_id": .string("9d1c250a-e61b-44d9-88ed-5944d1962f5e")]
        if let scopes = oauth["scopes"]?.array?.compactMap({ $0.string }), !scopes.isEmpty {
            payload["scope"] = .string(scopes.joined(separator: " "))
        }
        let body = try JSONEncoder().encode(J.object(payload))
        let response = try await request(path: "/v1/oauth/token", token: "", body: body)
        let data = try ClaudeTokenRenewal.merge(credential: credential, response: response, now: Date())
        try vault.write(data, service: service)
        return data
    }
    private func verify(_ credential: Data, record: ClaudeRecord) async throws {
        let profile = try JSONDecoder().decode(J.self, from: await request(path: "/api/oauth/profile", token: token(credential)))
        guard profile["account"]?["uuid"]?.string == record.accountID,
              profile["organization"]?["uuid"]?.string == record.organizationID else {
            throw AccountError.message("Claude-Zielanmeldung gehört zu einem anderen Konto oder einer anderen Organisation.")
        }
    }
    public func refresh(allowPrompt: Bool = false) async throws -> AccountSnapshot {
        try begin(); defer { end() }
        let before = try await snapshotUnlocked()
        if let blockedUntil, blockedUntil > Date() { return before }
        let saved = try records()
        for row in before.accounts {
            try Task.checkCancellation()
            do {
                let record = try saved.first { $0.id == row.id } ?? ClaudeRecord.fromConfig(config(activeConfig), id: row.id)
                let service = row.isActive ? activeService : ClaudeKeychain.service(configDirectory: try profile(record))
                var credential = try vault.read(service: service, allowPrompt: allowPrompt)
                // Running Claude owns its active token refresh; isolated inactive profiles belong to this app.
                if row.isActive {
                    let payload = try JSONDecoder().decode(J.self, from: credential)
                    if let expires = payload["claudeAiOauth"]?["expiresAt"]?.number,
                       expires / 1000 < Date().timeIntervalSince1970 + 60 {
                        try await ensureNoSessions()
                        credential = try await renewed(credential, service: service)
                    }
                } else { credential = try await renewed(credential, service: service) }
                try await verify(credential, record: record)
                let data = try await request(path: "/api/oauth/usage", token: token(credential))
                usage[row.id] = try ClaudeUsageParser.parse(data, fetchedAt: Date()); errors[row.id] = nil
            } catch is CancellationError { throw CancellationError() }
            catch { errors[row.id] = safeMessage(error); if blockedUntil.map({ $0 > Date() }) == true { break } }
        }
        try store.write(JSONEncoder().encode(usage), to: store.base.appendingPathComponent("usage.json"))
        return try await snapshotUnlocked()
    }
    public func addAccount(displayName: String, progress: @escaping AccountProgress) async throws -> AccountSnapshot {
        try begin(); defer { end() }
        let id = UUID().uuidString
        let home = try store.profile(id); try store.check(home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let service = ClaudeKeychain.service(configDirectory: home)
        var committed = false
        defer {
            if !committed { try? vault.remove(service: service); try? FileManager.default.removeItem(at: home) }
        }
        await progress("Claude-Anmeldung im Browser. Wähle dort das gewünschte Konto.")
        let (_, status) = try await run(["auth", "login", "--claudeai"], directory: home, isolated: true, timeout: 600)
        guard status == 0 else { throw AccountError.message("Claude-Anmeldung wurde nicht abgeschlossen.") }
        try Task.checkCancellation()
        let metadata = try config(home.appendingPathComponent(".claude.json"))
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = try ClaudeRecord.fromConfig(metadata, id: id, name: name.isEmpty ? nil : name)
        let credential = try vault.read(service: service, allowPrompt: true)
        try await verify(credential, record: record)
        var all = try records()
        if let index = all.firstIndex(where: { $0.matches(record) }) {
            let old = all[index]; let oldHome = try profile(old)
            try vault.write(credential, service: ClaudeKeychain.service(configDirectory: oldHome))
            try store.write(JSONEncoder().encode(metadata), to: oldHome.appendingPathComponent(".claude.json"))
            all[index].name = record.name
        } else { all.append(record) }
        try save(all)
        committed = all.contains { $0.id == record.id }
        notice = "Claude-Konto gespeichert. Die aktuelle Anmeldung bleibt bestehen."
        return try await snapshotUnlocked()
    }
    private func ensureNoSessions() async throws {
        let (_, status) = try await ClaudeProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", "(^|[/ ])claude([/ ]|$)|/@anthropic-ai/claude-code/cli\\.js"],
            environment: [:], directory: store.base, timeout: 3)
        guard status == 1 else {
            throw AccountError.message("Bitte laufende Claude-Code-Sitzungen vor dem Kontowechsel schließen. Es wurden keine Anmeldedaten verändert.")
        }
        // A plaintext fallback would outrank or disagree with a newly installed Keychain login.
        guard !FileManager.default.fileExists(atPath: activeDirectory.appendingPathComponent(".credentials.json").path) else {
            throw AccountError.message("Claude nutzt eine zusätzliche Anmeldedatei. Melde dich mit Claude Code erneut im Schlüsselbund an, bevor du wechselst.")
        }
    }
    public func switchAccount(id: String, progress: @escaping AccountProgress) async throws -> AccountSnapshot {
        try begin(); defer { end() }
        var all = try records()
        guard let target = all.first(where: { $0.id == id }) else { throw AccountError.message("Claude-Zielkonto nicht gefunden.") }
        let current = try await current() ?? ClaudeRecord.fromConfig(config(activeConfig), id: "current")
        if current.matches(target) { return try await snapshotUnlocked() }
        try await ensureNoSessions()
        await progress("Claude-Zielanmeldung wird geprüft …")
        let targetHome = try profile(target)
        let targetService = ClaudeKeychain.service(configDirectory: targetHome)
        let credential = try await renewed(vault.read(service: targetService, allowPrompt: true), service: targetService)
        try await verify(credential, record: target)
        let metadata = try config(targetHome.appendingPathComponent(".claude.json"))
        guard let account = metadata["oauthAccount"] else { throw AccountError.message("Claude-Kontodaten fehlen.") }
        guard try ClaudeRecord.fromConfig(metadata, id: target.id).matches(target) else { throw AccountError.message("Claude-Kontodaten wurden verändert.") }
        let original = try vault.read(service: activeService, allowPrompt: true)
        // Retain the outgoing account in its own Claude Code Keychain profile, never in a token file.
        let retained = all.first(where: { $0.matches(current) }) ??
            ClaudeRecord(id: UUID().uuidString, name: current.name, email: current.email,
                         accountID: current.accountID, organizationID: current.organizationID)
        let retainedHome = try profile(retained)
        try vault.write(original, service: ClaudeKeychain.service(configDirectory: retainedHome))
        guard let outgoingAccount = try config(activeConfig)["oauthAccount"] else { throw AccountError.message("Bisherige Claude-Kontometadaten fehlen.") }
        let retainedConfig = J.object(["oauthAccount": outgoingAccount, "hasCompletedOnboarding": .bool(true)])
        try store.write(JSONEncoder().encode(retainedConfig), to: retainedHome.appendingPathComponent(".claude.json"))
        if !all.contains(where: { $0.matches(retained) }) { all.append(retained); try save(all) }
        try await ensureNoSessions()
        await progress("Claude-Anmeldung wird eingesetzt und geprüft …")
        try await ClaudeSwitchTransaction.install(credential: credential, account: account,
            configURL: activeConfig, service: activeService, vault: vault, store: store) { [self] in
                guard let confirmed = try await self.current(), confirmed.matches(target) else {
                    throw AccountError.message("Claude-Identitätsprüfung nach dem Wechsel fehlgeschlagen.")
                }
            }
        notice = "Claude Code verwendet \(target.name) in neuen Sitzungen. Claude Desktop meldet sich separat an."
        return try await snapshotUnlocked()
    }
    public func removeAccount(id: String) async throws -> AccountSnapshot {
        try begin(); defer { end() }
        var all = try records()
        guard let record = all.first(where: { $0.id == id }) else { throw AccountError.message("Claude-Konto nicht gefunden.") }
        if let active = try await current(), record.matches(active) { throw AccountError.message("Das aktive Claude-Konto kann nicht entfernt werden.") }
        all.removeAll { $0.id == id }; try save(all)
        usage[id] = nil; errors[id] = nil
        notice = "Claude-Konto aus der Liste entfernt. Das geschützte Profil bleibt erhalten."
        return try await snapshotUnlocked()
    }
}
