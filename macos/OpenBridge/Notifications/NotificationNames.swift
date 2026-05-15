import Foundation

extension Notification.Name {
    // MARK: - Window

    static let windowDidOpen = Notification.Name("windowDidOpen")

    // MARK: - Permissions

    static let microphonePermissionDidChange = Notification.Name("microphonePermissionDidChange")

    // MARK: - Chat

    /// Posted when a skill should be activated in chat. The notification's `object` should be a `SkillInfo`.
    static let skillActivationRequested = Notification.Name("skillActivationRequested")
    static let skillInventoryDidChange = Notification.Name("skillInventoryDidChange")
    static let aiProviderSettingsDidChange = Notification.Name("aiProviderSettingsDidChange")

    // MARK: - Shortcuts

    static let keyboardShortcutsShortcutDidChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
}
