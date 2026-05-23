import Foundation
import KWWKAI
@testable import OpenBridge
import Testing

private actor ProviderAvailabilityProbe {
    private(set) var missingCount = 0

    func recordMissingProvider() {
        missingCount += 1
    }
}

struct BridgeAIProviderRegistryTests {
    @Test
    func `concurrent provider refreshes keep Gemini registered`() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("secrets.json", isDirectory: false)
        BridgeAIProviderSecretStore.setStoreURLForTesting(storeURL)
        defer {
            BridgeAIProviderSecretStore.setStoreURLForTesting(nil)
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        var settings = BridgeAIProviderSettings(selectedModelProvider: "google", selectedModelID: "gemini-2.5-flash")
        var geminiConfig = settings[.googleGemini]
        geminiConfig.isEnabled = true
        geminiConfig.authMethod = .apiKey
        settings[.googleGemini] = geminiConfig
        try await BridgeAIProviderSecretStore.saveSecret("test-key", for: .googleGemini, kind: .apiKey)
        try await BridgeAIProviderSecretStore.saveSettings(settings)

        await BridgeAIProviderRegistry.registerProviders()
        let initiallyRegistered = await APIRegistry.shared.provider(for: "google-generative-ai")
        #expect(initiallyRegistered != nil)

        let probe = ProviderAvailabilityProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 40 {
                group.addTask {
                    await BridgeAIProviderRegistry.registerProviders()
                }
            }

            for _ in 0 ..< 4 {
                group.addTask {
                    for _ in 0 ..< 1000 {
                        let provider = await APIRegistry.shared.provider(for: "google-generative-ai")
                        if provider == nil {
                            await probe.recordMissingProvider()
                            return
                        }
                        await Task.yield()
                    }
                }
            }
        }

        let missingCount = await probe.missingCount
        #expect(missingCount == 0)
    }
}
