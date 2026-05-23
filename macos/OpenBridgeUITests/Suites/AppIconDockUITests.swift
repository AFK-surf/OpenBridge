import XCTest

final class AppIconDockUITests: XCTestCase {
    private var app: XCUIApplication!
    private var reportURL: URL!
    private var reportDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        reportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBridgeAppIconUITests-\(UUID().uuidString)", isDirectory: true)
        reportURL = reportDirectory.appendingPathComponent("app-icon-report.txt", isDirectory: false)

        app = XCUIApplication()
        app.launchArguments = [
            "-e2eMode",
            "-e2eResetAppIcon",
            "-e2eAssertDefaultAppIconUsesSystemRenderer",
        ]
        app.launchEnvironment["OPENBRIDGE_E2E_APP_ICON_REPORT_PATH"] = reportURL.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let reportDirectory {
            try? FileManager.default.removeItem(at: reportDirectory)
        }
    }

    func testDefaultDockIconLaunchLeavesRuntimeOverrideCleared() throws {
        let report = try waitForReport(timeout: 8)

        XCTAssertTrue(report.contains("appIcon=default"), report)
        XCTAssertTrue(report.contains("runtimeIconOverrideCleared=true"), report)
    }

    private func waitForReport(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: reportURL.path) {
                return try String(contentsOf: reportURL, encoding: .utf8)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Expected app icon E2E report at \(reportURL.path)")
        return ""
    }
}
