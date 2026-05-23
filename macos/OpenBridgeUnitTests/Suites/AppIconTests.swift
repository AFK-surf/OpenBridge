import AppKit
@testable import OpenBridge
import Testing

@MainActor
struct AppIconTests {
    @Test
    func `default icon clears runtime override without setting a static image`() {
        let applier = RecordingAppIconApplier()

        let result = AppIcon.default.apply(to: applier, bundlePath: "/Applications/OpenBridge.app")

        #expect(applier.bundleIconCalls.count == 1)
        #expect(applier.bundleIconCalls[0].path == "/Applications/OpenBridge.app")
        #expect(applier.bundleIconCalls[0].image == nil)
        #expect(applier.applicationIconImages.count == 1)
        #expect(applier.applicationIconImages[0] == nil)
        #expect(result.didSetRuntimeIconOverride == false)
    }

    @Test
    func `alternate icon still installs a runtime image override`() {
        let applier = RecordingAppIconApplier()

        let result = AppIcon.appIconBLUEBLOCK.apply(to: applier, bundlePath: "/Applications/OpenBridge.app")

        #expect(applier.bundleIconCalls.count == 1)
        #expect(applier.bundleIconCalls[0].image != nil)
        #expect(applier.applicationIconImages.count == 2)
        #expect(applier.applicationIconImages[0] == nil)
        #expect(applier.applicationIconImages[1] != nil)
        #expect(result.didSetRuntimeIconOverride)
    }
}

@MainActor
private final class RecordingAppIconApplier: AppIconApplying {
    private(set) var bundleIconCalls: [(image: NSImage?, path: String)] = []
    private(set) var applicationIconImages: [NSImage?] = []

    func setBundleIcon(_ image: NSImage?, forFile path: String) -> Bool {
        bundleIconCalls.append((image, path))
        return true
    }

    func setApplicationIconImage(_ image: NSImage?) {
        applicationIconImages.append(image)
    }
}
