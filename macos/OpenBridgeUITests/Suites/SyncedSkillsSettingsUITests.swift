import AppKit
import XCTest

final class SyncedSkillsSettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var e2eHomeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        e2eHomeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBridgeSyncedSkillsUITests-\(UUID().uuidString)", isDirectory: true)
        try createSuggestedSkillFolders(in: e2eHomeDirectory)

        app = XCUIApplication()
        app.launchArguments = ["-e2eMode", "-e2eOpenSettings", "-e2eResetAccentColor", "-e2eLightAppearance"]
        app.launchEnvironment["OPENBRIDGE_E2E_HOME_DIRECTORY"] = e2eHomeDirectory.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let e2eHomeDirectory {
            try? FileManager.default.removeItem(at: e2eHomeDirectory)
        }
    }

    func testSuggestedAddButtonUsesAboutStyleBorderedButtonInLightMode() throws {
        openSyncedSkillsSettings()

        let addButton = app.buttons["settings.syncedSkills.suggested.add.claude"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))

        let screenshot = addButton.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Suggested Add Button"
        attachment.lifetime = .keepAlways
        add(attachment)

        let colorStats = try buttonColorStats(in: screenshot.pngRepresentation)
        XCTAssertLessThan(
            colorStats.nonLightPixelCoverage,
            0.45,
            "Suggested Add button should render as a bordered text button, not a filled prominent block."
        )
        XCTAssertGreaterThan(
            colorStats.averageCompositedLuminance,
            170,
            "Suggested Add button should keep a light bordered appearance in light mode."
        )

        addButton.click()
        XCTAssertFalse(addButton.waitForExistence(timeout: 3))
    }

    private func createSuggestedSkillFolders(in homeDirectory: URL) throws {
        let fileManager = FileManager.default
        for relativePath in [".claude/skills", ".codex/skills"] {
            let url = homeDirectory.appendingPathComponent(relativePath, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func openSyncedSkillsSettings() {
        let settingsWindow = app.windows["Settings"].firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10))

        let tabByIdentifier = app.descendants(matching: .any)["settings.tab.syncedSkills"].firstMatch
        if tabByIdentifier.waitForExistence(timeout: 3) {
            tabByIdentifier.click()
            return
        }

        let tabByTitle = app.staticTexts["Synced Skills"].firstMatch
        XCTAssertTrue(tabByTitle.waitForExistence(timeout: 3))
        tabByTitle.click()
    }

    private func buttonColorStats(in pngData: Data) throws -> ButtonColorStats {
        guard let image = NSImage(data: pngData) else {
            throw ColorSamplingError.invalidImage
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw ColorSamplingError.invalidImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ColorSamplingError.invalidImage
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminanceTotal = 0.0
        var nonLightPixelCount = 0.0
        var totalPixelCount = 0.0

        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Double(pixels[offset + 3]) / 255.0
            let red = Double(pixels[offset]) * alpha + 255.0 * (1.0 - alpha)
            let green = Double(pixels[offset + 1]) * alpha + 255.0 * (1.0 - alpha)
            let blue = Double(pixels[offset + 2]) * alpha + 255.0 * (1.0 - alpha)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

            luminanceTotal += luminance
            if luminance < 210 {
                nonLightPixelCount += 1
            }
            totalPixelCount += 1
        }

        guard totalPixelCount > 0 else {
            throw ColorSamplingError.noOpaquePixels
        }

        return ButtonColorStats(
            averageCompositedLuminance: luminanceTotal / totalPixelCount,
            nonLightPixelCoverage: nonLightPixelCount / totalPixelCount
        )
    }
}

private struct ButtonColorStats {
    let averageCompositedLuminance: Double
    let nonLightPixelCoverage: Double
}

private enum ColorSamplingError: Error {
    case invalidImage
    case noOpaquePixels
}
