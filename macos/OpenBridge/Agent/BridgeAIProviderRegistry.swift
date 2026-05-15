import Foundation
import KWWKAI

enum BridgeAIProviderRegistry {
    private static let sourceId = "bridge-ai"

    static func registerProviders() async {
        await APIRegistry.shared.unregisterSource(sourceId)
        var settings = await BridgeAIProviderSecretStore.readSettings()
        let anthropicConfig = settings[.anthropic]
        if anthropicConfig.authMethod == .oauth {
            await APIRegistry.shared.register(ProviderVariants.anthropicOAuth(accessToken: nil), sourceId: sourceId)
        } else {
            await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: nil), sourceId: sourceId)
        }
        await APIRegistry.shared.register(OpenAICompletionsProvider(defaultAPIKey: nil), sourceId: sourceId)
        await APIRegistry.shared.register(OpenAIResponsesProvider(defaultAPIKey: nil), sourceId: sourceId)
        await APIRegistry.shared.register(BedrockProvider(
            region: bedrockRegion(from: settings[.amazonBedrock]),
            credentialsProvider: bedrockCredentials
        ), sourceId: sourceId)
        if let azureEndpoint = URL(string: settings[.azureOpenAIResponses].baseURL), azureEndpoint.host != nil {
            await APIRegistry.shared.register(ProviderVariants.azureOpenAIResponses(
                endpoint: azureEndpoint,
                apiKey: nil
            ), sourceId: sourceId)
        }
        var openAIConfig = settings[.openAI]
        if openAIConfig.oauthAccountID == nil {
            let access = await BridgeAIProviderSecretStore.readSecret(for: .openAI, kind: .oauthAccessToken)
            openAIConfig.oauthAccountID = openAIAccountID(fromJWT: access)
            settings[.openAI] = openAIConfig
            try? await BridgeAIProviderSecretStore.saveSettings(settings)
        }
        await APIRegistry.shared.register(ProviderVariants.chatgptCodex(
            accessToken: nil,
            accountId: openAIConfig.oauthAccountID,
            originator: "bridge"
        ), sourceId: sourceId)
        await APIRegistry.shared.register(GoogleGeminiProvider(defaultAPIKey: nil), sourceId: sourceId)
        await registerGitHubCopilotProviders(settings: settings)
    }

    static func defaultModel() -> Model {
        ModelsCatalog.model(provider: "openai", id: "gpt-5") ?? availableModels().first ?? Models.gpt5
    }

    static func defaultModel(settings: BridgeAIProviderSettings) -> Model {
        availableModels(settings: settings).first ?? defaultModel()
    }

    static func selectedModel() async -> Model {
        let settings = await BridgeAIProviderSecretStore.readSettings()
        return selectedModel(settings: settings)
    }

    static func selectedModel(settings: BridgeAIProviderSettings) -> Model {
        let selected = enabledModel(
            runtimeModel(
                provider: settings.selectedModelProvider,
                id: settings.selectedModelID,
                settings: settings
            ),
            settings: settings
        )
        return selected ?? defaultModel(settings: settings)
    }

    static func selectedDisplayModel(settings: BridgeAIProviderSettings) -> Model {
        let selected = enabledModel(
            displayModel(
                provider: settings.selectedModelProvider,
                id: settings.selectedModelID,
                settings: settings
            ),
            settings: settings
        )
        return selected ?? defaultModel(settings: settings)
    }

    private static func enabledModel(_ model: Model?, settings: BridgeAIProviderSettings) -> Model? {
        model.flatMap { model in
            BridgeAIProvider.provider(for: model).flatMap { provider in
                settings[provider].isEnabled ? model : nil
            }
        }
    }

    static func runtimeModel(provider: String, id: String) async -> Model? {
        let settings = await BridgeAIProviderSecretStore.readSettings()
        return runtimeModel(provider: provider, id: id, settings: settings)
    }

    static func availableModels() -> [Model] {
        sortedModels(catalogModels() + openAIChatCompletionsModels(config: BridgeAIProviderSettings()[.openAIChatCompletions]))
    }

    static func availableModels(settings: BridgeAIProviderSettings) -> [Model] {
        var models = catalogModels().filter { model in
            guard let provider = BridgeAIProvider.provider(for: model) else { return false }
            let config = settings[provider]
            guard config.isEnabled else { return false }
            if provider == .openAI {
                switch config.authMethod {
                case .oauth:
                    return model.provider == "openai-codex"
                case .apiKey:
                    return model.provider == "openai" && model.api == "openai-responses"
                }
            }
            return true
        }

        let chatCompletionsConfig = settings[.openAIChatCompletions]
        if chatCompletionsConfig.isEnabled {
            models.append(contentsOf: openAIChatCompletionsModels(config: chatCompletionsConfig))
        }

        return sortedModels(models)
    }

    static func displayModel(provider: String, id: String) -> Model? {
        displayModel(provider: provider, id: id, settings: BridgeAIProviderSettings())
    }

    private static func displayModel(provider: String, id: String, settings: BridgeAIProviderSettings) -> Model? {
        if provider == BridgeAIProvider.openAIChatCompletions.rawValue {
            return openAIChatCompletionsModel(
                id: id,
                config: settings[.openAIChatCompletions]
            )
        }
        return ModelsCatalog.model(provider: provider, id: id)
    }

    static func displayProviderName(_ provider: String) -> String {
        BridgeAIProvider.allCases.first { $0.modelProviderIDs.contains(provider) }?.displayName
            ?? provider
    }

    private static func catalogModels() -> [Model] {
        let supportedAPIs: Set = [
            "anthropic-messages",
            "azure-openai-responses",
            "bedrock-converse-stream",
            "google-generative-ai",
            "github-copilot-chat",
            "mistral-conversations",
            "openai-codex-responses",
            "openai-completions",
            "openai-responses",
        ]
        return ModelsCatalog.all
            .filter { supportedAPIs.contains($0.api) }
    }

    private static func sortedModels(_ models: [Model]) -> [Model] {
        models.sorted { lhs, rhs in
            let left = "\(lhs.provider)/\(lhs.name)"
            let right = "\(rhs.provider)/\(rhs.name)"
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    static func availableModelsByProvider() -> [(provider: String, models: [Model])] {
        availableModelsByProvider(models: availableModels())
    }

    static func availableModelsByProvider(settings: BridgeAIProviderSettings) -> [(provider: String, models: [Model])] {
        availableModelsByProvider(models: availableModels(settings: settings))
    }

    private static func availableModelsByProvider(models: [Model]) -> [(provider: String, models: [Model])] {
        Dictionary(grouping: models, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { lhs, rhs in
                        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.provider.localizedStandardCompare(rhs.provider) == .orderedAscending
            }
    }

    static func authResolver() -> @Sendable (Model, String?) async -> ResolvedProviderAuth? {
        { model, sessionId in
            await resolveAuth(for: model, sessionId: sessionId)
        }
    }

    private static func resolveAuth(for model: Model, sessionId _: String?) async -> ResolvedProviderAuth? {
        guard let provider = BridgeAIProvider.provider(for: model) else { return nil }
        let config = await BridgeAIProviderSecretStore.readSettings()[provider]
        guard config.isEnabled else { return nil }

        let token = await resolvedToken(for: provider, config: config, model: model)
        guard !token.isEmpty else { return nil }

        var headers: [String: String] = [:]
        if provider == .anthropic, config.authMethod == .oauth {
            headers["anthropic-beta"] = "oauth-2025-04-20"
        }

        return ResolvedProviderAuth(
            token: token,
            scheme: authScheme(for: provider, method: config.authMethod),
            headers: headers,
            baseURL: config.resolvedBaseURL(for: provider)
        )
    }

    private static func runtimeModel(
        provider: String,
        id: String,
        settings: BridgeAIProviderSettings
    ) -> Model? {
        if provider == BridgeAIProvider.openAIChatCompletions.rawValue {
            return openAIChatCompletionsModel(id: id, config: settings[.openAIChatCompletions])
        }

        let catalogModel = ModelsCatalog.model(provider: provider, id: id)
        if provider == "openai-codex" ||
            (provider == "openai" && catalogModel?.api != "openai-completions" && settings[.openAI].authMethod == .oauth)
        {
            return codexRuntimeModel(id: id)
        }
        if provider == "mistral", catalogModel?.api == "mistral-conversations" {
            return mistralRuntimeModel(catalogModel)
        }
        if provider == BridgeAIProvider.githubCopilot.rawValue, let catalogModel {
            return githubCopilotRuntimeModel(catalogModel)
        }
        return catalogModel
    }

    private static func githubCopilotRuntimeModel(_ catalog: Model) -> Model {
        Model(
            id: catalog.id,
            name: catalog.name,
            api: "github-copilot-chat",
            provider: catalog.provider,
            baseUrl: catalog.baseUrl,
            reasoning: catalog.reasoning,
            input: catalog.input,
            cost: catalog.cost,
            contextWindow: catalog.contextWindow,
            maxTokens: catalog.maxTokens,
            headers: catalog.headers
        )
    }

    private static func openAIChatCompletionsModels(config: BridgeAIProviderConfig) -> [Model] {
        openAIChatCompletionsModelIDs(config: config).map { id in
            openAIChatCompletionsModel(id: id, config: config)
        }
    }

    private static func openAIChatCompletionsModelIDs(config: BridgeAIProviderConfig) -> [String] {
        let modelIDs = config.modelIDs ?? [Models.gpt4oMini.id]
        return modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { result, id in
                guard !result.contains(id) else { return }
                result.append(id)
            }
    }

    private static func openAIChatCompletionsModel(
        id: String,
        config: BridgeAIProviderConfig
    ) -> Model {
        let configuredBaseURL = normalizedBaseURL(config.baseURL)
        let baseURL = configuredBaseURL.isEmpty
            ? BridgeAIProvider.openAIChatCompletions.defaultBaseURL
            : configuredBaseURL
        let catalog = ModelsCatalog.model(provider: "openai", id: id)
        let builtin = id == Models.gpt4oMini.id ? Models.gpt4oMini : nil
        return Model(
            id: id,
            name: catalog?.name ?? builtin?.name ?? id,
            api: "openai-completions",
            provider: BridgeAIProvider.openAIChatCompletions.rawValue,
            baseUrl: baseURL,
            reasoning: catalog?.reasoning ?? builtin?.reasoning ?? false,
            input: catalog?.input ?? builtin?.input ?? [.text, .image],
            cost: catalog?.cost ?? builtin?.cost ?? .init(),
            contextWindow: catalog?.contextWindow ?? builtin?.contextWindow ?? 128_000,
            maxTokens: catalog?.maxTokens ?? builtin?.maxTokens ?? 16384,
            headers: catalog?.headers ?? builtin?.headers
        )
    }

    private static func normalizedBaseURL(_ baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func mistralRuntimeModel(_ catalog: Model?) -> Model? {
        guard let catalog else { return nil }
        return Model(
            id: catalog.id,
            name: catalog.name,
            api: "openai-completions",
            provider: catalog.provider,
            baseUrl: "https://api.mistral.ai/v1",
            reasoning: catalog.reasoning,
            input: catalog.input,
            cost: catalog.cost,
            contextWindow: catalog.contextWindow,
            maxTokens: catalog.maxTokens,
            headers: catalog.headers
        )
    }

    private static func codexRuntimeModel(id: String) -> Model? {
        let catalog = ModelsCatalog.model(provider: "openai-codex", id: id)
        guard catalog != nil || ModelsCatalog.model(provider: "openai", id: id) != nil else { return nil }
        return Model(
            id: id,
            name: catalog?.name ?? id,
            api: "chatgpt-codex",
            provider: "chatgpt-codex",
            baseUrl: "https://chatgpt.com",
            reasoning: catalog?.reasoning ?? true,
            input: catalog?.input ?? [.text, .image],
            cost: catalog?.cost ?? .init(),
            contextWindow: catalog?.contextWindow ?? 272_000,
            maxTokens: 0,
            headers: catalog?.headers
        )
    }

    private static func authScheme(
        for provider: BridgeAIProvider,
        method: BridgeAIProviderAuthMethod
    ) -> AuthScheme {
        switch method {
        case .oauth:
            .bearer
        case .apiKey:
            switch provider {
            case .openAI, .openAIChatCompletions, .cerebras, .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek,
                 .fireworks, .githubCopilot, .groq, .huggingFace, .kimiCoding, .minimax, .minimaxCN, .mistral,
                 .moonshotAI, .moonshotAICN, .opencode, .opencodeGo, .openRouter, .vercelAIGateway, .xAI, .xiaomi,
                 .zAI, .openAICompatible:
                .bearer
            case .anthropic:
                .apiKeyHeader(name: "x-api-key")
            case .googleGemini:
                .queryKey(name: "key")
            case .azureOpenAIResponses:
                .apiKeyHeader(name: "api-key")
            case .amazonBedrock:
                .none
            }
        }
    }

    private static func resolvedToken(
        for provider: BridgeAIProvider,
        config: BridgeAIProviderConfig,
        model: Model
    ) async -> String {
        if config.authMethod == .apiKey {
            return await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .apiKey)
        }

        let access = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthAccessToken)
        let refresh = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthRefreshToken)
        guard !refresh.isEmpty, config.oauthExpiresAt.map({ $0 <= Date() }) == true else {
            return access
        }
        guard let oauthProvider = oauthProvider(for: provider, model: model) else {
            return access
        }

        let credentials = OAuthCredentials(
            access: access,
            refresh: refresh,
            expires: Int64((config.oauthExpiresAt ?? Date()).timeIntervalSince1970 * 1000)
        )
        guard let refreshed = try? await oauthProvider.refresh(credentials, using: URLSessionHTTPClient()) else {
            return access
        }

        try? await BridgeAIProviderSecretStore.saveSecret(
            refreshed.access,
            for: provider,
            kind: .oauthAccessToken
        )
        try? await BridgeAIProviderSecretStore.saveSecret(
            refreshed.refresh,
            for: provider,
            kind: .oauthRefreshToken
        )
        var settings = await BridgeAIProviderSecretStore.readSettings()
        var nextConfig = settings[provider]
        nextConfig.oauthExpiresAt = Date(timeIntervalSince1970: Double(refreshed.expires) / 1000)
        if provider == .openAI {
            nextConfig.oauthAccountID = Self.openAIAccountID(fromJWT: refreshed.access)
        }
        if provider == .githubCopilot, case let .string(endpoint) = refreshed.extras["endpoint"] ?? .null, !endpoint.isEmpty {
            nextConfig.baseURL = endpoint
        }
        settings[provider] = nextConfig
        try? await BridgeAIProviderSecretStore.saveSettings(settings)
        return refreshed.access
    }

    private static func registerGitHubCopilotProviders(settings: BridgeAIProviderSettings) async {
        let baseURLString = settings[.githubCopilot].baseURL.isEmpty
            ? BridgeAIProvider.githubCopilot.defaultBaseURL
            : settings[.githubCopilot].baseURL
        let baseURL = URL(string: baseURLString) ?? URL(string: BridgeAIProvider.githubCopilot.defaultBaseURL)!
        await APIRegistry.shared.register(ProviderVariants.githubCopilot(
            sessionToken: nil,
            integrationID: "vscode-chat",
            baseURL: baseURL
        ), sourceId: sourceId)
        await APIRegistry.shared.register(ProviderVariants.githubCopilotAnthropic(
            sessionToken: nil,
            integrationID: "vscode-chat",
            baseURL: baseURL
        ), sourceId: sourceId)
        await APIRegistry.shared.register(ProviderVariants.githubCopilotResponses(
            sessionToken: nil,
            integrationID: "vscode-chat",
            baseURL: baseURL
        ), sourceId: sourceId)
    }

    private static func bedrockRegion(from config: BridgeAIProviderConfig) -> String {
        let raw = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "us-east-1" }
        if let url = URL(string: raw), let host = url.host {
            let prefix = "bedrock-runtime."
            let suffix = ".amazonaws.com"
            if host.hasPrefix(prefix), host.hasSuffix(suffix) {
                let start = host.index(host.startIndex, offsetBy: prefix.count)
                let end = host.index(host.endIndex, offsetBy: -suffix.count)
                return String(host[start ..< end])
            }
        }
        return raw
    }

    private static func bedrockCredentials() async -> AWSSigV4.Credentials? {
        let stored = await BridgeAIProviderSecretStore.readSecret(for: .amazonBedrock, kind: .apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let credentials = parseBedrockCredentials(stored) {
            return credentials
        }
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] else { return nil }
        return AWSSigV4.Credentials(
            accessKeyId: key,
            secretAccessKey: secret,
            sessionToken: env["AWS_SESSION_TOKEN"]
        )
    }

    private static func parseBedrockCredentials(_ raw: String) -> AWSSigV4.Credentials? {
        guard !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = object["accessKeyId"] as? String ?? object["AWS_ACCESS_KEY_ID"] as? String,
           let secret = object["secretAccessKey"] as? String ?? object["AWS_SECRET_ACCESS_KEY"] as? String
        {
            return AWSSigV4.Credentials(
                accessKeyId: key,
                secretAccessKey: secret,
                sessionToken: object["sessionToken"] as? String ?? object["AWS_SESSION_TOKEN"] as? String
            )
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return AWSSigV4.Credentials(
            accessKeyId: parts[0],
            secretAccessKey: parts[1],
            sessionToken: parts.dropFirst(2).first.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func openAIAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        let base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String
        else {
            return nil
        }
        return accountID
    }

    private static func oauthProvider(
        for provider: BridgeAIProvider,
        model _: Model
    ) -> (any OAuthProvider)? {
        switch provider {
        case .openAI:
            OpenAICodexOAuthProvider()
        case .openAIChatCompletions:
            nil
        case .anthropic:
            AnthropicOAuthProvider()
        case .githubCopilot:
            GitHubCopilotOAuthProvider()
        case .googleGemini:
            nil
        case .amazonBedrock, .azureOpenAIResponses, .cerebras, .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek,
             .fireworks, .groq, .huggingFace, .kimiCoding, .minimax, .minimaxCN, .mistral, .moonshotAI, .moonshotAICN,
             .opencode, .opencodeGo, .openRouter, .vercelAIGateway, .xAI, .xiaomi, .zAI, .openAICompatible:
            nil
        }
    }
}
