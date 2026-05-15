import Foundation
import KWWKAI
import SwiftUI

private struct AIProviderAuthSnapshot: Equatable {
    var apiKey: String
    var oauthAccessToken: String
    var oauthRefreshToken: String
}

struct AIProviderDetailView: View {
    let provider: BridgeAIProvider

    @State private var config: BridgeAIProviderConfig
    @State private var apiKey = ""
    @State private var oauthAccessToken = ""
    @State private var oauthRefreshToken = ""
    @State private var oauthExpiresAt = Date().addingTimeInterval(50 * 60)
    @State private var modelRows: [AIProviderModelRow]
    @State private var selectedModelRowIDs: Set<AIProviderModelRow.ID> = []
    @State private var usageSnapshot = BridgeAIProviderUsageSnapshot.unavailable
    @State private var isRefreshingUsage = false
    @State private var isSaving = false
    @State private var isLoggingIn = false
    @State private var isFetchingModels = false
    @State private var loginAttemptID = 0
    @State private var loginTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(provider: BridgeAIProvider) {
        self.provider = provider
        let initialConfig = BridgeAIProviderSettings()[provider]
        _config = State(initialValue: initialConfig)
        _modelRows = State(initialValue: Self.modelRows(for: provider, config: initialConfig))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                authPicker
                endpointSection

                if config.authMethod == .apiKey {
                    apiTokenSection
                } else {
                    oauthSection
                }

                if provider == .openAIChatCompletions {
                    modelsSection
                }

                if supportsUsageDisplay {
                    usageSection
                }
                actionsSection
                storageCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(provider.displayName)
        .task {
            config = await BridgeAIProviderSecretStore.readSettings()[provider]
            modelRows = Self.modelRows(for: provider, config: config)
            await loadSecrets()
            await refreshUsage()
        }
        .onDisappear {
            loginTask?.cancel()
            loginTask = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ProviderIcon(provider: provider, size: 68)

            VStack(alignment: .leading, spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 30, weight: .semibold))

                HStack(spacing: 10) {
                    Label(statusTitle, systemImage: statusIcon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(statusColor)

                    if supportsUsageDisplay {
                        Divider()
                            .frame(height: 16)

                        UsageBadge(
                            title: "5h",
                            value: usageSnapshot.label(for: .fiveHour),
                            tone: usageSnapshot.tone(for: .fiveHour)
                        )
                        UsageBadge(
                            title: "1w",
                            value: usageSnapshot.label(for: .oneWeek),
                            tone: usageSnapshot.tone(for: .oneWeek)
                        )
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if supportsUsageDisplay {
                    Button {
                        Task { await refreshUsage() }
                    } label: {
                        if isRefreshingUsage {
                            Label("Refreshing Usage", systemImage: "arrow.clockwise")
                        } else {
                            Label("Refresh Usage", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingUsage || !hasConfiguredAuth)

                    Text(usageUpdatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var authPicker: some View {
        Picker("Authentication", selection: $config.authMethod) {
            ForEach(provider.supportedAuthMethods) { method in
                Text(method.segmentTitle).tag(method)
            }
        }
        .pickerStyle(.segmented)
    }

    private var endpointSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Endpoint")
                        .font(.headline)
                    Spacer()
                    Button("Reset to default") {
                        config.baseURL = provider.defaultBaseURL
                    }
                    .disabled(config.baseURL == provider.defaultBaseURL)
                }

                TextField("Base URL", text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)

                if provider == .openAI {
                    openAIEndpointHelp
                }
            }
        }
    }

    private var openAIEndpointHelp: some View {
        ViewThatFits(in: .horizontal) {
            openAIEndpointHelpText(axis: .horizontal)
            openAIEndpointHelpText(axis: .vertical)
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func openAIEndpointHelpText(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("For third-party OpenAI-compatible endpoints, configure ")
                    .foregroundStyle(.secondary)
                openAIChatCompletionsLink
                Text(". This provider only supports official OpenAI endpoints.")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("For third-party OpenAI-compatible endpoints, configure:")
                    .foregroundStyle(.secondary)
                openAIChatCompletionsLink
                Text("This provider only supports official OpenAI endpoints.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openAIChatCompletionsLink: some View {
        Button("OpenAI Chat Completions") {
            SettingsNavigation.shared.present(.aiProviderDetail(.openAIChatCompletions), in: .aiProviders)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .help("Open OpenAI Chat Completions provider settings")
    }

    private var apiTokenSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("API Token")
                    .font(.headline)

                Text("Paste a provider token. OpenBridge stores it locally and only resolves it when a session uses this provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField(provider.apiKeyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var modelsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Models")
                            .font(.headline)
                        Text("Manage model names exposed by this Chat Completions endpoint.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await fetchModels() }
                    } label: {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Fetch Models", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFetchingModels || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Fetch available models from the endpoint's /v1/models API")
                }

                Table($modelRows, selection: $selectedModelRowIDs) {
                    TableColumn("Model Name") { $row in
                        TextField("Model name", text: $row.name)
                            .textFieldStyle(.plain)
                    }
                }
                .frame(minHeight: 180)

                HStack(spacing: 8) {
                    Button {
                        addModelRow()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add model")

                    Button {
                        removeSelectedModelRows()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedModelRowIDs.isEmpty)
                    .help("Remove selected models")

                    Spacer()

                    Text("\(normalizedModelIDs.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OAuth is the recommended way to connect your \(provider.displayName) account.\nOpenBridge opens a browser window for you to sign in and authorize access.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                startOAuthLogin()
            } label: {
                HStack {
                    Spacer()
                    if isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(oauthButtonTitle)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoggingIn && loginTask == nil)

            Button("Use API token instead") {
                config.authMethod = .apiKey
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            connectedAccountSection
        }
    }

    private var connectedAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected Account")
                .font(.headline)

            SettingsCard {
                VStack(spacing: 0) {
                    DetailRow(
                        title: "Account",
                        value: connectedAccountTitle,
                        systemImage: hasConfiguredAuth ? "checkmark.circle.fill" : nil,
                        tint: hasConfiguredAuth ? .green : .secondary
                    )
                    DetailDivider()
                    DetailRow(title: "Authentication", value: config.authMethod.displayName)
                    DetailDivider()
                    DetailRow(title: "Endpoint", value: displayBaseURL)
                    DetailDivider()
                    DetailRow(title: "Token expires", value: tokenExpiryText)
                    DetailDivider()
                    DetailRow(title: "Permissions", value: "Models, chat completions")
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Summary")
                .font(.headline)

            SettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        UsageMetric(
                            title: "5-Hour Limit",
                            value: usageSnapshot.label(for: .fiveHour),
                            detail: usageSnapshot.resetText(for: .fiveHour)
                        )
                        VerticalDivider()
                        UsageMetric(
                            title: "Weekly Limit",
                            value: usageSnapshot.label(for: .oneWeek),
                            detail: usageSnapshot.resetText(for: .oneWeek)
                        )
                        VerticalDivider()
                        UsageMetric(title: "Source", value: usageSnapshot.source.title)
                    }
                    .frame(height: 78)

                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(usageSnapshot.message ?? "Usage comes from the provider subscription limit endpoint and is refreshed locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Save Changes") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Reset Provider...", role: .destructive) {
                    Task { await resetProvider() }
                }
                .disabled(isLoggingIn)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var storageCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your API keys and OAuth tokens are stored locally.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var isOAuthLoggedIn: Bool {
        !oauthAccessToken.isEmpty
    }

    private var hasConfiguredAuth: Bool {
        config.isEnabled && hasStoredAuth
    }

    private var supportsUsageDisplay: Bool {
        hasConfiguredAuth && config.authMethod == .oauth
    }

    private var hasStoredAuth: Bool {
        switch config.authMethod {
        case .apiKey:
            !apiKey.isEmpty
        case .oauth:
            isOAuthLoggedIn
        }
    }

    private var statusTitle: String {
        if hasConfiguredAuth {
            return "Configured"
        }
        if config.isEnabled {
            return "Missing \(config.authMethod.displayName)"
        }
        return "Not configured"
    }

    private var statusIcon: String {
        hasConfiguredAuth ? "checkmark.circle.fill" : "circle.fill"
    }

    private var statusColor: Color {
        if hasConfiguredAuth {
            return .green
        }
        return config.isEnabled ? .orange : .secondary
    }

    private var connectedAccountTitle: String {
        if let accountID = config.oauthAccountID, !accountID.isEmpty {
            return accountID
        }
        return hasConfiguredAuth ? "Connected" : "Not connected"
    }

    private var displayBaseURL: String {
        config.baseURL.isEmpty ? provider.defaultBaseURL : config.baseURL
    }

    private var tokenExpiryText: String {
        guard config.authMethod == .oauth, isOAuthLoggedIn else { return "Not applicable" }
        return oauthExpiresAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var oauthButtonTitle: String {
        if isLoggingIn {
            return "Restart Sign In"
        }
        return isOAuthLoggedIn ? "Sign In Again" : "Open Browser for OAuth"
    }

    private var usageUpdatedText: String {
        guard let updatedAt = usageSnapshot.updatedAt else { return "Not synced" }
        return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func loadSecrets() async {
        apiKey = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .apiKey)
        oauthAccessToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthAccessToken)
        oauthRefreshToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthRefreshToken)
        oauthExpiresAt = config.oauthExpiresAt ?? Date().addingTimeInterval(50 * 60)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }

        do {
            let previousSettings = await BridgeAIProviderSecretStore.readSettings()
            let previousAuth = await authSnapshot()
            if config.authMethod == .apiKey {
                try await BridgeAIProviderSecretStore.saveSecret(apiKey, for: provider, kind: .apiKey)
            } else {
                try await BridgeAIProviderSecretStore.saveSecret(
                    oauthAccessToken,
                    for: provider,
                    kind: .oauthAccessToken
                )
                try await BridgeAIProviderSecretStore.saveSecret(
                    oauthRefreshToken,
                    for: provider,
                    kind: .oauthRefreshToken
                )
                config.oauthExpiresAt = oauthExpiresAt
            }

            if provider == .openAIChatCompletions {
                config.modelIDs = normalizedModelIDs
                modelRows = Self.rows(from: config.modelIDs ?? [])
            }

            config.isEnabled = hasStoredAuth || config.isEnabled
            var settings = previousSettings
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            await applyProviderConfigurationChange(
                previousSettings: previousSettings,
                updatedSettings: settings,
                previousAuth: previousAuth
            )
            statusMessage = "Saved"
            await refreshUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startOAuthLogin() {
        loginTask?.cancel()
        loginAttemptID += 1
        let attemptID = loginAttemptID
        loginTask = Task {
            await loginOAuth(attemptID: attemptID)
        }
    }

    private func loginOAuth(attemptID: Int) async {
        isLoggingIn = true
        errorMessage = nil
        statusMessage = "Opening browser..."
        defer {
            if loginAttemptID == attemptID {
                isLoggingIn = false
                loginTask = nil
            }
        }

        do {
            let previousSettings = await BridgeAIProviderSecretStore.readSettings()
            let previousAuth = await authSnapshot()
            let callbacks = OAuthLogin.Callbacks(
                onAuthURL: { url in
                    Browser.open(url)
                },
                onProgress: { message in
                    Task { @MainActor in
                        guard loginAttemptID == attemptID else { return }
                        statusMessage = message
                    }
                }
            )
            let credentials = try await oauthLogin(callbacks: callbacks)
            guard loginAttemptID == attemptID, !Task.isCancelled else { return }
            oauthAccessToken = credentials.access
            oauthRefreshToken = credentials.refresh
            oauthExpiresAt = Date(timeIntervalSince1970: Double(credentials.expires) / 1000)
            try await BridgeAIProviderSecretStore.saveSecret(
                credentials.access,
                for: provider,
                kind: .oauthAccessToken
            )
            try await BridgeAIProviderSecretStore.saveSecret(
                credentials.refresh,
                for: provider,
                kind: .oauthRefreshToken
            )

            config.authMethod = .oauth
            config.isEnabled = true
            config.oauthExpiresAt = oauthExpiresAt
            if provider == .openAI {
                config.oauthAccountID = BridgeAIProviderRegistry.openAIAccountID(fromJWT: credentials.access)
            }
            if provider == .githubCopilot,
               case let .string(endpoint) = credentials.extras["endpoint"] ?? .null,
               !endpoint.isEmpty
            {
                config.baseURL = endpoint
            }

            var settings = previousSettings
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            await applyProviderConfigurationChange(
                previousSettings: previousSettings,
                updatedSettings: settings,
                previousAuth: previousAuth
            )
            statusMessage = "Signed in"
            await refreshUsage()
        } catch is CancellationError {
            guard loginAttemptID == attemptID else { return }
            statusMessage = nil
        } catch {
            guard loginAttemptID == attemptID else { return }
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func resetProvider() async {
        errorMessage = nil
        do {
            let previousSettings = await BridgeAIProviderSecretStore.readSettings()
            let previousAuth = await authSnapshot()
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .apiKey)
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .oauthAccessToken)
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .oauthRefreshToken)
            apiKey = ""
            oauthAccessToken = ""
            oauthRefreshToken = ""
            config.isEnabled = false
            config.oauthExpiresAt = nil
            config.oauthAccountID = nil
            if provider == .openAIChatCompletions {
                config.modelIDs = nil
                modelRows = Self.modelRows(for: provider, config: config)
                selectedModelRowIDs = []
            }
            usageSnapshot = .unavailable

            var settings = previousSettings
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            await applyProviderConfigurationChange(
                previousSettings: previousSettings,
                updatedSettings: settings,
                previousAuth: previousAuth
            )
            statusMessage = "Provider reset"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyProviderConfigurationChange(
        previousSettings: BridgeAIProviderSettings,
        updatedSettings: BridgeAIProviderSettings,
        previousAuth: AIProviderAuthSnapshot
    ) async {
        let updatedAuth = await authSnapshot()
        guard previousSettings != updatedSettings || previousAuth != updatedAuth else { return }
        await AgentSessionManager.shared.reloadAIProviderConfiguration()
        await MainActor.run {
            NotificationCenter.default.post(name: .aiProviderSettingsDidChange, object: nil)
        }
    }

    private func authSnapshot() async -> AIProviderAuthSnapshot {
        let apiKey = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .apiKey)
        let oauthAccessToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthAccessToken)
        let oauthRefreshToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthRefreshToken)
        return AIProviderAuthSnapshot(
            apiKey: apiKey,
            oauthAccessToken: oauthAccessToken,
            oauthRefreshToken: oauthRefreshToken
        )
    }

    private func oauthLogin(callbacks: OAuthLogin.Callbacks) async throws -> OAuthCredentials {
        switch provider {
        case .openAI:
            try await OAuthLogin.loginOpenAICodex(callbacks: callbacks)
        case .openAIChatCompletions:
            throw OAuthError.unknownProvider(provider.rawValue)
        case .anthropic:
            try await OAuthLogin.loginAnthropic(callbacks: callbacks)
        case .githubCopilot:
            try await OAuthLogin.loginGitHubCopilot(callbacks: callbacks)
        case .googleGemini:
            throw OAuthError.unknownProvider(provider.rawValue)
        case .amazonBedrock, .azureOpenAIResponses, .cerebras, .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek,
             .fireworks, .groq, .huggingFace, .kimiCoding, .minimax, .minimaxCN, .mistral, .moonshotAI, .moonshotAICN,
             .opencode, .opencodeGo, .openRouter, .vercelAIGateway, .xAI, .xiaomi, .zAI, .openAICompatible:
            throw OAuthError.unknownProvider(provider.rawValue)
        }
    }

    private func refreshUsage() async {
        guard supportsUsageDisplay else {
            usageSnapshot = .unavailable
            return
        }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        usageSnapshot = await BridgeAIProviderUsageService.refresh(provider: provider)
    }

    private var normalizedModelIDs: [String] {
        Self.normalizedModelIDs(from: modelRows.map(\.name))
    }

    private func addModelRow() {
        let row = AIProviderModelRow(name: "new-model")
        modelRows.append(row)
        selectedModelRowIDs = [row.id]
    }

    private func removeSelectedModelRows() {
        modelRows.removeAll { selectedModelRowIDs.contains($0.id) }
        selectedModelRowIDs = []
    }

    private func fetchModels() async {
        guard provider == .openAIChatCompletions else { return }
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Enter an API token before fetching models."
            return
        }
        guard let url = modelListURL else {
            errorMessage = "Enter a valid endpoint URL."
            return
        }

        isFetchingModels = true
        errorMessage = nil
        statusMessage = nil
        defer { isFetchingModels = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIProviderModelFetchError.invalidResponse
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw AIProviderModelFetchError.requestFailed(httpResponse.statusCode)
            }

            let ids = try Self.decodeFetchedModelIDs(from: data)
            guard !ids.isEmpty else {
                throw AIProviderModelFetchError.emptyModelList
            }

            modelRows = Self.rows(from: ids)
            selectedModelRowIDs = []
            statusMessage = "Fetched \(ids.count) models. Save changes to persist them."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var modelListURL: URL? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = provider.defaultBaseURL
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let versioned = base.hasSuffix("/v1") ? base : "\(base)/v1"
        return URL(string: "\(versioned)/models")
    }

    private static func modelRows(for provider: BridgeAIProvider, config: BridgeAIProviderConfig) -> [AIProviderModelRow] {
        guard provider == .openAIChatCompletions else { return [] }
        return rows(from: config.modelIDs ?? [Models.gpt4oMini.id])
    }

    private static func rows(from modelIDs: [String]) -> [AIProviderModelRow] {
        normalizedModelIDs(from: modelIDs).map { AIProviderModelRow(name: $0) }
    }

    private static func normalizedModelIDs(from modelIDs: [String]) -> [String] {
        modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { result, id in
                guard !result.contains(id) else { return }
                result.append(id)
            }
    }

    private static func decodeFetchedModelIDs(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data)
        let rawIDs: [String] = if let root = json as? [String: Any], let models = root["data"] {
            extractModelIDs(from: models)
        } else {
            extractModelIDs(from: json)
        }
        return normalizedModelIDs(from: rawIDs)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func extractModelIDs(from value: Any) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        guard let models = value as? [Any] else { return [] }
        return models.compactMap { item in
            if let id = item as? String {
                return id
            }
            guard let object = item as? [String: Any] else { return nil }
            return object["id"] as? String
        }
    }
}

private struct AIProviderModelRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
}

private enum AIProviderModelFetchError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case emptyModelList

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The models endpoint returned an invalid response."
        case let .requestFailed(statusCode):
            "The models endpoint returned HTTP \(statusCode)."
        case .emptyModelList:
            "The models endpoint did not return any model IDs."
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
        }
        .font(.callout)
        .frame(height: 32)
    }
}

private struct DetailDivider: View {
    var body: some View {
        Divider()
    }
}

private struct VerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

private struct UsageMetric: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }
}

private extension BridgeAIProviderAuthMethod {
    var segmentTitle: String {
        switch self {
        case .apiKey: "API Token"
        case .oauth: "OAuth"
        }
    }
}

#Preview {
    NavigationStack {
        AIProviderDetailView(provider: .openAI)
            .environment(SettingsManager.shared)
    }
}
