import AccountCore
import Foundation
import SwiftUI

@MainActor
final class AccountModel: ObservableObject {
    @Published var snapshot: AccountSnapshot?
    @Published var claudeSnapshot: AccountSnapshot?
    @Published var selectedProvider: AccountProvider = .codex
    @Published var operation: String?
    @Published var progress = ""
    @Published var error: String?
    @Published var cancelling = false
    @Published var showOpenCodexAction = false
    private var task: Task<Void, Never>?
    private let service: AccountService?
    private let claudeService: ClaudeAccountService?
    let demoMode: Bool
    private var updateIsInstalling: (@MainActor () -> Bool)?
    private var lastRefreshAttempt: Date?
    private var backgroundRefreshTask: Task<Void, Never>?

    var busy: Bool { operation != nil }
    var displaySnapshot: AccountSnapshot? { selectedProvider == .codex ? snapshot : claudeSnapshot }
    var accounts: [SavedAccountView] { displaySnapshot?.accounts ?? [] }

    /// Only the actual Codex identity (isActive) can contribute to the menu bar.
    var menuBarRemaining: (percent: Int, window: String, account: String)? {
        guard let active = accounts.first(where: \.isActive), let usage = active.usage else { return nil }
        if let weekly = usage.weeklyRemaining, weekly.isFinite {
            return (Int(min(100, max(0, weekly)).rounded()), "Wochenlimit", active.displayName)
        }
        if let fiveHour = usage.fiveHourRemaining, fiveHour.isFinite {
            return (Int(min(100, max(0, fiveHour)).rounded()), "5-Stunden-Limit", active.displayName)
        }
        return nil
    }

