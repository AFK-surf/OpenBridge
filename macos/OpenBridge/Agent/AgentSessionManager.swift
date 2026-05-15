import Combine
import Foundation
import JSBridge
import OSLog

private func elapsedMilliseconds(since start: Date) -> Int {
    max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
}

private func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

// MARK: - Agent Session Manager

/// Central manager for local agent chat sessions.
@MainActor
final class AgentSessionManager {
    static let shared = AgentSessionManager()

    // Agent config for the local runtime.
    private var agentConfig: LocalAgentConfig?
    private var configTask: Task<LocalAgentConfig, Error>?
    private var runtimeBootstrapTask: Task<Void, Never>?

    // Local environment connectors.
    private(set) var connector: LocalRuntimeConnector?
    private(set) var vmConnector: LocalRuntimeConnector?
    private var embeddedVMBridge: EmbeddedVMRuntimeBridge?
    private var vmBridgeShutdownTask: Task<Void, Never>?
    private var vmBridgeShutdownToken: UUID?
    private var heartbeatMonitorTask: Task<Void, Never>?
    private var lastObservedHeartbeatSurface: HeartbeatSurfaceObservation?

    // Ready state
    var isVMReady = false
    var vmLoadError: Error?

    /// Fires when sessions are added or removed.
    let sessionListDidChange = PassthroughSubject<Void, Never>()
    let runtimeDidReset = PassthroughSubject<Void, Never>()
    let heartbeatResultDidReceive = PassthroughSubject<HeartbeatRunResult, Never>()

    /// Session management
    private var sessions: [String: LocalAgentSession] = [:] {
        didSet { sessionListDidChange.send() }
    }

    /// All currently loaded (in-memory) sessions.
    var loadedSessions: [LocalAgentSession] {
        Array(sessions.values)
    }

    private let logger = Logger(subsystem: Logger.loggingSubsystem, category: "AgentSessionManager")

    private init() {}

    // MARK: - Lifecycle

    /// Local agent runtime is created lazily per chat session.
    nonisolated func preload() {
        Task { @MainActor in
            AgentSessionManager.shared.isVMReady = true
        }
    }

    func waitUntilReady(timeout: Duration = .seconds(10)) async throws {
        _ = timeout
        isVMReady = true
        vmLoadError = nil
    }

    func ensureConfigLoaded() async throws -> LocalAgentConfig {
        throw AgentConfigError.featureUnavailable("Local agent config")
    }

    func shutdown() {
        resetRuntime()
    }

    private func startRuntimeBootstrapIfNeeded() {
        guard runtimeBootstrapTask == nil else { return }
        runtimeBootstrapTask = Task { [weak self] in
            guard let self else { return }
            await runRuntimeBootstrapLoop()
        }
    }

    private func runRuntimeBootstrapLoop() async {
        var retryDelaySeconds = 2
        defer { runtimeBootstrapTask = nil }

        while !Task.isCancelled {
            vmLoadError = nil
            configTask = nil

            do {
                _ = try await ensureRuntimeReady()
                logger.info("Local agent config loaded")
                return
            } catch {
                if Task.isCancelled {
                    return
                }

                logger.warning("Local agent config failed: \(error.localizedDescription)")
            }

            do {
                try await Task.sleep(for: .seconds(retryDelaySeconds))
            } catch {
                return
            }
            retryDelaySeconds = min(retryDelaySeconds * 2, 30)
        }
    }

    // MARK: - Local Environment Connector

