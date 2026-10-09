import Foundation
public enum AccountProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude" }
}
public struct AccountUsage: Codable, Sendable {
    public var fiveHourRemaining: Double?
    public var weeklyRemaining: Double?
    public var fiveHourReset: Date?
    public var weeklyReset: Date?
    public var fiveHourWindowMinutes: Double?
    public var weeklyWindowMinutes: Double?
    public var fetchedAt: Date
    public init(fiveHourRemaining: Double?, weeklyRemaining: Double?, fiveHourReset: Date?, weeklyReset: Date?, fetchedAt: Date, fiveHourWindowMinutes: Double? = nil, weeklyWindowMinutes: Double? = nil) {
        self.fiveHourRemaining = fiveHourRemaining; self.weeklyRemaining = weeklyRemaining
        self.fiveHourReset = fiveHourReset; self.weeklyReset = weeklyReset
        self.fiveHourWindowMinutes = fiveHourWindowMinutes; self.weeklyWindowMinutes = weeklyWindowMinutes
        self.fetchedAt = fetchedAt
    }
}
public struct SavedAccountView: Identifiable, Sendable {
    public let provider: AccountProvider
    public let id: String
    public let displayName: String
    public let email: String
    public let isActive: Bool
    public let usage: AccountUsage?
    public let error: String?
    public init(id: String, displayName: String, email: String, isActive: Bool, usage: AccountUsage?, error: String?, provider: AccountProvider = .codex) { self.id = id; self.displayName = displayName; self.email = email; self.isActive = isActive; self.usage = usage; self.error = error; self.provider = provider }
}
public struct AccountSnapshot: Sendable {
    public let accounts: [SavedAccountView]
    public let cliPath: String?
    public let currentAccountLabel: String?
    public let notice: String?
    public init(accounts: [SavedAccountView], cliPath: String?, currentAccountLabel: String?, notice: String?) { self.accounts = accounts; self.cliPath = cliPath; self.currentAccountLabel = currentAccountLabel; self.notice = notice }
}
public typealias AccountProgress = @Sendable (String) async -> Void
public enum AccountError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
