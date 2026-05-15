import Foundation

private enum PermissionKind: String, Hashable {
    case hostAccess = "host_access"

    init(rawValueOrDefault rawValue: String?) throws {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            self = .hostAccess
            return
        }
        guard let value = PermissionKind(rawValue: trimmed) else {
            throw ConnectorError.invalidParams("unsupported permission kind: \(trimmed)")
        }
        self = value
    }

    var approvalLabel: String {
        switch self {
        case .hostAccess:
            "permission"
        }
    }
}

private struct PermissionGrantKey: Hashable {
    let sessionKey: String
    let kind: PermissionKind
}

struct PermissionConfirmationReply: Sendable {
    let approved: Bool
    /// Populated only for ComputerUse start confirmations; host_access and
    /// similar always see nil.
    let mode: String?
}

private struct PendingConfirmation {
    var continuations: [CheckedContinuation<PermissionConfirmationReply, Never>]
    let sessionId: String?
    let grantKey: PermissionGrantKey?
    let respondsToPermissionMode: Bool
}

private enum PermissionReplyReason {
    static let expired = "expired"
}

/// In-process facade that routes local agent tools to macOS or the embedded VM.
@MainActor @Observable
final class LocalRuntimeConnector {
    enum State: String {
        case disconnected, connected
    }

    enum EnvironmentKind {
        case localMacOS
        case localVM

        var userVisibleName: String {
            switch self {
            case .localMacOS:
                "This Mac"
            case .localVM:
                "Safe Workspace on This Mac"
            }
        }

        var connectName: String {
            userVisibleName
        }

        var connectAlias: String {
            switch self {
            case .localMacOS:
                "local"
            case .localVM:
                "sandbox"
            }
        }

        var permissionEnvironmentLabel: String {
            userVisibleName
        }

        static func userVisibleName(forAlias alias: String) -> String {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }

