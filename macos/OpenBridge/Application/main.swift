//
//  main.swift
//  OpenBridge
//
//  Created by qaq on 14/10/2025.
//

@_exported import AppKit
@_exported import Foundation
@_exported import OSLog

private var isPreviewMode: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

#if DEBUG
    @MainActor
    private func configureE2EEnvironment() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-e2eMode") else { return }

        // E2E runs happen on a reused CI host, so clear debug-only flags that can
        // trigger permission prompts or other non-deterministic startup behavior.
        UserDefaults.standard.set(false, forKey: SettingsKeyName.enableDebugMode.key)

        // Force dock icon so the app runs as .regular and XCUITest sees it as foreground
        UserDefaults.standard.set(true, forKey: SettingsKeyName.showDockIcon.key)

        if arguments.contains("-e2eResetAccentColor") {
            UserDefaults.standard.set(SystemAccentColor.default.rawValue, forKey: SettingsKeyName.accentColorName.key)
        }

        if arguments.contains("-e2eResetAppIcon") {
            UserDefaults.standard.set(AppIcon.default.rawValue, forKey: SettingsKeyName.appIcon.key)
        }

        SettingsManager.shared.enabledFeatures = SettingsManager.Defaults.enabledFeatures
    }
#endif

MainActor.assumeIsolated {
    var appDelegate: NSApplicationDelegate?

    // skip some side effects in preview mode
    if !isPreviewMode {
        #if DEBUG
            configureE2EEnvironment()
        #endif

        _ = Logger.loggingSubsystem
        _ = SettingsManager.shared

        appDelegate = AppDelegate()
        NSApplication.shared.delegate = appDelegate
    }

    let ret = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    exit(ret)
}

fatalError()
