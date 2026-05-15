import AppKit
import ComposerEditor
import Foundation
import KWWKAI
import SwiftUI

@MainActor
extension ChatEditorViewModel: ComposerEditing {
    var attachments: [ChatAttachment] {
        attachmentManager.attachments
    }

    func removeAttachment(id: UUID) {
        attachmentManager.removeAttachment(id: id)
    }

    func retryAttachment(_ attachment: ChatAttachment) {
        attachmentManager.retryAttachment(attachment)
    }

    func requestEscape() {
        onEscape?()
    }
}

@MainActor
extension ChatEditorViewModel {
    var composerRealModelSelectorConfig: ComposerModelSelectorConfig? {
        let groups = availableModelGroups.map { group in
            ComposerModelGroup(
                provider: BridgeAIProviderRegistry.displayProviderName(group.provider),
                models: group.models.map { model in
                    ComposerModelOption(
                        id: Self.modelSelectionID(for: model),
                        title: model.name
                    )
                },
                showsHeader: true
            )
        }
        let selectedModel = selectedModel
        let hasModels = hasAvailableModelSelection

        return ComposerModelSelectorConfig(
            groups: groups,
            isLoading: false,
            selectedModelId: Binding(
                get: { Self.modelSelectionID(provider: self.selectedModelProvider, id: self.selectedModelID) },
                set: { selectionID in
                    self.updateSelectedModel(selectionID)
                }
            ),
            selectedModelTitle: hasModels ? (selectedModel?.name ?? selectedModelID) : String(localized: "Set up AI provider"),
            selectedModelSubtitle: hasModels ? BridgeAIProviderRegistry.displayProviderName(selectedModelProvider) : nil,
            emptyActionSystemImage: "key.fill",
            accessibilityIdentifier: AccessibilityID.Chat.composerModelSelector,
            accessibilityLabel: hasModels ? String(localized: "Select model") : String(localized: "Set up AI provider"),
            onOpen: {
                Task { await self.loadSelectedModel() }
            },
            onSelect: { selectionID in
                self.updateSelectedModel(selectionID)
            },
            onEmptyAction: {
                self.openAIProviderSettings()
            }
        )
    }

    var composerModelSelectorConfig: ComposerModelSelectorConfig? {
        ComposerModelSelectorConfig(
            groups: [
                ComposerModelGroup(
                    provider: "permissions",
                    models: LocalEnvironmentPermissionMode.allCases.map { mode in
                        ComposerModelOption(
                            id: mode.rawValue,
                            title: mode.displayName,
                            systemImage: mode.systemImage,
                            selectedTone: mode == .fullAccess ? .warning : nil
                        )
                    },
                    showsHeader: false
                ),
            ],
            isLoading: false,
            selectedModelId: Binding(
                get: { SettingsManager.shared.localEnvironmentPermissionMode.rawValue },
                set: { rawValue in
                    self.updateLocalEnvironmentPermissionMode(rawValue)
                }
            ),
            selectedModelTitle: SettingsManager.shared.localEnvironmentPermissionMode.displayName,
            accessibilityIdentifier: AccessibilityID.Chat.composerPermissionSelector,
            accessibilityLabel: String(localized: "Select permission mode"),
            onOpen: {},
            onSelect: { rawValue in
                self.updateLocalEnvironmentPermissionMode(rawValue)
            }
        )
    }