            let normalized = trimmed
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            if normalized == "sandbox" || normalized.hasPrefix("sandbox-") || normalized == "local-vm" || normalized.hasPrefix("local-vm-") {
                return EnvironmentKind.localVM.userVisibleName
            }
            if normalized == "local" || normalized.hasPrefix("local-") {
                return EnvironmentKind.localMacOS.userVisibleName
            }
            if normalized == "cloud-vm" {
                return EnvironmentKind.localVM.userVisibleName
            }
            if normalized == "vfs" {
                return "Agent Files"
            }
            return trimmed
        }
    }

    enum Target {
        case localMacOS
        case embeddedVM(EmbeddedVMRuntimeBridge)
    }

    // MARK: - Public State

    private(set) var state: State = .disconnected

    // MARK: - Configuration

    let agentGroupId: String
    let environmentKind: EnvironmentKind
    let target: Target

    private static let maxSkillInventoryDescriptionLength = 3000

    // MARK: - Private

    private var runningProcesses: [String: Process] = [:]
    private var processLock = NSLock()
    private var grantedPermissionKeys: Set<PermissionGrantKey> = []
    private var pendingPermissionConfirmationIDsByGrantKey: [PermissionGrantKey: String] = [:]

    // MARK: - Init

    init(agentGroupId: String, environmentKind: EnvironmentKind, target: Target) {
        self.agentGroupId = agentGroupId
        self.environmentKind = environmentKind
        self.target = target
    }

    // MARK: - Lifecycle

    func connect() {
        state = .connected
    }

    func disconnect() {
        state = .disconnected
        clearAllGrantedPermissions()
        killAllProcesses()
    }

    func applyPermissionModeChange(_ mode: LocalEnvironmentPermissionMode) {
        guard environmentKind == .localMacOS else { return }

        switch mode {
        case .default:
            revokeGrantedPermissions()
        case .fullAccess:
            approvePendingHostAccessPermissions()
        }
    }

    private func currentArch() -> String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    func localDescription() -> String {
        let localHome = NSHomeDirectory()
        var parts = ["darwin/\(currentArch())"]
        if let version = ProcessInfo.processInfo.operatingSystemVersionString as String? {
            parts.append(version)
        }
        parts.append("home=\(localHome)")
        parts.append("cpus=\(ProcessInfo.processInfo.processorCount)")
        switch environmentKind {
        case .localMacOS:
            parts.append("This Mac environment; use environment=\"local\" to target it. This is the computer the user is currently using and the highest-risk protected environment. Commands and file operations affect the host directly with no connector sandbox. Do not use this by default and do not switch here on your own initiative. First use environment=\"sandbox\" whenever it can accomplish the goal. Only after concluding sandbox cannot do the job should you request or trigger local permission and execute host commands or other protected host operations. Permission is temporary for the current task execution; do not assume a past approval applies to later user requests. Before requesting or triggering local permission, describe exactly what you plan to do. This Mac shares the user's files with the safe local workspace. Never operate on both This Mac and the safe local workspace filesystems in the same task; choose one environment for filesystem work. If a task truly requires host execution, stay on This Mac for that task instead of continuing to modify files from the safe local workspace. This environment disappears when the OpenBridge client disconnects.")
        case .localVM:
            let mountDescription = Self.localVMMountDescription()
            parts.append("Safe Workspace on This Mac; use environment=\"sandbox\" to target it. This is the default environment and usually the safest way to work with the user's local files. Commands and file operations execute inside a protected bundled workspace, not directly on This Mac. Mounted host folders are available at their listed absolute macOS paths; reviewed-write mounts stay staged until the user accepts applying them back to the host, while direct-write mounts update the host immediately. Mounted folders: \(mountDescription). Prefer this environment unless the user explicitly requests direct host work or sandbox cannot complete the task. If sandbox can finish the task, stay here and do not request host access. Never operate on both the safe local workspace and This Mac filesystems in the same task; choose one environment for filesystem work. If the task truly requires host execution, stop using the safe local workspace filesystem for that task and switch fully to environment=\"local\". Commands here do not trigger host GUI or process side effects. Use absolute macOS home paths for user-visible folders: Desktop is \(localHome)/Desktop, Documents is \(localHome)/Documents, and Downloads is \(localHome)/Downloads. Use the same absolute macOS path in file tools and shell commands when you need those folders, and report that absolute macOS path back to the user. This environment disappears when the OpenBridge client disconnects.")
        }
        parts.append(Self.localSkillInventoryDescription(
            skills: SkillManager.shared.skills,
            homeDirectory: localHome,
            maxLength: Self.maxSkillInventoryDescriptionLength
        ))
        return parts.joined(separator: "; ")
    }

    private static func localVMMountDescription() -> String {
        LocalVMMount.defaultMounts()
            .map { mount in
                let mode = if mount.passthrough {
                    "direct writes"
                } else if mount.readOnly {
                    "read-only"
                } else {
                    "reviewed writes"
                }
                if mount.vmPath == mount.hostPath {
                    return "\(mount.hostPath) (\(mode))"
                }
                return "\(mount.hostPath) mounted at \(mount.vmPath) (\(mode))"
            }
            .joined(separator: ", ")
    }

    static func localSkillInventoryDescription(
        skills: [Skill],
        homeDirectory: String,
        maxLength: Int = 3000
    ) -> String {
        let skillsRoot = Self.skillsRootPath(homeDirectory: homeDirectory)
        let activeSkills = Self.activeSkills(skills)

        let prefix = """
        local skills available via this machine: read the referenced SKILL.md files through the local environment when relevant; root \(skillsRoot); discovered \(activeSkills.count) active skill(s)
        """

        guard !activeSkills.isEmpty else {
            return prefix + ": none"
        }

        var entries: [String] = []
        entries.reserveCapacity(activeSkills.count)

        for skill in activeSkills {
            let entry = "\(skill.name) [\(skillCategoryLabel(skill.category))] - \(normalizedDescription(skill.description)) @ \(skill.fileURL.path)"
            entries.append(entry)
        }

        var result = prefix + ": "
        var remainingCount = activeSkills.count

        for entry in entries {
            let separator = result.hasSuffix(": ") ? "" : " | "
            let candidate = result + separator + entry
            if candidate.count > maxLength {
                break
            }
            result = candidate
            remainingCount -= 1
        }

        if remainingCount > 0 {
            let suffix = " | ... (\(remainingCount) more skill(s) not shown)"
            if result.count + suffix.count <= maxLength {
                result += suffix
            } else if suffix.count < maxLength {
                let limit = maxLength - suffix.count
                result = String(result.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            }
        }

        return result
    }

    private static func activeSkills(_ skills: [Skill]) -> [Skill] {
        skills
            .filter { !$0.disabled && $0.visibility != .hidden }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func skillsRootPath(homeDirectory: String) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".openbridge/skills", isDirectory: true)
            .path
    }

    private static func skillCategoryLabel(_ category: Skill.Category) -> String {
        switch category {
        case .custom:
            "custom"
        case .synced:
            "sync"
        case .imported:
            "imported"
        case .reflected:
            "reflected"
        case .system:
            "system"
        }
    }

    private static func normalizedDescription(_ description: String) -> String {
        let trimmed = description
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: ";", with: ",")
        if trimmed.isEmpty {
            return "No description"
        }
        if trimmed.count <= 140 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 140)
        return String(trimmed[..<endIndex]) + "..."
    }

    private var pendingConfirmations: [String: PendingConfirmation] = [:]

    // MARK: - Path Safety

    private static let deniedReadPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent(".ssh"),
            (home as NSString).appendingPathComponent(".gnupg"),
            (home as NSString).appendingPathComponent(".aws"),
            (home as NSString).appendingPathComponent("Library/Keychains"),
        ]
    }()

    private static let allowedWritePaths: [String] = [
        "/private/tmp",
        "/private/var/folders",
        "/tmp",
    ]

    func resolvePath(_ requested: String) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardized
        return URL(fileURLWithPath: requested, relativeTo: home).standardized.path
    }

    func requiresPathPermission(elevated: Bool) -> Bool {
        guard elevated else { return false }
        guard environmentKind == .localMacOS else { return false }
        return SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess
    }

    func requiresMutationPermission() -> Bool {
        guard environmentKind == .localMacOS else { return false }
        guard SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess else { return false }
        return true
    }

    func requiresExecPermission(sessionId: String?) -> Bool {
        guard environmentKind == .localMacOS else { return false }
        guard SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess else { return false }
        return !hasGrantedPermission(sessionId: sessionId, kind: .hostAccess)
    }

    func requestHostAccessForTool(description: String, sessionId: String?) async -> Bool {
        await requestPermission(
            method: "tool",
            kind: .hostAccess,
            description: description,
            sessionId: sessionId
        )
    }

    func requestToolPermission(requestedEnvironment: String, description: String, sessionID: String?) async throws -> JSONValue {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            throw ConnectorError.invalidParams("description is required")
        }

        switch environmentKind {
        case .localVM:
            return .dict([
                "approved": true,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": "permission is not required for this environment",
            ])
        case .localMacOS:
            guard normalizedSessionKey(sessionID) != nil else {
                throw ConnectorError.invalidParams("request_permission requires session context")
            }
            if hasGrantedPermission(sessionId: sessionID, kind: .hostAccess) {
                return .dict([
                    "approved": true,
                    "environment_id": environmentKind.connectAlias,
                    "environment_label": environmentKind.permissionEnvironmentLabel,
                    "message": "permission is already granted for this task",
                ])
            }

            let requestEnvironment = requestedEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestDescription = requestEnvironment.isEmpty
                ? trimmedDescription
                : "\(trimmedDescription)\nRequested environment: \(EnvironmentKind.userVisibleName(forAlias: requestEnvironment))"
            let approved = await requestPermission(
                method: requestEnvironment.isEmpty ? environmentKind.connectAlias : requestEnvironment,
                kind: .hostAccess,
                description: requestDescription,
                sessionId: sessionID
            )
            return .dict([
                "approved": approved,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": approved ? "permission granted for this task" : "permission denied for this task",
            ])
        }
    }

    func protectedEnvironmentError(action: String) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.isEmpty ? "this operation" : trimmed
        return "environment \"local\" is protected; call request_permission(environment=\"local\", description=\"...\") before trying to \(detail)"
    }

    func checkReadPath(_ requested: String) -> (String, Bool) {
        let path = resolvePath(requested)
        for denied in Self.deniedReadPaths {
            if path == denied || path.hasPrefix(denied + "/") {
                return (path, true)
            }
        }
        return (path, false)
    }

    func checkWritePath(_ requested: String) -> (String, Bool) {
        let path = resolvePath(requested)
        for allowed in Self.allowedWritePaths {
            if path == allowed || path.hasPrefix(allowed + "/") {
                return (path, false)
            }
        }
        return (path, true)
    }

    // MARK: - Process Tracking

    func trackProcess(_ id: String, _ process: Process) {
        processLock.lock()
        runningProcesses[id] = process
        processLock.unlock()
    }

    func untrackProcess(_ id: String) {
        processLock.lock()
        runningProcesses.removeValue(forKey: id)
        processLock.unlock()
    }

    private func killAllProcesses() {
        processLock.lock()
        let processes = runningProcesses.values
        runningProcesses.removeAll()
        processLock.unlock()
        for process in processes {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func canResolveSessionConfirmation(id: String) -> Bool {
        canResolveConfirmation(id: id)
    }

    func resolveSessionConfirmation(id: String, approved: Bool, mode: String? = nil) {
        resolveConfirmation(id: id, approved: approved, mode: mode)
    }

    func clearSessionPermission(sessionId: String) {
        clearGrantedPermission(sessionId: sessionId)
    }
}

extension LocalRuntimeConnector {
    /// Inject a permission_request carrying mode-selection metadata and await
    /// the reply. Used by ComputerUse `start` to let the user pick background
    /// vs foreground in the chat card.
    func awaitComputerUseStart(
        availableModes: [String],
        apps: [String]?,
        permissions: [SessionHistoryMessage.ComputerUsePermissionPane]?,
        description: String,
        sessionId: String?
    ) async -> PermissionConfirmationReply {
        await awaitPermissionConfirmation(
            kind: .hostAccess, // computer_use no longer uses PermissionKind; this is unused when computerUseStart is non-nil
            description: description,
            sessionId: sessionId,
            computerUseStart: SessionHistoryMessage.ComputerUseStartInfo(
                availableModes: availableModes,
                apps: apps,
                permissions: permissions
            )
        )
    }

    func hasGrantedHostAccessPermission(sessionId: String?) -> Bool {
        hasGrantedPermission(sessionId: sessionId, kind: .hostAccess)
    }

    func hasGrantedHostAccessPermissionForTesting(sessionId: String?) -> Bool {
        hasGrantedHostAccessPermission(sessionId: sessionId)
    }
}

private extension LocalRuntimeConnector {
    // MARK: - User Confirmation

    func clearGrantedPermission(sessionId: String) {
        guard let sessionKey = normalizedSessionKey(sessionId) else { return }
        cancelPendingPermissionRequests(for: sessionKey)
        grantedPermissionKeys = Set(grantedPermissionKeys.filter { $0.sessionKey != sessionKey })
    }

    func revokeGrantedPermissions() {
        grantedPermissionKeys.removeAll()
    }

    func approvePendingHostAccessPermissions() {
        let confirmationIDs = pendingConfirmations.compactMap { id, pending in
            pending.respondsToPermissionMode ? id : nil
        }
        for confirmationID in confirmationIDs {
            resolveConfirmation(id: confirmationID, approved: true)
        }
    }

    /// Injects a permission_request message into the session that triggered the
    /// request (identified by sessionId) and suspends until the user clicks
    /// Allow or Deny in the chat UI. Returns false immediately if no session
    /// is available so the connector does not hang indefinitely.
    func requestPermission(
        method _: String,
        kind: PermissionKind,
        description: String,
        sessionId: String?
    ) async -> Bool {
        if hasGrantedPermission(sessionId: sessionId, kind: kind) {
            return true
        }

        let reply = await awaitPermissionConfirmation(
            kind: kind,
            description: description,
            sessionId: sessionId,
            computerUseStart: nil
        )
        return reply.approved
    }

    func awaitPermissionConfirmation(
        kind: PermissionKind,
        description: String,
        sessionId: String?,
        computerUseStart: SessionHistoryMessage.ComputerUseStartInfo?
    ) async -> PermissionConfirmationReply {
        let sessionKey = normalizedSessionKey(sessionId)
        // ComputerUse start requests do not use grant caching — each start is
        // an explicit user confirmation; the grant key is only populated for
        // host_access-style permissions.
        let grantKey: PermissionGrantKey? = if computerUseStart == nil {
            sessionKey.map { PermissionGrantKey(sessionKey: $0, kind: kind) }
        } else {
            nil
        }

        if let grantKey,
           let pendingConfirmationID = pendingPermissionConfirmationIDsByGrantKey[grantKey],
           pendingConfirmations[pendingConfirmationID] != nil
        {
            return await withCheckedContinuation { continuation in
                guard var pending = pendingConfirmations[pendingConfirmationID] else {
                    continuation.resume(returning: PermissionConfirmationReply(approved: false, mode: nil))
                    return
                }
                pending.continuations.append(continuation)
                pendingConfirmations[pendingConfirmationID] = pending
            }
        }
        if let grantKey {
            pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey)
        }

        let confirmationId = "connector-\(UUID().uuidString)"
        let requestMessage = SessionHistoryMessage(
            id: confirmationId,
            type: "permission_request",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: SessionHistoryMessage.PermissionRequestInfo(
                environmentId: environmentKind.connectAlias,
                environmentLabel: environmentKind.permissionEnvironmentLabel,
                kind: computerUseStart != nil ? "computer_use_start" : kind.rawValue,
                description: description,
                computerUseStart: computerUseStart
            ),
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
        guard AgentSessionManager.shared.injectMessage(requestMessage, intoSessionID: sessionId) else {
            return PermissionConfirmationReply(approved: false, mode: nil)
        }

        return await withCheckedContinuation { continuation in
            pendingConfirmations[confirmationId] = PendingConfirmation(
                continuations: [continuation],
                sessionId: sessionId,
                grantKey: grantKey,
                respondsToPermissionMode: computerUseStart == nil
            )
            if let grantKey {
                pendingPermissionConfirmationIDsByGrantKey[grantKey] = confirmationId
            }
        }
    }

    func canResolveConfirmation(id: String) -> Bool {
        pendingConfirmations[id] != nil
    }

    func resolveConfirmation(id: String, approved: Bool, mode: String? = nil) {
        guard let pending = pendingConfirmations.removeValue(forKey: id) else { return }
        if let grantKey = pending.grantKey,
           pendingPermissionConfirmationIDsByGrantKey[grantKey] == id
        {
            pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey)
        }

        let finalApproved = approved
        let reason: String? = nil

        if finalApproved, let grantKey = pending.grantKey {
            grantedPermissionKeys.insert(grantKey)
        }
        injectPermissionReply(
            confirmationId: id,
            sessionId: pending.sessionId,
            approved: finalApproved,
            reason: reason,
            mode: mode
        )
        resumePendingConfirmation(pending, approved: finalApproved, mode: mode)
    }

    func normalizedSessionKey(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func cancelPendingPermissionRequests(for sessionKey: String) {
        let grantKeys = pendingPermissionConfirmationIDsByGrantKey.keys.filter { $0.sessionKey == sessionKey }
        for grantKey in grantKeys {
            guard let confirmationID = pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey),
                  let pending = pendingConfirmations.removeValue(forKey: confirmationID)
            else {
                continue
            }
            injectPermissionReply(
                confirmationId: confirmationID,
                sessionId: pending.sessionId,
                approved: false,
                reason: PermissionReplyReason.expired
            )
            resumePendingConfirmation(pending, approved: false)
        }
    }

    func hasGrantedPermission(sessionId: String?, kind: PermissionKind = .hostAccess) -> Bool {
        guard environmentKind == .localMacOS else { return true }
        if kind == .hostAccess,
           SettingsManager.shared.localEnvironmentPermissionMode == .fullAccess
        {
            return true
        }
        guard let sessionKey = normalizedSessionKey(sessionId) else { return false }
        return grantedPermissionKeys.contains(PermissionGrantKey(sessionKey: sessionKey, kind: kind))
    }

    func clearAllGrantedPermissions() {
        grantedPermissionKeys.removeAll()
        pendingPermissionConfirmationIDsByGrantKey.removeAll()
        let pendingEntries = pendingConfirmations
        pendingConfirmations.removeAll()
        for (confirmationID, pending) in pendingEntries {
            injectPermissionReply(
                confirmationId: confirmationID,
                sessionId: pending.sessionId,
                approved: false,
                reason: PermissionReplyReason.expired
            )
            resumePendingConfirmation(pending, approved: false)
        }
    }

    func injectPermissionReply(
        confirmationId: String,
        sessionId: String?,
        approved: Bool,
        reason: String?,
        mode: String? = nil
    ) {
        guard let sessionId else { return }
        let replyMessage = SessionHistoryMessage(
            id: "reply-\(confirmationId)",
            type: "permission_reply",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: SessionHistoryMessage.PermissionReplyInfo(
                approved: approved,
                reason: reason,
                mode: mode
            ),
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
        AgentSessionManager.shared.injectMessage(replyMessage, intoSessionID: sessionId)
    }

    func resumePendingConfirmation(
        _ pending: PendingConfirmation,
        approved: Bool,
        mode: String? = nil
    ) {
        let reply = PermissionConfirmationReply(approved: approved, mode: mode)
        for continuation in pending.continuations {
            continuation.resume(returning: reply)
        }
    }
}
