//
//  ChatEditorViewModel.swift
//  OpenBridge
//
//  Created by Cursor on 2025/12/09.
//

import AppKit
import Combine
import ComposerEditor
import Foundation
import KWWKAI
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatEditorViewModel {
    struct QuoteFocusRequest: Equatable {
        let quoteRef: SessionHistoryMessage.QuoteReference
        let requestId: Int
    }

    struct Submission: CustomStringConvertible {
        let text: String?
        let attachments: [ChatAttachment]
        let quote: SessionHistoryMessage.Content?
        let reasoningEffort: String?

        var description: String {
            let textPreview = text?.prefix(64) ?? ""
            return "ChatEditorSubmission(text: \"\(textPreview)\", attachments: \(attachments.count), hasQuote: \(quote != nil))"
        }
    }

    // Editor state
    var text: String
    var isFocused: Bool = false
    var isDraggingFile: Bool = false
    var attachmentManager: AttachmentManager = .init()
    var draftQuote: SessionHistoryMessage.Content?
    let skillAutoMatcher = SkillAutoMatcher()
    var voiceInputState: ChatVoiceInputState = .idle
    var voiceWaveformLevels: [Double] = []
    var voiceRecordingDuration: TimeInterval = 0
    var voiceCurrentAmplitude: Double = 0
    var voiceAlert: ChatVoiceAlert?
    var isMicrophoneSettingsPromptPresented: Bool = false
    var isMicrophonePermissionAuthorizedForVoiceInput: Bool = MicrophonePermission().isAuthorized
    var selectedModelProvider: String = "openai"
    var selectedModelID: String = "gpt-5"
    var availableModelGroups: [(provider: String, models: [Model])] = []

    @ObservationIgnored
    let voiceRecorder = ChatVoiceRecorder()
    @ObservationIgnored
    let voiceTranscriptionService = ChatVoiceTranscriptionService()
    @ObservationIgnored
    var voiceTask: Task<Void, Never>?
    @ObservationIgnored
    var voiceRecordedDuration: TimeInterval = 0
    @ObservationIgnored
    var voiceLastWaveformSampleTime: TimeInterval?
    @ObservationIgnored
    var voicePendingWaveformPeak: Double = 0
    @ObservationIgnored
    private var quoteFocusRequestCounter: Int = 0
    @ObservationIgnored
    private var aiProviderSettingsCancellable: AnyCancellable?

    /// Skill selected for the current conversation (delegated to Chat)
    var selectedSkill: Skill? {
        get { chat?.selectedSkill }
        set { chat?.selectedSkill = newValue }
    }

    // Callback for external submission handling.
    var onSubmit: ((Submission) -> Void)?
    var onEscape: (() -> Void)?

    // Chat state
    var conversationTitle: String = ""
    var isConversationTitleLoaded: Bool = false
    var hasConversationMessages: Bool = false
    var isCreatingNewChat: Bool = false
    var pendingFocusMessageId: String?
    var pendingFocusQuoteRequest: QuoteFocusRequest?
    private var historyEventRemover: (@Sendable () -> Void)?
    private var titleDidChangeRemover: (@Sendable () -> Void)?
    @ObservationIgnored
    private var pendingNewChatTask: Task<ChatViewModel.Chat, Error>?
    @ObservationIgnored
    private var pendingNewChatRequestID: UUID?
    @ObservationIgnored
    private var pendingUnusedNewChatConversationID: String?

    let chatSubject = CurrentValueSubject<ChatViewModel.Chat?, Never>(nil)
    var chat: ChatViewModel.Chat? {
        didSet {
            cleanupTitleObservers()
            chatSubject.send(chat)
            setupTitleObservation()
        }
    }

    var error: Error?
    var isLoading: Bool = false
    var loadingTask: Task<Void, Never>?

    let chatViewController = ChatViewModel.shared
    let logger: os.Logger = .ui

    var isStreaming: Bool {
        chat?.isStreaming ?? false
    }

    var isStreamingPublisher: AnyPublisher<Bool, Never> {
        chatSubject
            .flatMap { chat -> AnyPublisher<Bool, Never> in
                chat?.isStreamingPublisher ?? Just(false).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    init(
        text: String = ""
    ) {
        self.text = text
        aiProviderSettingsCancellable = NotificationCenter.default
            .publisher(for: .aiProviderSettingsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadSelectedModel()
                }
            }
        Task { await loadSelectedModel() }
    }

    // MARK: - State Helpers

    var hasRunningAgentTask: Bool {
        chat?.session.hasOpenTask ?? false
    }

    var canStop: Bool {
        isStreaming || hasRunningAgentTask
    }

    var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || attachmentManager.hasUploadedAttachments
        let noPendingUploads = !attachmentManager.hasPendingOrUploadingAttachments

        guard hasAvailableModelSelection else { return false }
        guard !voiceInputState.blocksManualSend else { return false }

        // Allow sending to agent task even when streaming
        if hasRunningAgentTask, hasText, noPendingUploads {
            return true
        }

        // Allow sending with sendDirectly skill even without text/attachments
        if selectedSkill?.sendDirectly == true, !isStreaming, !isLoading, noPendingUploads {
            return true
        }

        return !isStreaming && !isLoading && hasContent && noPendingUploads
    }

    // MARK: - Editor Actions

    func requestSend() {
        guard canSend else { return }
        let submission = currentSubmission()
        if let onSubmit {
            onSubmit(submission)
        } else {
            sendMessage(submission: submission)
        }
    }

    func acceptAutoSuggestion() {
        guard let skill = skillAutoMatcher.suggestedSkill else { return }
        let submission = currentSubmission()
        skillAutoMatcher.reset()
        sendMessage(submission: submission, skillOverride: skill)
    }

    func dismissAutoSuggestion() {
        skillAutoMatcher.dismiss()
    }

    func requestStop() {
        AnalyticsManager.track(.init(do: .chatStopped, at: .chat))
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
        chat?.cancel()
    }

    func addAttachment(_ attachment: ChatAttachment, source: AttachmentSource) {
        attachmentManager.addAttachment(attachment, source: source)
    }

    func addFileURLs(_ urls: [URL], source: AttachmentSource) {
        for url in urls {
            attachmentManager.addAttachmentFromURL(url, source: source)
        }
    }

    func applyQuote(_ quote: SessionHistoryMessage.Content) {
        guard quote.type == "quote", quote.quoteRef != nil else { return }
        draftQuote = quote
        isFocused = true
    }

    func clearQuote() {
        draftQuote = nil
    }

    func focusDraftQuote() {
        guard let quoteRef = draftQuote?.quoteRef else { return }
        quoteFocusRequestCounter += 1
        pendingFocusQuoteRequest = .init(
            quoteRef: quoteRef,
            requestId: quoteFocusRequestCounter
        )
    }

    func populateFromSubmission(_ submission: Submission) {
        text = submission.text ?? ""
        draftQuote = submission.quote
        for attachment in submission.attachments {
            if attachment.data.isEmpty, attachment.isImage {
                attachmentManager.addAttachmentFromURL(attachment.localURL, source: .menu)
            } else {
                attachmentManager.addAttachment(attachment, source: .menu)
            }
        }
        isFocused = true
    }

    func clearAfterExternalSubmit() {
        text = ""
        draftQuote = nil
        attachmentManager.clearUploadedAttachments()
    }

    func reset() {
        cancelPendingNewChatCreation()
        releaseUnusedPendingNewChatIfNeeded()
        cancelVoiceInput()
        loadingTask?.cancel()
        isLoading = false
        loadingTask = nil
        skillAutoMatcher.reset()
        chat = nil
        error = nil
        text = ""
        draftQuote = nil
        conversationTitle = ""
        isConversationTitleLoaded = false
        hasConversationMessages = false
        pendingFocusMessageId = nil
        pendingFocusQuoteRequest = nil
        attachmentManager.clearUploadedAttachments()
    }

    func openNewChat() {
        AnalyticsManager.track(.init(do: .chatConversationCreated, at: .chat))
        prepareConversationTransition()
        startPendingNewChatCreation()
    }

    func openConversation(_ conversationId: String, focusMessageId: String? = nil) {
        AnalyticsManager.track(.init(do: .chatConversationSwitched, at: .chat))
        openConversation(conversationId: conversationId, focusMessageId: focusMessageId)
    }

    // MARK: - Skill Actions

    func selectSkill(_ skill: Skill) {
        skillAutoMatcher.reset()
        chat?.selectedSkill = skill
    }

    func clearSelectedSkill() {
        skillAutoMatcher.reset()
        chat?.selectedSkill = nil
    }

    /// Activate a skill: create a new conversation, set the skill, and optionally send directly.
    func activateSkill(_ skill: Skill) {
        AnalyticsManager.track(.init(do: .chatConversationCreated, at: .chat))
        skillAutoMatcher.reset()
        cancelPendingNewChatCreation()
        releaseUnusedPendingNewChatIfNeeded()
        cancelVoiceInput()

        chat = nil
        error = nil
        text = ""
        draftQuote = nil
        attachmentManager.clearUploadedAttachments()

        let sendDirectly = skill.sendDirectly
        withLoadingTask {
            do {
                try await AgentSessionManager.shared.waitUntilReady()
                let chat = try await self.chatViewController.openChat(conversationId: nil)
                try Task.checkCancellation()
                self.chat = chat
                self.error = nil
                chat.selectedSkill = skill

                guard sendDirectly else { return }

                let (inputText, _) = self.buildInputText(submissionText: nil)
                let content = AttachmentManager.buildInputContents(text: inputText, attachments: [])
                let didStart = chat.send(
                    content: content,
                    reasoningEffort: nil
                )
                guard didStart else { return }
                self.clearAfterSubmit()
                AnalyticsManager.track(.init(do: .chatMessageSent(attachmentCount: 0), at: .chat))
                AnalyticsManager.track(.init(do: .skillActivated(name: skill.name), at: .chat))
                SkillManager.shared.recordSkillUsage(skillName: skill.name)
            } catch is CancellationError {
                return
            } catch {
                self.error = error
            }
        }
    }

    // MARK: - Models

    // Model is determined by the local agent configuration; no client-side selection.

    // MARK: - Private

    func sendMessage(submission: Submission, skillOverride: Skill? = nil) {
        guard canSend(submission: submission, skillOverride: skillOverride) else { return }

        withLoadingTask {
            await self.sendMessageTask(submission: submission, skillOverride: skillOverride)
        }
    }

    func sendRetryMessage() {
        guard hasAvailableModelSelection else { return }
        withLoadingTask {
            await self.sendRetryMessageTask()
        }
    }

    func canSend(submission: Submission, skillOverride: Skill? = nil) -> Bool {
        let hasUploadedAttachments = submission.attachments.contains { $0.isUploaded }
        let hasPendingUploads = submission.attachments.contains { $0.uploadState == .pending || $0.isUploading }
        let hasContent = submission.text != nil || hasUploadedAttachments || selectedSkill != nil || skillOverride != nil
        guard hasContent else { return false }
        guard hasAvailableModelSelection else { return false }
        guard !hasPendingUploads else { return false }
        guard !voiceInputState.blocksManualSend else { return false }
        guard !isLoading else { return false }
        guard !isStreaming || hasRunningAgentTask else { return false }

        return true
    }

    private func sendMessageTask(
        submission: Submission,
        skillOverride: Skill?
    ) async {
        do {
            try await AgentSessionManager.shared.waitUntilReady()
            _ = try await performSendOperation(
                submission: submission,
                skillOverride: skillOverride
            )
        } catch is CancellationError {
            return
        } catch {
            self.error = error
        }
    }

    func performSendOperation(
        submission: Submission,
        skillOverride: Skill?
    ) async throws -> Bool {
        let chat = try await resolveChat()
        try Task.checkCancellation()

        error = nil

        let (inputText, activatedSkill) = buildInputText(
            submissionText: submission.text,
            skillOverride: skillOverride
        )
        let content = AttachmentManager.buildInputContents(
            text: inputText,
            attachments: submission.attachments,
            quote: submission.quote
        )

        let didStart = chat.send(
            content: content,
            reasoningEffort: submission.reasoningEffort
        )
        guard didStart else { return false }

        if pendingUnusedNewChatConversationID == chat.conversationId {
            pendingUnusedNewChatConversationID = nil
        }

        clearAfterSubmit()

        logger.info("Message sent successfully")
        let uploadedCount = submission.attachments.filter(\.isUploaded).count
        AnalyticsManager.track(.init(do: .chatMessageSent(
            attachmentCount: uploadedCount
        ), at: .chat))

        if let activatedSkill {
            AnalyticsManager.track(.init(do: .skillActivated(name: activatedSkill.name), at: .chat))
            SkillManager.shared.recordSkillUsage(skillName: activatedSkill.name)
        }

        return true
    }

    private func sendRetryMessageTask() async {
        let chat: ChatViewModel.Chat
        do {
            try await AgentSessionManager.shared.waitUntilReady()
            chat = try await resolveChat()
        } catch {
            self.error = error
            return
        }
        let retryContent: [SessionHistoryMessage.Content] = [
            SessionHistoryMessage.Content(type: "text", text: "retry", url: nil, fileRef: nil, fileName: nil, mimeType: nil),
        ]

        let didStart = chat.send(
            content: retryContent,
            reasoningEffort: nil
        )
        guard didStart else { return }

        clearAfterSubmit()

        logger.info("Retry message sent successfully")
        AnalyticsManager.track(.init(do: .chatMessageSent(attachmentCount: 0), at: .chat))
    }

    private func resolveChat() async throws -> ChatViewModel.Chat {
        if let chat {
            return chat
        }

        if let pendingNewChatTask {
            let chat = try await pendingNewChatTask.value
            self.pendingNewChatTask = nil
            pendingNewChatRequestID = nil
            isCreatingNewChat = false
            self.chat = chat
            error = nil
            return chat
        }

        return try await newChat(conversationId: nil)
    }

    private func prepareConversationTransition(focusMessageId: String? = nil) {
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
        cancelPendingNewChatCreation()
        releaseUnusedPendingNewChatIfNeeded()
        cancelVoiceInput()
        skillAutoMatcher.reset()
        chat = nil
        error = nil
        text = ""
        draftQuote = nil
        pendingFocusMessageId = focusMessageId
        pendingFocusQuoteRequest = nil
        attachmentManager.clearUploadedAttachments()
    }

    private func startPendingNewChatCreation() {
        let requestID = UUID()
        pendingNewChatRequestID = requestID
        isCreatingNewChat = true

        let task = Task { @MainActor in
            try await self.chatViewController.openChat(conversationId: nil)
        }
        pendingNewChatTask = task

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let chat = try await task.value
                guard pendingNewChatRequestID == requestID else { return }
                pendingNewChatTask = nil
                pendingNewChatRequestID = nil
                isCreatingNewChat = false
                guard self.chat == nil else { return }
                pendingUnusedNewChatConversationID = chat.conversationId
                self.chat = chat
                error = nil
            } catch is CancellationError {
                guard pendingNewChatRequestID == requestID else { return }
                pendingNewChatTask = nil
                pendingNewChatRequestID = nil
                isCreatingNewChat = false
            } catch {
                guard pendingNewChatRequestID == requestID else { return }
                pendingNewChatTask = nil
                pendingNewChatRequestID = nil
                isCreatingNewChat = false
                self.error = error
            }
        }
    }

    private func cancelPendingNewChatCreation() {
        let task = pendingNewChatTask
        pendingNewChatTask?.cancel()
        pendingNewChatTask = nil
        pendingNewChatRequestID = nil
        isCreatingNewChat = false
        guard let task else { return }

        Task { @MainActor in
            guard case let .success(chat) = await task.result else { return }
            _ = await AgentSessionManager.shared.deleteSessionIfPristine(sessionId: chat.conversationId)
        }
    }

    private func releaseUnusedPendingNewChatIfNeeded() {
        guard let conversationId = pendingUnusedNewChatConversationID else { return }
        pendingUnusedNewChatConversationID = nil

        Task { @MainActor in
            _ = await AgentSessionManager.shared.deleteSessionIfPristine(sessionId: conversationId)
        }
    }

    private func buildInputText(submissionText: String?, skillOverride: Skill? = nil) -> (String, Skill?) {
        let baseText = submissionText ?? "<empty/>"
        guard let skill = skillOverride ?? selectedSkill else { return (baseText, nil) }

        var displayName = skill.displayName
        if displayName.isEmpty { displayName = skill.name }
        let escapedDisplayName = displayName.replacingOccurrences(of: "\"", with: "&quot;")
        let repoAttr = skill.sourceRepo.map { " source-repo=\"\($0)\"" } ?? ""
        let taggedText = "<use-skill display-name=\"\(escapedDisplayName)\"\(repoAttr)>\(skill.name)</use-skill>" + baseText
        return (taggedText, skill)
    }

    func clearAfterSubmit() {
        skillAutoMatcher.reset()
        text = ""
        draftQuote = nil
        attachmentManager.clearUploadedAttachments()
        chat?.selectedSkill = nil
    }

    func currentSubmission(textOverride: String? = nil) -> Submission {
        let trimmed = (textOverride ?? text).trimmingCharacters(in: .whitespacesAndNewlines)

        return Submission(
            text: trimmed.isEmpty ? nil : trimmed,
            attachments: attachmentManager.attachments,
            quote: draftQuote,
            reasoningEffort: nil
        )
    }

    // MARK: - Title

    func renameCurrentConversation(title: String, window: NSWindow?) {
        guard let conversationId = chat?.conversationId else { return }
        Task {
            do {
                try await ConversationListViewController.shared.renameConversation(
                    conversationId: conversationId,
                    title: title
                )
                guard self.chat?.conversationId == conversationId else { return }
                self.applyConversationTitle(title, for: conversationId)
            } catch {
                let targetWindow = window?.isVisible == true ? window : NSApp.keyWindow
                guard let targetWindow else { return }
                let errorAlert = NSAlert(error: error)
                errorAlert.beginSheetModal(for: targetWindow) { _ in }
            }
        }
    }

    private func setupTitleObservation() {
        guard let chat else {
            conversationTitle = ""
            isConversationTitleLoaded = false
            hasConversationMessages = false
            return
        }
        let expectedId = chat.conversationId
        conversationTitle = chat.currentTitle
        isConversationTitleLoaded = chat.hasLoadedTitle
        hasConversationMessages = !chat.session.historyMessages.isEmpty
        syncConversationTitleToListIfNeeded(conversationId: expectedId)

        historyEventRemover = chat.session.addHistoryEventListener { [weak self] event in
            Task { @MainActor in
                guard self?.chat?.conversationId == expectedId else { return }
                switch event {
                case .added:
                    self?.hasConversationMessages = true
                case let .reset(messages):
                    self?.hasConversationMessages = !messages.isEmpty
                case .workspaceStateChanged:
                    break
                }
            }
        }

        titleDidChangeRemover = chat.addTitleDidChangeListener { [weak self] title in
            Task { @MainActor [weak self] in
                guard self?.chat?.conversationId == expectedId else { return }
                self?.applyConversationTitle(title, for: expectedId)
            }
        }

        Task {
            guard let title = await chat.loadTitleIfNeeded() else { return }
            guard self.chat?.conversationId == expectedId else { return }
            self.applyConversationTitle(title, for: expectedId)
        }
    }

    private func cleanupTitleObservers() {
        historyEventRemover?()
        historyEventRemover = nil
        titleDidChangeRemover?()
        titleDidChangeRemover = nil
    }

    @discardableResult
    func newChat(conversationId: String?) async throws -> ChatViewModel.Chat {
        let chat = try await chatViewController.openChat(conversationId: conversationId)

        try Task.checkCancellation()

        self.chat = chat

        return chat
    }

    func openConversation(conversationId: String?, focusMessageId: String? = nil) {
        prepareConversationTransition(focusMessageId: focusMessageId)
        withLoadingTask {
            do {
                let chat = try await self.chatViewController.openChat(conversationId: conversationId)
                try Task.checkCancellation()
                self.chat = chat
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = error
            }
        }
    }

    func withLoadingTask(closure: @escaping () async -> Void) {
        loadingTask?.cancel()
        loadingTask = Task {
            isLoading = true
            defer {
                if !Task.isCancelled {
                    self.isLoading = false
                }
            }
            await closure()
        }
    }

    private func applyConversationTitle(_ title: String, for conversationId: String) {
        conversationTitle = title
        isConversationTitleLoaded = true
        syncConversationTitleToListIfNeeded(
            conversationId: conversationId,
            title: title,
            isLoaded: true
        )
    }

    private func syncConversationTitleToListIfNeeded(
        conversationId: String,
        title: String? = nil,
        isLoaded: Bool? = nil
    ) {
        let resolvedTitle = (title ?? conversationTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLoadedState = isLoaded ?? isConversationTitleLoaded
        guard resolvedLoadedState, !resolvedTitle.isEmpty else { return }

        let session = chat?.conversationId == conversationId ? chat?.session : nil
        ConversationListViewController.shared.syncConversationTitle(
            conversationId: conversationId,
            title: resolvedTitle,
            purpose: session?.listPurpose,
            createdAt: session?.listCreatedAt,
            updatedAt: session?.listUpdatedAt
        )
    }
}