    var menuBarDescription: String {
        if let remaining = menuBarRemaining {
            let base = "\(selectedProvider.title), \(remaining.account): \(remaining.percent) % im \(remaining.window) übrig"
            if let active = accounts.first(where: \.isActive), let usage = active.usage {
                let fetchedAt = usage.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "de_DE")))
                if let error = active.error, !error.isEmpty {
                    return "\(base). Abruf fehlgeschlagen: \(error). Letzter Stand: \(fetchedAt)"
                }
                if Date().timeIntervalSince(usage.fetchedAt) > 900 {
                    return "\(base). Veralteter Stand vom \(fetchedAt)"
                }
                return "\(base). Stand: \(fetchedAt)"
            }
            return base
        }
        if let active = accounts.first(where: \.isActive) {
            return "\(active.displayName): Limit noch nicht verfügbar"
        }
        return displaySnapshot == nil ? "\(selectedProvider.title): Konten werden geladen" : "\(selectedProvider.title): kein aktives Konto erkannt"
    }

    func startBackgroundRefresh(updates: UpdateController) {
        updates.bindAccountBusy { [weak self] in self?.busy ?? false }
        bindUpdateInstall { [weak updates] in updates?.isInstalling ?? false }
        guard service != nil, backgroundRefreshTask == nil else { return }
        load()
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { break }
                self?.refresh(allowPrompt: false)
            }
        }
    }

    func bindUpdateInstall(_ isInstalling: @escaping @MainActor () -> Bool) {
        updateIsInstalling = isInstalling
    }

    private var canStartOperation: Bool { !busy && updateIsInstalling?() != true }

    init(preview: Bool = false, previewStress: Bool = false, demo: Bool = false) {
        demoMode = demo
        service = (preview || demo) ? nil : AccountService()
        claudeService = (preview || demo) ? nil : ClaudeAccountService()
        if preview || demo { snapshot = Self.previewSnapshot(stress: previewStress) }
        if preview || demo {
            let now = Date()
            claudeSnapshot = AccountSnapshot(accounts: [
                SavedAccountView(id: "claude-demo-a", displayName: "Claude Arbeit", email: "arbeit@example.com", isActive: true,
                    usage: AccountUsage(fiveHourRemaining: 76, weeklyRemaining: 38, fiveHourReset: now.addingTimeInterval(7200),
                        weeklyReset: now.addingTimeInterval(200000), fetchedAt: now, fiveHourWindowMinutes: 300, weeklyWindowMinutes: 10080),
                    error: nil, provider: .claude),
                SavedAccountView(id: "claude-demo-b", displayName: "Claude Privat", email: "privat@example.com", isActive: false,
                    usage: AccountUsage(fiveHourRemaining: 95, weeklyRemaining: 82, fiveHourReset: now.addingTimeInterval(10000),
                        weeklyReset: now.addingTimeInterval(400000), fetchedAt: now, fiveHourWindowMinutes: 300, weeklyWindowMinutes: 10080),
                    error: nil, provider: .claude)
            ], cliPath: nil, currentAccountLabel: "Claude Arbeit", notice: nil)
        }
        if !preview && !demo {
            selectedProvider = AccountProvider(rawValue: UserDefaults.standard.string(forKey: "selectedAccountProvider") ?? "codex") ?? .codex
        }
        if CommandLine.arguments.contains("--claude") { selectedProvider = .claude }
    }

    func providerChanged() {
        if !demoMode { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedAccountProvider") }
        error = nil
        load()
    }

    func load() {
        if selectedProvider == .claude {
            guard canStartOperation else { return }
            if claudeSnapshot == nil { performClaude("Konten laden", refreshAfter: true) { try await $0.snapshot() } }
            else { refresh(allowPrompt: false) }
            return
        }
        guard service != nil else { return }
        guard canStartOperation else { return }
        if snapshot == nil {
            perform("Konten laden", refreshAfter: true) { service in try await service.snapshot() }
        } else if lastRefreshAttempt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            refresh(allowPrompt: false)
        }
    }

    func refresh(allowPrompt: Bool = true) {
        if selectedProvider == .claude {
            performClaude("Limits aktualisieren") { try await $0.refresh(allowPrompt: allowPrompt) }
            return
        }
        guard service != nil else { return }
        guard canStartOperation else { return }
        lastRefreshAttempt = Date()
        perform("Limits aktualisieren") { service in try await service.refresh() }
    }

    func add(name: String) {
        guard canStartOperation else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if demoMode {
            guard !cleanName.isEmpty, let current = displaySnapshot else { return }
            let account = SavedAccountView(id: UUID().uuidString, displayName: cleanName, email: "demo@example.com", isActive: false, usage: nil, error: nil, provider: selectedProvider)
            let result = AccountSnapshot(accounts: current.accounts + [account], cliPath: nil, currentAccountLabel: current.currentAccountLabel, notice: current.notice)
            if selectedProvider == .claude { claudeSnapshot = result } else { snapshot = result }
            return
        }
        let callback = progressCallback
        if selectedProvider == .claude {
            performClaude("Konto anmelden", refreshAfter: true) { try await $0.addAccount(displayName: cleanName, progress: callback) }
            return
        }
        perform("Konto anmelden", refreshAfter: true) { service in
            try await service.addAccount(displayName: cleanName, progress: callback)
        }
    }

    func switchAccount(_ account: SavedAccountView) {
        guard canStartOperation else { return }
        if demoMode, let current = displaySnapshot {
            let result = AccountSnapshot(accounts: current.accounts.map {
                SavedAccountView(id: $0.id, displayName: $0.displayName, email: $0.email, isActive: $0.id == account.id, usage: $0.usage, error: $0.error, provider: $0.provider)
            }, cliPath: nil, currentAccountLabel: account.email, notice: current.notice)
            if account.provider == .claude { claudeSnapshot = result } else { snapshot = result }
            return
        }
        let callback = progressCallback
        if account.provider == .claude {
            performClaude("Konto wechseln", refreshAfter: true) { try await $0.switchAccount(id: account.id, progress: callback) }
            return
        }
        perform("Konto wechseln") { service in
            try await service.switchAccount(id: account.id, progress: callback)
        }
    }

    func remove(_ account: SavedAccountView) {
        guard canStartOperation else { return }
        if demoMode, let current = displaySnapshot {
            let result = AccountSnapshot(accounts: current.accounts.filter { $0.id != account.id }, cliPath: nil, currentAccountLabel: current.currentAccountLabel, notice: current.notice)
            if account.provider == .claude { claudeSnapshot = result } else { snapshot = result }
            return
        }
        if account.provider == .claude {
            performClaude("Konto entfernen") { try await $0.removeAccount(id: account.id) }
            return
        }
        perform("Konto entfernen") { service in try await service.removeAccount(id: account.id) }
    }

    func openCodex() {
        guard canStartOperation else { return }
        if demoMode { return }
        perform("Codex öffnen") { service in try await service.openCodex() }
    }

    func cancel() {
        guard busy, operation == "Konto anmelden", !cancelling else { return }
        cancelling = true
        progress = "Anmeldung wird abgebrochen …"
        task?.cancel()
    }

    private func perform(_ title: String, refreshAfter: Bool = false, body: @escaping @Sendable (AccountService) async throws -> AccountSnapshot) {
        guard canStartOperation, let service else { return }
        operation = title
        progress = title == "Konto anmelden" ? "Browser-Anmeldung wird vorbereitet …" : "Bitte warten …"
        error = nil
        showOpenCodexAction = false
        cancelling = false
        task = Task { [weak self] in
            var succeeded = false
            do {
                let result = try await body(service)
                self?.snapshot = result
                if title == "Konten laden", let claude = self?.claudeService {
                    self?.claudeSnapshot = try? await claude.snapshot()
                }
                if title == "Limits aktualisieren", let claude = self?.claudeService {
                    self?.claudeSnapshot = try? await claude.refresh()
                }
                self?.showOpenCodexAction = false
                succeeded = true
            } catch {
                let message: String
                if Task.isCancelled || error is CancellationError {
                    message = "Anmeldung abgebrochen."
                } else {
                    message = error.localizedDescription
                }
                if let actual = try? await service.snapshot() { self?.snapshot = actual }
                self?.error = message
                self?.showOpenCodexAction = title == "Konto wechseln" || title == "Codex öffnen"
            }
            self?.operation = nil
            self?.progress = ""
            self?.cancelling = false
            self?.task = nil
            if refreshAfter, succeeded { self?.refresh(allowPrompt: false) }
        }
    }

    private func performClaude(_ title: String, refreshAfter: Bool = false,
                              body: @escaping @Sendable (ClaudeAccountService) async throws -> AccountSnapshot) {
        guard canStartOperation, let claudeService else { return }
        operation = title; progress = "Bitte warten …"; error = nil; cancelling = false; showOpenCodexAction = false
        task = Task { [weak self] in
            var succeeded = false
            do {
                self?.claudeSnapshot = try await body(claudeService); succeeded = true
            } catch {
                let message = Task.isCancelled || error is CancellationError ? "Anmeldung abgebrochen." : error.localizedDescription
                if !Task.isCancelled { self?.claudeSnapshot = try? await claudeService.snapshot() }
                self?.error = message
            }
            self?.operation = nil; self?.progress = ""; self?.cancelling = false; self?.task = nil
            if refreshAfter, succeeded { self?.refresh(allowPrompt: false) }
        }
    }

    private var progressCallback: AccountProgress {
        { [weak self] message in await self?.setProgress(message) }
    }

    private func setProgress(_ message: String) {
        if !cancelling { progress = message }
    }

    static func previewSnapshot(stress: Bool) -> AccountSnapshot {
        let now = Date()
        var rows = [
            SavedAccountView(id: "sample-a", displayName: "Privat", email: "privat@example.com", isActive: true,
                usage: AccountUsage(fiveHourRemaining: nil, weeklyRemaining: 63, fiveHourReset: nil, weeklyReset: now.addingTimeInterval(180000), fetchedAt: now, weeklyWindowMinutes: 10080), error: nil),
            SavedAccountView(id: "sample-b", displayName: "Arbeit", email: "arbeit@example.com", isActive: false,
                usage: AccountUsage(fiveHourRemaining: nil, weeklyRemaining: 28, fiveHourReset: nil, weeklyReset: now.addingTimeInterval(260000), fetchedAt: now, weeklyWindowMinutes: 10080), error: nil)
        ]
        if stress {
            rows[1] = SavedAccountView(id: "sample-b", displayName: "Arbeit", email: "arbeit@example.com", isActive: false,
                usage: AccountUsage(fiveHourRemaining: 12, weeklyRemaining: 28, fiveHourReset: now.addingTimeInterval(1500), weeklyReset: now.addingTimeInterval(260000), fetchedAt: now.addingTimeInterval(-3600), fiveHourWindowMinutes: 300, weeklyWindowMinutes: 10080), error: "Die Anmeldung ist abgelaufen. Bitte das Konto erneut im Browser anmelden.")
            rows.append(SavedAccountView(id: "sample-c", displayName: "Projekt", email: "projekt@example.com", isActive: false, usage: nil, error: "Limits konnten nicht gelesen werden."))
        }
        return AccountSnapshot(accounts: rows, cliPath: nil, currentAccountLabel: "privat@example.com", notice: nil)
    }
}
