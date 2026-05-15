import Foundation
import KWWKAgent
import KWWKAI
import KWWKComputerUseCore
import OSLog

private let logger = Logger(subsystem: Logger.loggingSubsystem, category: "LocalAgentSession")

private func elapsedMilliseconds(since start: Date) -> Int {
    max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
}

private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

@MainActor
private func debugTemplateOverride() -> String? {
    guard SettingsManager.shared.enableDebugMode else { return nil }
    return trimmedNonEmpty(SettingsManager.shared.lastSelectedAgentTemplateID)
}

/// Local agent session that owns one conversation's message history and task state.
@MainActor @Observable
final class LocalAgentSession: Identifiable {
    let sessionID: String
    private let adapter = LocalAgentEventAdapter()
    private let computerUseClientStore = OpenBridgeComputerUseClientStore()

    private(set) var listCreatedAt: Int64?
    private(set) var listUpdatedAt: Int64?
    private(set) var listPurpose: String?
    private(set) var isProcessing: Bool = false
    private(set) var lastFinishState: String?
    private(set) var lastWaitReason: String?
    private(set) var assistantState: AssistantState?
    private(set) var workspaceState: WorkspaceState?
    private(set) var activeClient: String = "macos"

    private(set) var messages: [SessionHistoryMessage] = []
    private var eventListeners: [UUID: @Sendable (SessionHistoryEvent) -> Void] = [:]
    private var stopRequestListeners: [UUID: @Sendable () -> Void] = [:]
    private var streamTask: Task<Void, Never>?
    private var localAgent: Agent?
    private var localBackgroundManager: BackgroundTaskManager?
    private var localAgentUnsubscribe: Unsubscribe?
    private var localRunTask: Task<Void, Never>?
    private var pendingRuntimeConfigurationRefresh = false
    private var localAssistantMessageID: String?
    private var localAssistantText = ""
    private var localToolStates: [String: AssistantToolCallState] = [:]
    private var localPendingConfirmations: [String: CheckedContinuation<PermissionConfirmationReply, Never>] = [:]
    private var localAssistantSequence = 0
    private var localAssistantPhase = "idle"
    private var localAssistantPhaseStartedAt: Double = 0
    private var sessionTitle: String = ""
    private var lastEventID: String?
    private var isRestoringLocalRecord = false
    var shouldInjectInitialSystemReminder = true
    var pendingLocalContextReminders: [String] = []
    var appRequestHandledInCurrentRound = false
    var appRequestToken = 0

    var hasOpenTask: Bool {
        if lastFinishState == "waiting" {
            return true
        }
        guard hasRunningTaskInHistory else { return false }
        return isProcessing
    }

    var isWaiting: Bool {
        !isProcessing && lastFinishState == "waiting"
    }

    private var hasRunningTaskInHistory: Bool {
        guard let latestTaskAction = messages.last(where: { $0.type == "task" })?.action else {
            return false
        }
        return latestTaskAction == "start" || latestTaskAction == "update"
    }

    // MARK: - Callbacks

    var onSessionStarted: (() -> Void)?
    var onSessionFinished: ((_ state: String, _ error: String?) -> Void)?
    var onTitleChanged: ((_ title: String) -> Void)?

    // MARK: - Init

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    deinit {
        let computerUseClientStore = computerUseClientStore
        Task { @MainActor in
            computerUseClientStore.finishAndReset()
        }
    }

    convenience init(record: LocalAgentSessionRecord) {
        self.init(sessionID: record.id)
        loadLocalRecord(record)
    }

    // MARK: - History Access

    var historyMessages: [SessionHistoryMessage] {
        messages
    }

    var taskDisplayTitle: String {
        for message in messages.reversed() {
            guard message.type == "task" else { continue }
            if let taskTitle = trimmedNonEmpty(message.taskTitle) {
                return taskTitle
            }
        }
        if let sessionTitle = trimmedNonEmpty(sessionTitle) {
            return sessionTitle
        }
        return String(localized: "Task")
    }