    private func startConnectorIfEnabled(config: LocalAgentConfig) async {
        if connector == nil {
            let newConnector = LocalRuntimeConnector(
                agentGroupId: config.agentGroupId,
                environmentKind: .localMacOS,
                target: .localMacOS
            )
            connector = newConnector
            newConnector.connect()
            logger.info("Local macOS connector started")
        }

        if SettingsManager.shared.enableLocalVMEnvironment {
            if vmConnector == nil {
                await waitForPendingVMBridgeShutdown()
                guard SettingsManager.shared.enableLocalVMEnvironment, vmConnector == nil else {
                    return
                }
                let bridge = embeddedVMBridge ?? EmbeddedVMRuntimeBridge()
                embeddedVMBridge = bridge
                let newConnector = LocalRuntimeConnector(
                    agentGroupId: config.agentGroupId,
                    environmentKind: .localVM,
                    target: .embeddedVM(bridge)
                )
                vmConnector = newConnector
                newConnector.connect()
                logger.info("Local VM connector started")
            }
        } else if vmConnector != nil || embeddedVMBridge != nil {
            disconnectVMConnector(shutdownBridge: true)
            logger.info("Local VM connector disabled")
        }
    }

    func refreshConnectorConfiguration() {
        isVMReady = true
        vmLoadError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ensureRuntimeReady()
                await refreshLoadedSessionRuntimeConfiguration()
            } catch {
                vmLoadError = error
                logger.warning("Failed to refresh local connector configuration: \(error.localizedDescription)")
            }
        }
    }

    func restartConnector() {
        connector?.disconnect()
        connector = nil
        disconnectVMConnector()
        isVMReady = true
    }

    func applyLocalEnvironmentPermissionModeChange(_ mode: LocalEnvironmentPermissionMode) {
        connector?.applyPermissionModeChange(mode)
        Task { [weak self] in
            guard let self else { return }
            await refreshLoadedSessionRuntimeConfiguration()
        }
    }

    func reloadAIProviderConfiguration() async {
        await BridgeAIProviderRegistry.registerProviders()
        await refreshLoadedSessionRuntimeConfiguration()
    }

    private func refreshLoadedSessionRuntimeConfiguration() async {
        for session in sessions.values {
            await session.refreshRuntimeConfiguration()
        }
    }

    private func disconnectVMConnector(shutdownBridge: Bool = false) {
        guard vmConnector != nil || embeddedVMBridge != nil else { return }
        vmConnector?.disconnect()
        vmConnector = nil
        if shutdownBridge {
            scheduleVMBridgeShutdown(embeddedVMBridge)
            embeddedVMBridge = nil
        } else {
            cancelPendingVMBridgeShutdown()
        }
    }

    func connectorForLocalTool(environment rawEnvironment: String?) async throws -> LocalRuntimeConnector {
        _ = try await ensureRuntimeReady()

        let normalized = rawEnvironment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == nil || normalized?.isEmpty == true || normalized == "sandbox" || normalized?.hasPrefix("sandbox-") == true {
            if SettingsManager.shared.enableLocalVMEnvironment, let vmConnector {
                return vmConnector
            }
            if normalized == "sandbox" || normalized?.hasPrefix("sandbox-") == true {
                throw AgentConfigError.featureUnavailable("Sandbox environment")
            }
            if let connector {
                return connector
            }
        }

        if normalized == "local" || normalized?.hasPrefix("local-") == true {
            if let connector {
                return connector
            }
            throw AgentConfigError.featureUnavailable("Local environment")
        }

        throw AgentConfigError.featureUnavailable("Environment \(rawEnvironment ?? "")")
    }

    func localEnvironmentSystemPromptSection() async throws -> String {
        _ = try await ensureRuntimeReady()

        let environments = [vmConnector, connector].compactMap(\.self)
        guard !environments.isEmpty else { return "" }

        let entries = environments
            .map { connector in
                """
                <environment>
                  <name>\(connector.environmentKind.connectName)</name>
                  <alias>\(connector.environmentKind.connectAlias)</alias>
                  <description>\(xmlEscaped(connector.localDescription()))</description>
                </environment>
                """
            }
            .joined(separator: "\n")

        return """
        ## Available Environments

        This is the current environment inventory at agent startup. It mirrors ListEnvironments and includes mounted sandbox folders when available.

        <environments>
        \(entries)
        </environments>
        """
    }

    var initialSystemReminder: String? {
        guard let reminder = agentConfig?.systemReminder?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !reminder.isEmpty
        else {
            return nil
        }
        return reminder
    }

    /// Injects a message into the session identified by `sessionID`. Falls back to
    /// the most recently loaded session when no ID is provided. Returns `false`
    /// when no matching session is found so the caller can deny the request
    /// immediately rather than suspending indefinitely.
    @discardableResult
    func injectMessage(_ message: SessionHistoryMessage, intoSessionID sessionID: String?) -> Bool {
        let session =
            if let sessionID {
                sessions[sessionID]
            } else {
                sessions.values.max(by: { $0.sessionID < $1.sessionID })
            }
        guard let session else {
            logger.warning("No session available for connector confirmation (session_id=\(sessionID ?? "nil"))")
            return false
        }
        session.injectMessage(message)
        return true
    }

    func resolveConnectorConfirmation(id: String, approved: Bool, mode: String? = nil) -> Bool {
        for session in sessions.values where session.canResolveLocalConfirmation(id: id) {
            session.resolveLocalConfirmation(id: id, approved: approved, mode: mode)
            return true
        }
        for connector in [connector, vmConnector].compactMap(\.self) {
            if connector.canResolveSessionConfirmation(id: id) {
                connector.resolveSessionConfirmation(id: id, approved: approved, mode: mode)
                return true
            }
        }
        return false
    }

    func clearLocalPermission(sessionId: String) {
        connector?.clearSessionPermission(sessionId: sessionId)
    }

    // MARK: - Config Loading

    private func ensureConfig() async throws -> LocalAgentConfig {
        if let config = agentConfig { return config }

        if let task = configTask {
            return try await task.value
        }

        let task = Task<LocalAgentConfig, Error> {
            LocalAgentConfig(
                agentGroupId: "local",
                agentId: "local",
                systemReminder: nil,
                availableTemplates: []
            )
        }
        configTask = task

        do {
            let config = try await task.value
            agentConfig = config
            isVMReady = true
            vmLoadError = nil
            configTask = nil
            return config
        } catch {
            isVMReady = false
            vmLoadError = error
            configTask = nil
            throw error
        }
    }

    private func ensureRuntimeReady() async throws -> LocalAgentConfig {
        let config = try await ensureConfig()
        await startConnectorIfEnabled(config: config)
        startHeartbeatMonitorIfNeeded()
        return config
    }

    private func scheduleVMBridgeShutdown(_ bridge: EmbeddedVMRuntimeBridge?) {
        guard let bridge else { return }
        let previousTask = vmBridgeShutdownTask
        let token = UUID()
        vmBridgeShutdownToken = token
        vmBridgeShutdownTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await bridge.shutdown()
            await MainActor.run {
                guard self?.vmBridgeShutdownToken == token else { return }
                self?.vmBridgeShutdownTask = nil
                self?.vmBridgeShutdownToken = nil
            }
        }
    }

    private func cancelPendingVMBridgeShutdown() {
        vmBridgeShutdownToken = nil
        vmBridgeShutdownTask?.cancel()
        vmBridgeShutdownTask = nil
    }

    private func waitForPendingVMBridgeShutdown() async {
        let token = vmBridgeShutdownToken
        guard let task = vmBridgeShutdownTask else { return }
        await task.value
        guard vmBridgeShutdownToken == token else { return }
        vmBridgeShutdownTask = nil
        vmBridgeShutdownToken = nil
    }

    private func startHeartbeatMonitorIfNeeded() {
        guard heartbeatMonitorTask == nil else { return }
        heartbeatMonitorTask = Task { [weak self] in
            guard let self else { return }
            await runHeartbeatMonitor()
        }
    }

    private func runHeartbeatMonitor() async {
        await primeHeartbeatMonitor()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled {
                return
            }
            await pollHeartbeatSurfaceSessions()
        }
    }

    private func primeHeartbeatMonitor() async {
        lastObservedHeartbeatSurface = nil
    }

    private func pollHeartbeatSurfaceSessions() async {
        lastObservedHeartbeatSurface = nil
    }

    private func buildHeartbeatRunResult(
        sessionID: String,
        fallbackTitle: String?,
        fallbackSummary: String?,
        runAt: Int64
    ) async throws -> HeartbeatRunResult {
        let title: String
        title = AgentHeartbeatDefaults.normalizedString(fallbackTitle) ?? AgentHeartbeatDefaults.normalizedSurfaceTitle("")

        if let fallbackSummary = AgentHeartbeatDefaults.normalizedString(fallbackSummary) {
            return HeartbeatRunResult(sessionID: sessionID, title: title, summary: fallbackSummary, runAt: runAt)
        }

        let summary = title
        return HeartbeatRunResult(sessionID: sessionID, title: title, summary: summary, runAt: runAt)
    }

    private func resetRuntime() {
        isVMReady = false
        vmLoadError = nil
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = nil
        configTask?.cancel()
        configTask = nil
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        lastObservedHeartbeatSurface = nil
        agentConfig = nil
        connector?.disconnect()
        connector = nil
        disconnectVMConnector()
        sessions.removeAll()
        runtimeDidReset.send()
    }

    // MARK: - Session Lifecycle

    /// Create a new session.
    func createSession(interactionMode _: String = "") async throws -> LocalAgentSession {
        try await waitUntilReady()
        let sessionID = "local-\(UUID().uuidString)"
        let session = LocalAgentSession(sessionID: sessionID)
        try await session.setup()
        sessions[sessionID] = session
        LocalAgentSessionStore.save(LocalAgentSessionRecord(
            id: sessionID,
            title: session.currentTitleForList,
            createdAt: session.listCreatedAt ?? Int64(Date().timeIntervalSince1970),
            updatedAt: session.listUpdatedAt ?? Int64(Date().timeIntervalSince1970),
            messages: session.historyMessages
        ))
        logger.info("Created local session: \(sessionID)")
        return session
    }

    /// Load an existing session.
    func loadSession(sessionId: String) async throws -> LocalAgentSession {
        #if DEBUG
            if let fixture = E2EConversationSearchFixture.current,
               fixture.sessionID == sessionId
            {
                if let existing = sessions[sessionId] {
                    return existing
                }
                let session = LocalAgentSession(sessionID: fixture.sessionID)
                session.loadLocalFixture(
                    title: fixture.sessionTitle,
                    messages: [fixture.historyMessage]
                )
                sessions[fixture.sessionID] = session
                logger.info("Loaded E2E fixture session: \(fixture.sessionID)")
                return session
            }
        #endif

        if let existing = sessions[sessionId] {
            return existing
        }
        let session = if let record = LocalAgentSessionStore.load(sessionID: sessionId) {
            LocalAgentSession(record: record)
        } else {
            LocalAgentSession(sessionID: sessionId)
        }
        try await session.setup()
        sessions[sessionId] = session
        logger.info("Loaded session: \(sessionId)")
        return session
    }

    /// Get session by ID.
    func getSession(_ sessionId: String) -> LocalAgentSession? {
        sessions[sessionId]
    }

    func updateActiveLocalAgentModel(provider: String, modelID: String) async {
        for session in sessions.values {
            await session.updateLocalAgentModel(provider: provider, modelID: modelID)
        }
    }

    func setSessionHidden(sessionId: String, hidden: Bool) async throws {
        _ = sessionId
        _ = hidden
    }

    /// List all sessions.
    func listSessions() async throws -> [SessionListInfo] {
        #if DEBUG
            if let fixture = E2EConversationSearchFixture.current {
                let now = Int64(Date().timeIntervalSince1970)
                return [SessionListInfo(
                    id: fixture.sessionID,
                    title: fixture.sessionTitle,
                    messageCount: 1,
                    lastMessagePreview: fixture.snippet,
                    createdAt: now,
                    updatedAt: now
                )]
            }
        #endif

        let storedSessions = LocalAgentSessionStore.list().map { record in
            SessionListInfo(
                id: record.id,
                title: record.title,
                messageCount: record.messages.count,
                lastMessagePreview: record.messages.reversed().compactMap { message in
                    message.content?.compactMap(\.text).joined(separator: "\n")
                }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        }

        let mappedSessions = sessions.values.map { session in
            SessionListInfo(
                id: session.sessionID,
                title: session.currentTitleForList,
                messageCount: nil,
                lastMessagePreview: session.lastMessagePreviewForList,
                createdAt: session.listCreatedAt ?? 0,
                updatedAt: session.listUpdatedAt ?? session.listCreatedAt ?? 0
            )
        }
        let merged = Dictionary(grouping: storedSessions + mappedSessions, by: \.id)
            .compactMap { _, values in
                values.max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
            }
        return SessionListInfo.sortedNewestFirst(merged)
    }

    /// Delete a session.
    func deleteSession(sessionId: String) async throws {
        ChatViewModel.shared.removeChat(conversationId: sessionId)
        if let session = sessions[sessionId] {
            await session.teardown()
        }
        sessions.removeValue(forKey: sessionId)
        LocalAgentSessionStore.delete(sessionID: sessionId)
        clearLocalPermission(sessionId: sessionId)
        if let bridge = embeddedVMBridge {
            do {
                try await bridge.deleteSessionState(sessionID: sessionId)
            } catch {
                logger.warning("Failed to cleanup local VM state for deleted session \(sessionId): \(error.localizedDescription)")
            }
        }
    }

    func deleteSessionIfPristine(sessionId: String) async -> Bool {
        if let session = sessions[sessionId],
           !session.historyMessages.isEmpty || session.isProcessing || session.hasOpenTask
        {
            return false
        }
        if let record = LocalAgentSessionStore.load(sessionID: sessionId),
           !record.messages.isEmpty
        {
            return false
        }

        do {
            try await deleteSession(sessionId: sessionId)
            logger.info("Deleted pristine session: \(sessionId)")
            return true
        } catch {
            logger.warning("Failed to delete pristine session \(sessionId): \(error.localizedDescription)")
            return false
        }
    }

    /// Rename a session.
    func renameSession(sessionId: String, title: String) async throws {
        if let session = sessions[sessionId] {
            session.setLocalTitle(title)
            return
        }
        guard var record = LocalAgentSessionStore.load(sessionID: sessionId) else { return }
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.updatedAt = Int64(Date().timeIntervalSince1970)
        LocalAgentSessionStore.save(record)
    }

    // MARK: - Local VM Workspace Review

    func localVMWorkspaceState(sessionId: String) async throws -> WorkspaceState? {
        guard SettingsManager.shared.enableLocalVMEnvironment,
              let bridge = embeddedVMBridge
        else {
            return nil
        }
        return try await bridge.workspaceState(sessionID: sessionId)
    }

    func localVMWorkspaceFileForPreview(sessionId: String, path: String, environmentID: String) async throws -> String {
        guard SettingsManager.shared.enableLocalVMEnvironment,
              let bridge = embeddedVMBridge
        else {
            throw AgentConfigError.featureUnavailable("Local VM workspace review")
        }
        return try await bridge.previewFile(sessionID: sessionId, path: path, environmentID: environmentID)
    }

    func acceptLocalVMWorkspaceFiles(sessionId: String, paths: [String]) async throws -> EmbeddedVMRuntimeBridge.ReviewActionResult {
        guard SettingsManager.shared.enableLocalVMEnvironment,
              let bridge = embeddedVMBridge
        else {
            throw AgentConfigError.featureUnavailable("Local VM workspace review")
        }
        return try await bridge.acceptChanges(sessionID: sessionId, paths: paths)
    }

    func discardLocalVMWorkspaceChanges(sessionId: String) async throws -> EmbeddedVMRuntimeBridge.ReviewActionResult {
        guard SettingsManager.shared.enableLocalVMEnvironment,
              let bridge = embeddedVMBridge
        else {
            throw AgentConfigError.featureUnavailable("Local VM workspace review")
        }
        return try await bridge.discardAllChanges(sessionID: sessionId)
    }

    // MARK: - Stubs for removed local-only features

    func resetAgentImage(includeCurrentImage _: Bool) async throws -> Int64 {
        0
    }

    func startTelegramBot(token _: String) async throws {
        throw AgentConfigError.featureUnavailable("Telegram bot")
    }

    func stopTelegramBot() async throws {}

    var telegramBotEnabled: Bool {
        false
    }

    func telegramBotRuntimeStatus() async -> TelegramBotRuntimeStatus {
        .stopped
    }

    func triggerHeartbeat(prompt: String) async throws {
        _ = prompt
        throw AgentConfigError.featureUnavailable("Heartbeat")
    }
}

