import SwiftUI

struct AIProvidersSettingsView: View {
    @Binding var navigationPath: NavigationPath
    @State private var providerSettings = BridgeAIProviderSettings()
    @State private var configuredSecrets: [BridgeAIProvider: Bool] = [:]
    @State private var usageSnapshots: [BridgeAIProvider: BridgeAIProviderUsageSnapshot] = [:]
    @State private var isRefreshingUsage = false
    @State private var searchText = ""
    @State private var statusFilter: AIProviderStatusFilter = .all

    private var filteredProviders: [BridgeAIProvider] {
        BridgeAIProvider.displayOrder.filter { provider in
            let matchesSearch = searchText.isEmpty
                || provider.displayName.localizedStandardContains(searchText)
            let state = rowState(for: provider)
            return matchesSearch && statusFilter.includes(state)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                providerListCard
                storageCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("AI Providers")
        .task {
            await reload()
        }
        .onChange(of: navigationPath) { _, newPath in
            guard newPath.isEmpty else { return }
            Task { await reload() }
        }
        .onReceiveNotification(name: .aiProviderSettingsDidChange) { _ in
            Task { await reload() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Providers")
                .font(.system(size: 28, weight: .semibold))

            Text("Connect and manage model providers used by OpenBridge.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var providerListCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                searchField

                Spacer()

                Picker("Status", selection: $statusFilter) {
                    ForEach(AIProviderStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 154)

                Button {
                    Task { await reload() }
                } label: {
                    if isRefreshingUsage {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingUsage)
                .help("Refresh provider status")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 20)

            if filteredProviders.isEmpty {
                ContentUnavailableView(
                    "No Providers",
                    systemImage: "magnifyingglass",
                    description: Text("No AI providers match the current search and status filter.")
                )
                .frame(minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredProviders) { provider in
                        NavigationLink(value: SettingsDestination.aiProviderDetail(provider)) {
                            AIProviderListRow(
                                provider: provider,
                                state: rowState(for: provider),
                                showsUsage: showsUsage(for: provider),
                                usage: usageSnapshot(for: provider)
                            )
                        }
                        .buttonStyle(.plain)

                        if provider != filteredProviders.last {
                            Divider()
                                .padding(.leading, 78)
                                .padding(.trailing, 20)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search providers", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 38)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
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
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func reload() async {
        providerSettings = await BridgeAIProviderSecretStore.readSettings()
        await refreshConfiguredSecrets()
        await refreshUsage()
    }

    private func refreshConfiguredSecrets() async {
        var next: [BridgeAIProvider: Bool] = [:]
        for provider in BridgeAIProvider.allCases {
            let config = providerSettings[provider]
            let kind: BridgeAIProviderSecretKind = config.authMethod == .apiKey ? .apiKey : .oauthAccessToken
            next[provider] = await BridgeAIProviderSecretStore.hasSecret(for: provider, kind: kind)
        }
        configuredSecrets = next
    }

    private func refreshUsage() async {
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        usageSnapshots = await BridgeAIProviderUsageService.refreshConfigured(
            settings: providerSettings,
            configuredSecrets: configuredSecrets
        )
    }

    private func showsUsage(for provider: BridgeAIProvider) -> Bool {
        let config = providerSettings[provider]
        return rowState(for: provider).isConfigured && config.authMethod == .oauth
    }

    private func rowState(for provider: BridgeAIProvider) -> AIProviderRowState {
        let config = providerSettings[provider]
        let hasSecret = configuredSecrets[provider] ?? false
        if config.isEnabled, hasSecret {
            return .configured(method: config.authMethod)
        }
        if config.isEnabled {
            return .missing(method: config.authMethod)
        }
        return .notConfigured
    }

    private func usageSnapshot(for provider: BridgeAIProvider) -> BridgeAIProviderUsageSnapshot {
        let state = rowState(for: provider)
        guard state.isConfigured else { return .unavailable }
        return usageSnapshots[provider] ?? .unavailable
    }
}

private struct AIProviderListRow: View {
    let provider: BridgeAIProvider
    let state: AIProviderRowState
    let showsUsage: Bool
    let usage: BridgeAIProviderUsageSnapshot

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: provider, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(state.tint)
                        .frame(width: 7, height: 7)
                    Text(state.title)
                        .font(.caption)
                        .foregroundStyle(state.tint)
                }
            }

            Spacer(minLength: 20)

            if showsUsage {
                HStack(spacing: 8) {
                    UsageBadge(
                        title: "5h",
                        value: usage.label(for: .fiveHour),
                        tone: usage.tone(for: .fiveHour)
                    )
                    UsageBadge(
                        title: "1w",
                        value: usage.label(for: .oneWeek),
                        tone: usage.tone(for: .oneWeek)
                    )
                }
            } else {
                Text("Set Up")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
            }

            Image(systemName: "chevron.right")
                .font(.body.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .onHover { isHovering = $0 }
    }
}

struct ProviderIcon: View {
    let provider: BridgeAIProvider
    var size: CGFloat = 52

    var body: some View {
        if NSImage(named: provider.logoImageName) != nil {
            logoIcon
        } else {
            fallbackIcon
        }
    }

    private var logoIcon: some View {
        Image(provider.logoImageName)
            .resizable()
            .renderingMode(provider.usesTemplateLogoRendering ? .template : .original)
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: logoSize, height: logoSize)
            .frame(width: size, height: size)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .accessibilityLabel(provider.displayName)
    }

    private var logoSize: CGFloat {
        size * 0.62
    }

    private var fallbackIcon: some View {
        Image(systemName: provider.iconName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .accessibilityLabel(provider.displayName)
    }
}

struct UsageBadge: View {
    let title: String
    let value: String
    var tone: UsageBadgeTone = .good

    var body: some View {
        Text("\(title) \(value)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.foregroundStyle)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(tone.backgroundStyle, in: Capsule())
    }
}

private extension UsageBadgeTone {
    var foregroundStyle: Color {
        switch self {
        case .good:
            .green
        case .warning:
            .orange
        case .danger:
            .red
        case .unavailable:
            .secondary
        }
    }

    var backgroundStyle: Color {
        switch self {
        case .good:
            .green.opacity(0.13)
        case .warning:
            .orange.opacity(0.14)
        case .danger:
            .red.opacity(0.14)
        case .unavailable:
            .secondary.opacity(0.12)
        }
    }
}

private enum AIProviderStatusFilter: String, CaseIterable, Identifiable {
    case all
    case configured
    case notConfigured

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All Statuses"
        case .configured: "Configured"
        case .notConfigured: "Not Configured"
        }
    }

    func includes(_ state: AIProviderRowState) -> Bool {
        switch self {
        case .all:
            true
        case .configured:
            state.isConfigured
        case .notConfigured:
            !state.isConfigured
        }
    }
}

private enum AIProviderRowState: Equatable {
    case configured(method: BridgeAIProviderAuthMethod)
    case missing(method: BridgeAIProviderAuthMethod)
    case notConfigured

    var title: String {
        switch self {
        case let .configured(method): "Configured with \(method.displayName)"
        case let .missing(method): "Missing \(method.displayName)"
        case .notConfigured: "Not configured"
        }
    }

    var tint: Color {
        switch self {
        case .configured: .green
        case .missing: .orange
        case .notConfigured: .secondary
        }
    }

    var isConfigured: Bool {
        if case .configured = self {
            return true
        }
        return false
    }
}

extension BridgeAIProvider {
    var accentColor: Color {
        switch self {
        case .openAI, .openAIChatCompletions: .green
        case .anthropic: .orange
        case .googleGemini: .blue
        case .amazonBedrock: .orange
        case .azureOpenAIResponses: .blue
        case .cerebras: .red
        case .cloudflareAIGateway, .cloudflareWorkersAI: .orange
        case .deepSeek: .blue
        case .fireworks: .red
        case .githubCopilot: .purple
        case .groq: .orange
        case .huggingFace: .yellow
        case .kimiCoding, .moonshotAI, .moonshotAICN: .indigo
        case .minimax, .minimaxCN: .pink
        case .mistral: .purple
        case .opencode, .opencodeGo: .gray
        case .openRouter: .cyan
        case .vercelAIGateway: .black
        case .xAI: .primary
        case .xiaomi: .orange
        case .zAI: .teal
        case .openAICompatible: .secondary
        }
    }
}

#Preview {
    NavigationStack {
        AIProvidersSettingsView(navigationPath: .constant(NavigationPath()))
            .environment(SettingsManager.shared)
    }
}
