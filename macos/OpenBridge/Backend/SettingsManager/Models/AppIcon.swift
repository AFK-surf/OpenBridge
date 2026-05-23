//
//  AppIcon.swift
//  OpenBridge
//
//  Created by qaq on 18/12/2025.
//

import Cocoa
import SwiftUI

@MainActor
protocol AppIconApplying {
    func setBundleIcon(_ image: NSImage?, forFile path: String) -> Bool
    func setApplicationIconImage(_ image: NSImage?)
}

struct AppIconApplyResult: Equatable {
    let didSetRuntimeIconOverride: Bool
}

struct SystemAppIconApplier: AppIconApplying {
    func setBundleIcon(_ image: NSImage?, forFile path: String) -> Bool {
        NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }

    func setApplicationIconImage(_ image: NSImage?) {
        NSApp.applicationIconImage = image
    }
}

enum AppIcon: String, CaseIterable, Identifiable, Codable {
    case `default`
    #if DEBUG
        case appIconDev
    #endif

    case appIconBLUEBLOCK
    case appIconMERCURY

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .default: String(localized: "Default")
        #if DEBUG
            case .appIconDev: String(localized: "Developer")
        #endif
        case .appIconBLUEBLOCK: String(localized: "Blue Lock")
        case .appIconMERCURY: String(localized: "Mercury")
        }
    }

    var image: NSImage {
        let read: NSImage? = switch self {
        case .default: .init(named: "AppIcon")
        #if DEBUG
            case .appIconDev: .init(named: "AppIconDev")
        #endif
        case .appIconBLUEBLOCK: .init(named: "AppIconBLUEBLOCK")
        case .appIconMERCURY: .init(named: "AppIconMERCURY")
        }
        return read ?? .appLogo
    }

    var placeholderColors: [Color] {
        switch self {
        case .default:
            []
        #if DEBUG
            case .appIconDev:
                []
        #endif
        case .appIconBLUEBLOCK:
            []
        case .appIconMERCURY:
            []
        }
    }

    @MainActor
    @discardableResult
    func apply(
        to applier: AppIconApplying = SystemAppIconApplier(),
        bundlePath: String = Bundle.main.bundleURL.path
    ) -> AppIconApplyResult {
        if self == .default {
            if !applier.setBundleIcon(nil, forFile: bundlePath) {
                Logger.app.error("Failed to reset bundle icon for \(bundlePath)")
            }
            applier.setApplicationIconImage(nil)
            return AppIconApplyResult(didSetRuntimeIconOverride: false)
        }

        let customIcon = image
        if !applier.setBundleIcon(customIcon, forFile: bundlePath) {
            Logger.app.error("Failed to set bundle icon for \(bundlePath)")
        }
        applier.setApplicationIconImage(nil)
        applier.setApplicationIconImage(customIcon)
        return AppIconApplyResult(didSetRuntimeIconOverride: true)
    }

    #if DEBUG
        static func validateAll() {
            for eachCase in allCases {
                assert(eachCase.image != .appLogo)
            }
            Logger.app.info("\(allCases.count) alternative image asset has been validated!")
        }
    #endif
}