// MARK: - Session List Info

@JSBridgeType
struct SessionListInfo: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    let messageCount: Int?
    let lastMessagePreview: String?
    let createdAt: Int64
    let updatedAt: Int64

    static func sortedNewestFirst(_ sessions: [SessionListInfo]) -> [SessionListInfo] {
        sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id > rhs.id
        }
    }
}

// MARK: - Errors

enum AgentConfigError: LocalizedError {
    case timeout
    case featureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            "Agent configuration timed out"
        case let .featureUnavailable(name):
            "\(name) is not available in this local agent mode"
        }
    }
}

struct HeartbeatRunResult: Sendable {
    let sessionID: String
    let title: String
    let summary: String
    let runAt: Int64
}

extension HeartbeatRunResult {
    var notificationIdentifier: String {
        "openbridge.heartbeat.\(sessionID).\(runAt)"
    }
}

struct HeartbeatSurfaceObservation: Equatable {
    let sessionID: String
    let runAt: Int64
}

extension LocalAgentHeartbeat {
    var surfaceObservation: HeartbeatSurfaceObservation? {
        guard let sessionID = lastSurfaceSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let lastRunAt
        else {
            return nil
        }
        return HeartbeatSurfaceObservation(sessionID: sessionID, runAt: lastRunAt)
    }
}