    var composerVoiceInputConfig: ComposerVoiceInputConfig {
        let amplitude = voiceCurrentAmplitude
        let composerState: ComposerVoiceInputState = switch voiceInputState {
        case .idle:
            .idle
        case .recording:
            .recording(
                ComposerVoiceRecordingState(
                    levels: voiceWaveformLevels,
                    duration: voiceRecordingDuration,
                    currentAmplitude: amplitude
                )
            )
        case .transcribing:
            .transcribing(
                ComposerVoiceRecordingState(
                    levels: voiceWaveformLevels,
                    duration: voiceRecordingDuration,
                    currentAmplitude: amplitude
                )
            )
        }

        return ComposerVoiceInputConfig(
            state: composerState,
            isButtonEnabled: canStartVoiceRecording,
            canAutoSendRecording: canAutoSendVoiceRecording,
            disablesSendButton: voiceInputState.disablesSendButton,
            idleButtonStyle: isMicrophonePermissionAuthorizedForVoiceInput ? .accent : .warning,
            shortcutHint: VoiceInputShortcutHelper.shortcutDisplayString,
            onPrimaryAction: { self.requestStartVoiceRecording() },
            onCancelVoiceInput: { self.requestCancelVoiceInput() },
            onStopRecording: { self.requestStopVoiceRecording() },
            onSendRecording: { self.requestSendVoiceRecording() }
        )
    }

    private var sessionModelMenuSections: [ComposerModelMenuSection] {
        // Local VM settings are managed by the local agent session.
        []
    }

    private var selectedModel: Model? {
        BridgeAIProviderRegistry.displayModel(provider: selectedModelProvider, id: selectedModelID)
    }

    var hasAvailableModelSelection: Bool {
        availableModelGroups.contains { !$0.models.isEmpty }
    }

    func loadSelectedModel() async {
        var settings = await BridgeAIProviderSecretStore.readSettings()
        availableModelGroups = BridgeAIProviderRegistry.availableModelsByProvider(settings: settings)
        if settings.selectedModelProvider == "openai",
           settings[.openAI].authMethod == .oauth,
           BridgeAIProviderRegistry.displayModel(provider: "openai-codex", id: settings.selectedModelID) != nil
        {
            settings.selectedModelProvider = "openai-codex"
            try? await BridgeAIProviderSecretStore.saveSettings(settings)
        }
        availableModelGroups = BridgeAIProviderRegistry.availableModelsByProvider(settings: settings)
        guard hasAvailableModelSelection else {
            selectedModelProvider = settings.selectedModelProvider
            selectedModelID = settings.selectedModelID
            return
        }
        let selected = BridgeAIProviderRegistry.selectedDisplayModel(settings: settings)
        selectedModelProvider = selected.provider
        selectedModelID = selected.id
    }

    private func updateSelectedModel(_ selectionID: String) {
        guard let parsed = Self.parseModelSelectionID(selectionID),
              availableModelGroups.contains(where: { group in
                  group.provider == parsed.provider && group.models.contains { $0.id == parsed.id }
              })
        else { return }
        selectedModelProvider = parsed.provider
        selectedModelID = parsed.id
        Task {
            var settings = await BridgeAIProviderSecretStore.readSettings()
            settings.selectedModelProvider = parsed.provider
            settings.selectedModelID = parsed.id
            try? await BridgeAIProviderSecretStore.saveSettings(settings)
            await AgentSessionManager.shared.updateActiveLocalAgentModel(
                provider: parsed.provider,
                modelID: parsed.id
            )
        }
    }

    private func updateLocalEnvironmentPermissionMode(_ rawValue: String) {
        guard let mode = LocalEnvironmentPermissionMode(rawValue: rawValue),
              SettingsManager.shared.localEnvironmentPermissionMode != mode
        else { return }
        SettingsManager.shared.localEnvironmentPermissionMode = mode
        AgentSessionManager.shared.applyLocalEnvironmentPermissionModeChange(mode)
    }

    private func openAIProviderSettings() {
        SettingsNavigation.shared.navigate(to: .aiProviders)
        Windows.shared.open(.settings)
    }

    private static func modelSelectionID(for model: Model) -> String {
        modelSelectionID(provider: model.provider, id: model.id)
    }

    private static func modelSelectionID(provider: String, id: String) -> String {
        "\(provider)/\(id)"
    }

    private static func parseModelSelectionID(_ selectionID: String) -> (provider: String, id: String)? {
        let parts = selectionID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (provider: parts[0], id: parts[1])
    }
}