    func addHistoryEventListener(_ listener: @escaping @Sendable (SessionHistoryEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        eventListeners[id] = listener
        return { [weak self] in
            Task { @MainActor [weak self] in
                self?.eventListeners.removeValue(forKey: id)
            }
        }
    }

    func addStopRequestListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        stopRequestListeners[id] = listener
        return { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopRequestListeners.removeValue(forKey: id)
            }
        }
    }

    /// Inject a locally-created message (e.g. connector confirmation) into the session history.
    func injectMessage(_ message: SessionHistoryMessage) {
        appendMessage(message)
    }

    func canResolveLocalConfirmation(id: String) -> Bool {
        localPendingConfirmations[id] != nil
    }

    func resolveLocalConfirmation(id: String, approved: Bool, mode: String? = nil) {
        guard let continuation = localPendingConfirmations.removeValue(forKey: id) else { return }
        appendMessage(makePermissionReplyMessage(confirmationId: id, approved: approved, reason: nil, mode: mode))
        continuation.resume(returning: PermissionConfirmationReply(approved: approved, mode: mode))
    }

    func loadLocalFixture(title: String, messages: [SessionHistoryMessage]) {
        sessionTitle = title
        self.messages = messages
        let now = Int64(Date().timeIntervalSince1970)
        listCreatedAt = now
        listUpdatedAt = now
    }

    func loadLocalRecord(_ record: LocalAgentSessionRecord) {
        isRestoringLocalRecord = true
        defer {
            isRestoringLocalRecord = false
            expireUnresolvedPermissionRequestsFromRestoredHistory()
        }
        sessionTitle = record.title
        messages = record.messages
        listCreatedAt = record.createdAt
        listUpdatedAt = record.updatedAt
    }

    func setup() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        listCreatedAt = listCreatedAt ?? now
        listUpdatedAt = listUpdatedAt ?? now
    }

    func teardown() async {
        streamTask?.cancel()
        streamTask = nil
        lastEventID = nil
    }

    @discardableResult
    func send(
        content: [SessionHistoryMessage.Content],
        reasoningEffort _: String? = nil,
        traceContext _: TraceContextCarrier? = nil
    ) async throws -> String {
        AgentSessionManager.shared.clearLocalPermission(sessionId: sessionID)
        isProcessing = true
        lastFinishState = nil
        lastWaitReason = nil
        onSessionStarted?()

        resetAppRequestRoundState()

        do {
            let preparedContent = try await prepareOutboundContent(content)
            guard Self.containsMeaningfulOutboundContent(preparedContent) else {
                throw LocalAgentSessionError.emptyMessage
            }
            let transportContent = makeTransportContent(from: preparedContent)

            let userMsgId = "local-\(UUID().uuidString)"
            let userMessage = makeUserHistoryMessage(id: userMsgId, content: preparedContent)
            appendMessage(userMessage)
            scheduleTitleGenerationIfNeeded()

            let agent = try await ensureLocalAgent()
            await applySelectedModel(to: agent)
            let prompt = Self.serializeOutboundContent(transportContent)
            let images = try makeLocalImageContent(from: transportContent)
            localAssistantMessageID = nil
            localAssistantText = ""
            localToolStates.removeAll()
            localAssistantPhase = "idle"
            localAssistantPhaseStartedAt = 0
            localRunTask = Task { [weak self] in
                do {
                    try await agent.prompt(prompt, images: images)
                } catch {
                    await MainActor.run {
                        self?.finishLocalRun(error: error)
                    }
                }
            }
            shouldInjectInitialSystemReminder = false
            pendingLocalContextReminders.removeAll()
            return userMsgId
        } catch {
            appendMessage(makeErrorHistoryMessage(for: error))
            isProcessing = false
            throw error
        }
    }

    @discardableResult
    func sendSynchronously(
        content: [SessionHistoryMessage.Content],
        templateOverride: String? = nil,
        reasoningEffort: String? = nil
    ) async throws -> String {
        _ = templateOverride
        let messageID = try await send(content: content, reasoningEffort: reasoningEffort)
        await localRunTask?.value
        return messageID
    }

    @discardableResult
    func cancel() async -> Bool {
        cancelLocalPendingConfirmations(reason: "expired")
        computerUseClientStore.finishAndReset()
        localAgent?.abort()
        localRunTask?.cancel()
        isProcessing = false
        lastFinishState = "cancelled"
        AgentSessionManager.shared.clearLocalPermission(sessionId: sessionID)
        updateLocalAssistantState(phase: "cancelled", isStreaming: false)
        onSessionFinished?("cancelled", nil)
        refreshRuntimeConfigurationAfterRunIfNeeded()
        return true
    }

    func settleLocalStop() {
        let output = adapter.process(eventType: "status", data: #"{"status":"paused"}"#)
        applyAdapterOutput(output, refreshSchedules: false)
    }

    func requestStop() {
        for listener in stopRequestListeners.values {
            listener()
        }
        settleLocalStop()
        Task { [weak self] in
            guard let self else { return }
            _ = await cancel()
        }
    }

    func getTitle() async throws -> String {
        if !sessionTitle.isEmpty {
            return sessionTitle
        }
        return String(localized: "New Chat")
    }

    func setTitle(_ title: String) async throws {
        setLocalTitle(title)
    }

    var currentTitleForList: String {
        sessionTitle.isEmpty ? String(localized: "New Chat") : sessionTitle
    }

    var lastMessagePreviewForList: String? {
        messages.reversed().compactMap { message in
            message.content?.compactMap(\.text).joined(separator: "\n")
        }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func setLocalTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionTitle = trimmed
        listUpdatedAt = Int64(Date().timeIntervalSince1970)
        onTitleChanged?(trimmed)
        persistLocalRecord()
    }

    // MARK: - Local KWWK Agent

    func refreshRuntimeConfiguration() async {
        guard let localAgent else { return }
        guard !isProcessing else {
            pendingRuntimeConfigurationRefresh = true
            return
        }
        pendingRuntimeConfigurationRefresh = false
        localAgent.state.model = await BridgeAIProviderRegistry.selectedModel()
        localAgent.state.systemPrompt = await makeLocalAgentSystemPrompt()
    }

    private func makeLocalAgentSystemPrompt() async -> String {
        let skillManager = SkillManager.shared
        let cwd = skillManager.skillDirs.workspace.path
        let memoryPrompt = await MemoryRepository.shared.systemPromptSection()
        let environmentInventory = try? await AgentSessionManager.shared.localEnvironmentSystemPromptSection()
        return OpenBridgeSystemPromptBuilder.build(
            cwd: cwd,
            skills: skillManager.skills,
            memory: memoryPrompt,
            computerUsePrompt: OpenBridgeComputerUseAgent.systemPromptWithStartupInventory(clientStore: computerUseClientStore),
            environmentInventory: environmentInventory
        )
    }

    private func ensureLocalAgent() async throws -> Agent {
        if let localAgent {
            return localAgent
        }

        await BridgeAIProviderRegistry.registerProviders()
        let backgroundManager = BackgroundTaskManager()
        let skillManager = SkillManager.shared
        let cwd = skillManager.skillDirs.workspace.path
        let systemPrompt = await makeLocalAgentSystemPrompt()
        localBackgroundManager = backgroundManager

        let config = await CodingAgentConfig(
            model: BridgeAIProviderRegistry.selectedModel(),
            cwd: cwd,
            tools: [],
            systemPrompt: systemPrompt,
            backgroundManager: backgroundManager,
            sessionId: sessionID,
            authResolver: BridgeAIProviderRegistry.authResolver()
        )

        let agent = await makeCodingAgent(config)
        agent.state.messages = makeKWWKMessages(from: messages)
        agent.state.tools += makeOpenBridgeCodingTools(sessionID: sessionID)
        agent.state.tools += [OpenBridgeComputerUseAgent.makeTool(
            clientStore: computerUseClientStore,
            requestStartConfirmation: { [weak self] apps in
                await self?.requestComputerUseStartConfirmation(apps: apps) ?? PermissionConfirmationReply(approved: false, mode: nil)
            }
        )]
        agent.state.tools += [makeManageTaskTool(), makeManageScheduleTool(), makeManageMemoryTool()]
        localAgentUnsubscribe = agent.subscribe { [weak self] (event: AgentEvent, _: CancellationHandle?) in
            await MainActor.run {
                self?.handleLocalAgentEvent(event)
            }
        }
        localAgent = agent
        return agent
    }

    func updateLocalAgentModel(provider: String, modelID: String) async {
        guard let model = await BridgeAIProviderRegistry.runtimeModel(provider: provider, id: modelID) else { return }
        localAgent?.state.model = model
    }

    private func applySelectedModel(to agent: Agent) async {
        agent.state.model = await BridgeAIProviderRegistry.selectedModel()
    }

    private func handleLocalAgentEvent(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            isProcessing = true
            lastFinishState = nil
            lastWaitReason = nil
            updateLocalAssistantState(phase: "thinking", isStreaming: true)
        case let .messageUpdate(message, _):
            updateLocalAssistantMessage(message)
        case let .toolExecutionStart(toolCallId, toolName, args):
            let argsText = Self.jsonString(args)
            upsertLocalToolState(
                callId: toolCallId,
                toolName: toolName,
                args: argsText,
                status: "running",
                endedAt: nil,
                success: nil,
                error: nil,
                result: nil
            )
            appendMessage(makeToolStatusHistoryMessage(
                callId: toolCallId,
                toolName: toolName,
                args: argsText,
                status: "running"
            ))
        case let .toolExecutionUpdate(toolCallId, toolName, args, partialResult):
            let argsText = Self.jsonString(args)
            upsertLocalToolState(
                callId: toolCallId,
                toolName: toolName,
                args: argsText,
                status: "running",
                endedAt: nil,
                success: nil,
                error: nil,
                result: Self.toolResultText(partialResult.content)
            )
            appendMessage(makeToolStatusHistoryMessage(
                callId: toolCallId,
                toolName: toolName,
                args: argsText,
                status: "running"
            ))
        case let .toolExecutionEnd(toolCallId, toolName, result, isError):
            let existingArgs = localToolStates[toolCallId]?.args
            upsertLocalToolState(
                callId: toolCallId,
                toolName: toolName,
                args: nil,
                status: isError ? "failed" : "completed",
                endedAt: Date().timeIntervalSince1970,
                success: !isError,
                error: isError ? Self.toolResultText(result.content) : nil,
                result: Self.toolResultText(result.content)
            )
            if toolName == "manage_task" {
                if !isError,
                   let taskMessage = makeTaskHistoryMessageFromManageTaskResult(
                       Self.toolResultText(result.content),
                       fallbackToolCallId: toolCallId,
                       fallbackArgs: existingArgs
                   )
                {
                    appendMessage(taskMessage)
                }
                break
            }
            appendMessage(makeToolStatusHistoryMessage(
                callId: toolCallId,
                toolName: toolName,
                args: existingArgs,
                status: isError ? "failed" : "completed"
            ))
        case let .agentEnd(messages, summary):
            finishLocalRun(error: Self.localAgentRunError(from: messages, summary: summary))
        default:
            break
        }
    }

    private func finishLocalRun(error: Error?) {
        if let error {
            appendMessage(makeErrorHistoryMessage(for: error))
        }
        cancelLocalPendingConfirmations(reason: "expired")
        computerUseClientStore.finishAndReset()
        isProcessing = false
        lastFinishState = error == nil ? "completed" : "failed"
        AgentSessionManager.shared.clearLocalPermission(sessionId: sessionID)
        updateLocalAssistantState(phase: lastFinishState ?? "completed", isStreaming: false)
        onSessionFinished?(lastFinishState ?? "completed", error?.localizedDescription)
        refreshRuntimeConfigurationAfterRunIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await refreshWorkspaceState()
        }
    }

    private func refreshRuntimeConfigurationAfterRunIfNeeded() {
        guard pendingRuntimeConfigurationRefresh else { return }
        Task { [weak self] in
            guard let self else { return }
            await refreshRuntimeConfiguration()
        }
    }

    private func requestComputerUseStartConfirmation(apps: [String]) async -> PermissionConfirmationReply {
        let confirmationId = "local-\(UUID().uuidString)"
        let message = makeComputerUsePermissionRequestMessage(confirmationId: confirmationId, apps: apps)
        return await withCheckedContinuation { continuation in
            localPendingConfirmations[confirmationId] = continuation
            appendMessage(message)
        }
    }

    private func cancelLocalPendingConfirmations(reason: String) {
        let pending = localPendingConfirmations
        localPendingConfirmations.removeAll()
        for (confirmationId, continuation) in pending {
            appendMessage(makePermissionReplyMessage(
                confirmationId: confirmationId,
                approved: false,
                reason: reason,
                mode: nil
            ))
            continuation.resume(returning: PermissionConfirmationReply(approved: false, mode: nil))
        }
    }

    private func expireUnresolvedPermissionRequestsFromRestoredHistory() {
        let repliedConfirmationIds = Set(messages.compactMap { message -> String? in
            guard message.type == "permission_reply" else { return nil }
            return message.confirmationId
        })
        let unresolvedConfirmationIds = messages.compactMap { message -> String? in
            guard message.type == "permission_request",
                  message.permissionRequest != nil,
                  let confirmationId = message.confirmationId,
                  !repliedConfirmationIds.contains(confirmationId)
            else {
                return nil
            }
            return confirmationId
        }
        guard !unresolvedConfirmationIds.isEmpty else { return }

        for confirmationId in unresolvedConfirmationIds {
            messages.append(makePermissionReplyMessage(
                confirmationId: confirmationId,
                approved: false,
                reason: "expired",
                mode: nil
            ))
        }
        listUpdatedAt = Int64(Date().timeIntervalSince1970)
        persistLocalRecord()
    }

    private func updateLocalAssistantMessage(_ message: AssistantMessage) {
        let text = message.content.compactMap { block -> String? in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined()
        guard !text.isEmpty else { return }

        localAssistantText = text
        let messageID = localAssistantMessageID ?? "local-assistant-\(UUID().uuidString)"
        localAssistantMessageID = messageID
        appendMessage(makeAssistantHistoryMessage(id: messageID, text: text))
        updateLocalAssistantState(phase: "messaging", isStreaming: true)
    }

    private func updateLocalAssistantState(phase: String, isStreaming: Bool) {
        let now = Date().timeIntervalSince1970
        if localAssistantPhase != phase {
            localAssistantSequence += 1
            localAssistantPhase = phase
            localAssistantPhaseStartedAt = now
        }

        assistantState = AssistantState(
            phase: phase,
            sequence: localAssistantSequence,
            phaseStartedAt: localAssistantPhaseStartedAt,
            updatedAt: now,
            reasoning: nil,
            messaging: AssistantStageStreamState(
                messageId: localAssistantMessageID,
                responseId: nil,
                text: localAssistantText,
                isStreaming: isStreaming
            ),
            tools: localToolStates.values.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.callId < rhs.callId
            },
            asyncToolcalls: []
        )
    }

    private func upsertLocalToolState(
        callId: String,
        toolName: String,
        args: String?,
        status: String,
        endedAt: Double?,
        success: Bool?,
        error: String?,
        result: String?
    ) {
        let existing = localToolStates[callId]
        let startedAt = existing?.startedAt ?? Date().timeIntervalSince1970
        localToolStates[callId] = AssistantToolCallState(
            callId: callId,
            toolName: toolName,
            summary: Self.toolCallSummary(name: toolName, arguments: args ?? existing?.args),
            args: args ?? existing?.args,
            startedAt: startedAt,
            endedAt: endedAt,
            success: success,
            error: error,
            result: result,
            status: status,
            statusUpdatedAt: Date().timeIntervalSince1970
        )
        updateLocalAssistantState(phase: "execution", isStreaming: true)
    }

    private func makeLocalImageContent(from content: [SessionHistoryMessage.Content]) throws -> [ImageContent] {
        try content.compactMap { item in
            guard item.type == "image",
                  let ref = item.fileRef,
                  !ref.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let url = URL(fileURLWithPath: (ref.path as NSString).expandingTildeInPath)
            let data = try Data(contentsOf: url)
            return ImageContent(
                data: data.base64EncodedString(),
                mimeType: item.mimeType ?? url.detectedMimeType() ?? "image/png"
            )
        }
    }

    private func makeComputerUsePermissionRequestMessage(confirmationId: String, apps: [String]) -> SessionHistoryMessage {
        SessionHistoryMessage(
            id: confirmationId,
            type: "permission_request",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: SessionHistoryMessage.PermissionRequestInfo(
                environmentId: LocalRuntimeConnector.EnvironmentKind.localMacOS.connectAlias,
                environmentLabel: LocalRuntimeConnector.EnvironmentKind.localMacOS.permissionEnvironmentLabel,
                kind: "computer_use_start",
                description: OpenBridgeComputerUseAgent.startDescription(apps: apps),
                computerUseStart: SessionHistoryMessage.ComputerUseStartInfo(
                    availableModes: ["allow"],
                    apps: apps.isEmpty ? nil : apps,
                    permissions: ComputerUsePermissionService.status()
                )
            ),
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
    }

    private func makePermissionReplyMessage(
        confirmationId: String,
        approved: Bool,
        reason: String?,
        mode: String?
    ) -> SessionHistoryMessage {
        SessionHistoryMessage(
            id: "reply-\(confirmationId)",
            type: "permission_reply",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: SessionHistoryMessage.PermissionReplyInfo(
                approved: approved,
                reason: reason,
                mode: mode
            ),
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
    }

    // MARK: - SSE Stream

    private func startSSEStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await runSSEStream()
        }
    }

    private func runSSEStream() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func applyAdapterOutput(
        _ output: LocalAgentEventAdapter.AdapterOutput,
        refreshSchedules: Bool = true,
        observeAppRequests: Bool = true
    ) {
        if output.sessionStarted {
            resetAppRequestRoundState()
            isProcessing = true
            lastFinishState = nil
            lastWaitReason = nil
            onSessionStarted?()
        }

        for msg in output.historyMessages {
            appendMessage(msg)
            if observeAppRequests {
                observeAppRequestInPersistedMessage(msg)
            }
        }

        if let state = output.assistantState {
            assistantState = state
            if let messagingText = state.messaging?.text, !messagingText.isEmpty {
                observeAssistantMessagingText(messagingText)
            }
        }

        if let finished = output.sessionFinished {
            lastFinishState = finished.state
            lastWaitReason = nil
            isProcessing = false
            if finished.state != "waiting" {
                computerUseClientStore.finishAndReset()
                AgentSessionManager.shared.clearLocalPermission(sessionId: sessionID)
            }
            onSessionFinished?(finished.state, finished.error)
            Task { [weak self] in
                guard let self else { return }
                await reconcileStoredMessages(reason: "session_finished")
                await refreshWorkspaceState()
            }
        }

        if let title = output.titleChanged {
            sessionTitle = title
            onTitleChanged?(title)
        }

        if refreshSchedules, output.refreshSchedules {
            Task {
                await ScheduleStore.shared.refresh()
            }
        }
    }

    // MARK: - History Helpers

    private func appendMessage(_ message: SessionHistoryMessage) {
        // If this is a server-side user message and we already have a locally-added
        // copy (from send()), replace the local one so IDs are canonical.
        if message.role == "user", message.id.hasPrefix("agent-") {
            shouldInjectInitialSystemReminder = false
            if let localIdx = messages.lastIndex(where: { $0.id.hasPrefix("local-") && $0.role == "user" }) {
                messages[localIdx] = message
                persistLocalRecord()
                return
            }
        }

        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
            notifyEvent(.added(message: message))
            persistLocalRecord()
            return
        }

        messages.append(message)
        listUpdatedAt = Int64(Date().timeIntervalSince1970)
        notifyEvent(.added(message: message))
        persistLocalRecord()
    }

    private func persistLocalRecord() {
        guard !isRestoringLocalRecord else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let createdAt = listCreatedAt ?? now
        let updatedAt = listUpdatedAt ?? now
        listCreatedAt = createdAt
        listUpdatedAt = updatedAt
        LocalAgentSessionStore.save(LocalAgentSessionRecord(
            id: sessionID,
            title: currentTitleForList,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        ))
    }

    private func makeKWWKMessages(from history: [SessionHistoryMessage]) -> [KWWKAI.Message] {
        history.compactMap { message in
            switch message.role {
            case "user":
                let text = Self.serializeOutboundContent(message.content ?? [])
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .user(UserMessage(
                    text: text,
                    timestamp: Int64(message.timestamp * 1000)
                ))
            case "assistant":
                let text = message.content?.compactMap(\.text).joined(separator: "\n") ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .assistant(AssistantMessage(
                    content: [.text(TextContent(text: text))],
                    api: "local-restored",
                    provider: "local",
                    model: "restored",
                    timestamp: Int64(message.timestamp * 1000)
                ))
            default:
                return nil
            }
        }
    }

    private func reconcileStoredMessages(reason: String) async {
        _ = reason
    }

    func reconcileStoredSessionInfo(_ sessionInfo: LocalAgentSessionInfo, reason: String) {
        updateListMetadata(from: sessionInfo)

        let resolvedTitle = sessionInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedTitle.isEmpty, resolvedTitle != sessionTitle {
            sessionTitle = resolvedTitle
            onTitleChanged?(resolvedTitle)
        }

        let activityStatus = normalizedSessionActivityStatus(from: sessionInfo)
        switch activityStatus {
        case "queued", "running":
            reconcileStoredInFlightSessionState(activityStatus: activityStatus, reason: reason)
        case "waiting":
            reconcileStoredWaitingSessionState(reason: reason)
        case "paused", "failed", "cancelled", "completed":
            reconcileStoredTerminalSessionState(
                activityStatus: activityStatus,
                error: sessionInfo.lastRoundError,
                reason: reason
            )
        default:
            break
        }
    }

    private func normalizedSessionActivityStatus(from sessionInfo: LocalAgentSessionInfo) -> String {
        let activityStatus = sessionInfo.activityStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !activityStatus.isEmpty {
            return activityStatus
        }
        return sessionInfo.status.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func primeListMetadata(from sessionInfo: LocalAgentSessionInfo) {
        updateListMetadata(from: sessionInfo)
    }

    private func updateListMetadata(from sessionInfo: LocalAgentSessionInfo) {
        listCreatedAt = sessionInfo.createdAt
        listUpdatedAt = sessionInfo.lastActivityAt ?? sessionInfo.createdAt
        listPurpose = sessionInfo.purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reconcileStoredInFlightSessionState(activityStatus: String, reason: String) {
        if isProcessing {
            lastFinishState = nil
            lastWaitReason = nil
            return
        }
        logger.info("Reconciled in-flight session state \(activityStatus) for session \(sessionID) [\(reason)]")
        isProcessing = true
        lastFinishState = nil
        lastWaitReason = nil
        onSessionStarted?()
    }

    private func reconcileStoredWaitingSessionState(reason: String) {
        let wasProcessing = isProcessing
        let output = adapter.process(eventType: "status", data: #"{"status":"waiting"}"#)
        applyAdapterOutput(output)
        if isProcessing {
            lastFinishState = nil
            lastWaitReason = nil
            return
        }

        logger.info("Reconciled in-flight session state waiting for session \(sessionID) [\(reason)]")
        isProcessing = true
        lastFinishState = nil
        lastWaitReason = nil
        if !wasProcessing {
            onSessionStarted?()
        }
    }

    private func reconcileStoredTerminalSessionState(activityStatus: String, error: String?, reason: String) {
        let finishState = switch activityStatus {
        case "failed":
            "failed"
        case "cancelled":
            "cancelled"
        default:
            "completed"
        }

        guard isProcessing || lastFinishState != finishState else {
            return
        }

        var payload: [String: String] = ["status": activityStatus]
        let trimmedError = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedError.isEmpty {
            payload["error"] = trimmedError
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        logger.info("Reconciled terminal session state \(activityStatus) for session \(sessionID) [\(reason)]")
        let output = adapter.process(eventType: "status", data: json)
        applyAdapterOutput(output)
    }

    private func refreshWorkspaceState() async {
        do {
            workspaceState = try await AgentSessionManager.shared.localVMWorkspaceState(sessionId: sessionID)
            let refreshedSessionID = sessionID
            let diffCount = workspaceState?.fileDiff.count ?? 0
            let environmentID = workspaceState?.environmentId ?? ""
            logger.info("Workspace state refreshed for session \(refreshedSessionID, privacy: .public): diffs=\(diffCount, privacy: .public) environment=\(environmentID, privacy: .public)")
            notifyEvent(.workspaceStateChanged(workspaceState))
        } catch {
            let refreshedSessionID = sessionID
            logger.info("Local VM workspace state unavailable for session \(refreshedSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            workspaceState = nil
            notifyEvent(.workspaceStateChanged(nil))
        }
    }

    func acceptFiles(_ paths: [String], environmentID: String = "") async throws {
        let result = try await AgentSessionManager.shared.acceptLocalVMWorkspaceFiles(
            sessionId: sessionID,
            paths: paths
        )
        workspaceState = result.state
        let sandboxID = resolvedSandboxEnvironmentID(preferredEnvironmentID: environmentID, fallbackState: result.state)
        let artifacts = Self.makeSandboxReviewArtifacts(
            sandboxID: sandboxID,
            summary: result.summary,
            reviewDiff: result.reviewDiff,
            reviewDiffTotal: result.reviewDiffTotal
        )
        appendMessage(artifacts.message)
        if !artifacts.contextReminder.isEmpty {
            pendingLocalContextReminders.append(artifacts.contextReminder)
        }
    }

    func discardAllChanges(environmentID: String = "") async throws {
        let result = try await AgentSessionManager.shared.discardLocalVMWorkspaceChanges(
            sessionId: sessionID
        )
        workspaceState = result.state
        let sandboxID = resolvedSandboxEnvironmentID(preferredEnvironmentID: environmentID, fallbackState: result.state)
        let artifacts = Self.makeSandboxReviewArtifacts(
            sandboxID: sandboxID,
            summary: result.summary,
            reviewDiff: result.reviewDiff,
            reviewDiffTotal: result.reviewDiffTotal
        )
        appendMessage(artifacts.message)
        if !artifacts.contextReminder.isEmpty {
            pendingLocalContextReminders.append(artifacts.contextReminder)
        }
    }

    func getWorkspaceFileForPreview(path: String, environmentID: String = "") async throws -> String {
        try await AgentSessionManager.shared.localVMWorkspaceFileForPreview(
            sessionId: sessionID,
            path: path,
            environmentID: environmentID
        )
    }

    private func resolvedSandboxEnvironmentID(preferredEnvironmentID: String, fallbackState: WorkspaceState?) -> String {
        let preferred = preferredEnvironmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            return preferred
        }
        let stateEnvironmentID = fallbackState?.environmentId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stateEnvironmentID.isEmpty {
            return stateEnvironmentID
        }
        return "local-vm"
    }

    static func makeSandboxReviewArtifacts(
        sandboxID: String,
        summary: String,
        reviewDiff: [FileDiff],
        reviewDiffTotal: Int
    ) -> (message: SessionHistoryMessage, contextReminder: String) {
        let clippedDiff = Array(reviewDiff.prefix(100))
        let diffTotal = max(reviewDiffTotal, reviewDiff.count)
        let message = SessionHistoryMessage(
            id: "local-sandbox-review-\(UUID().uuidString)",
            type: "sandbox_review",
            role: nil,
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: sandboxID,
            acceptedSummary: summary,
            reviewDiff: clippedDiff.isEmpty ? nil : clippedDiff,
            reviewDiffTotal: diffTotal,
            confirmationId: nil,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
        let reminder = buildSandboxReviewContext(summary: summary, reviewDiff: clippedDiff, reviewDiffTotal: diffTotal)
        return (message, reminder.isEmpty ? "" : "[system] \(reminder)")
    }

    static func buildSandboxReviewContext(summary: String, reviewDiff: [FileDiff], reviewDiffTotal: Int) -> String {
        guard !summary.isEmpty else { return "" }
        guard reviewDiffTotal > 0, !reviewDiff.isEmpty else { return summary }

        var lines: [String] = [summary, "Diff list:"]
        lines.append(contentsOf: reviewDiff.map(formatSandboxReviewDiffLine))
        if reviewDiffTotal > reviewDiff.count {
            lines.append("... \(reviewDiffTotal - reviewDiff.count) more changes omitted.")
        }
        return lines.joined(separator: "\n")
    }

    static func formatSandboxReviewDiffLine(_ diff: FileDiff) -> String {
        if let movedFrom = diff.movedFrom, !movedFrom.isEmpty {
            return "MOVED \(movedFrom) -> \(diff.path)"
        }
        if diff.isDeleted {
            return "DELETED \(diff.path)"
        }
        if diff.isUpdated {
            return "UPDATED \(diff.path)"
        }
        return "NEW \(diff.path)"
    }

    private func notifyEvent(_ event: SessionHistoryEvent) {
        for listener in eventListeners.values {
            listener(event)
        }
    }

    static func serializeOutboundContent(_ content: [SessionHistoryMessage.Content]) -> String {
        content
            .compactMap { item in
                switch item.type {
                case "text":
                    guard let text = item.text,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        return nil
                    }
                    return text
                case "quote":
                    guard let text = item.text,
                          let quoteRef = item.quoteRef,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        return nil
                    }
                    return serializeQuoteReferenceLine(text: text, quoteRef: quoteRef)
                case "image":
                    guard let fileRef = item.fileRef else { return nil }
                    let environmentAlias = normalizedEnvironmentAlias(fileRef.environmentId)
                    return "[type:\"image\" env:\"\(escapeFileReferenceComponent(environmentAlias))\" path:\"\(escapeFileReferenceComponent(fileRef.path))\"]"
                default:
                    return nil
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func normalizedEnvironmentAlias(_ alias: String?) -> String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedAlias.isEmpty ? "Local" : trimmedAlias
    }

    private static func escapeFileReferenceComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func serializeQuoteReferenceLine(
        text: String,
        quoteRef: SessionHistoryMessage.QuoteReference
    ) -> String {
        "<quote source-message-id=\"\(quoteRef.sourceMessageId)\" start=\"\(quoteRef.startOffset)\" end=\"\(quoteRef.endOffset)\">\(escapeQuoteText(text))</quote>"
    }

    private static func escapeQuoteText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private func makeUserHistoryMessage(id: String, content: [SessionHistoryMessage.Content]) -> SessionHistoryMessage {
        SessionHistoryMessage(
            id: id,
            type: "message",
            role: "user",
            timestamp: Date().timeIntervalSince1970,
            content: content,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: nil,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
    }

    private func makeAssistantHistoryMessage(id: String, text: String) -> SessionHistoryMessage {
        SessionHistoryMessage(
            id: id,
            type: "message",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: [
                SessionHistoryMessage.Content(
                    type: "text",
                    text: text,
                    url: nil,
                    fileRef: nil,
                    fileRefs: nil,
                    fileName: nil,
                    mimeType: nil,
                    sizeBytes: nil,
                    entryKind: nil
                ),
            ],
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: nil,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
    }

    private static func jsonString(_ value: KWWKAI.JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }
        return text
    }

    private static func toolResultText(_ blocks: [ToolResultBlock]) -> String {
        blocks.compactMap { block in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func makeErrorHistoryMessage(for error: Error) -> SessionHistoryMessage {
        let resolvedError = resolveHistoryError(error)
        return SessionHistoryMessage(
            id: "local-error-\(UUID().uuidString)",
            type: "message",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: nil,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: resolvedError.type,
            error: resolvedError.message
        )
    }

    private func resolveHistoryError(_ error: Error) -> (type: String, message: String) {
        ("other_error", error.localizedDescription)
    }
}

// MARK: - Errors

enum LocalAgentSessionError: LocalizedError {
    case emptyMessage
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "Cannot send an empty message"
        case let .unsupportedOperation(name):
            "\(name) is not available in this local agent mode"
        }
    }
}