private enum AgentHeartbeatDefaults {
    static let skippedOverlapStatus = "skipped_overlap"

    static func normalizedSurfaceTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Heartbeat") : trimmed
    }

    static func extractSurfaceSummary(from messages: [LocalAgentStoredMessage]) -> String? {
        for message in messages where message.role == "assistant" {
            guard let text = extractText(from: message.content),
                  let normalized = normalizedString(text)
            else {
                continue
            }
            return normalized
        }
        return nil
    }

    static func normalizedString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractText(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return raw
        }

        if let arr = json as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n")
        }

        if let obj = json as? [String: Any], let text = obj["text"] as? String {
            return text
        }

        return raw
    }
}

private enum AgentHeartbeatError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            String(localized: "A heartbeat is already running.")
        }
    }
}

// MARK: - Stub Types (previously from Go sandbox vm)

struct TelegramBotRuntimeStatus: Sendable {
    let enabled: Bool
    let running: Bool
    let online: Bool
    let retryAttempt: Int
    let lastError: String
    let lastErrorAt: Int64
    let nextRetryAt: Int64
    let lastOnlineAt: Int64

    static let stopped = TelegramBotRuntimeStatus(
        enabled: false,
        running: false,
        online: false,
        retryAttempt: 0,
        lastError: "",
        lastErrorAt: 0,
        nextRetryAt: 0,
        lastOnlineAt: 0
    )

    var hasError: Bool {
        !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
