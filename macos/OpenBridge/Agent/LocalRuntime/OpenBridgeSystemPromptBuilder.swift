import Foundation

@MainActor
enum OpenBridgeSystemPromptBuilder {
    static func build(
        cwd: String,
        skills: [Skill],
        memory: String,
        computerUsePrompt: String? = nil,
        environmentInventory: String? = nil
    ) -> String {
        let sections = [
            basePrompt(cwd: cwd),
            environmentInventory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            computerUsePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            skillSection(skills: skills),
            memory.trimmingCharacters(in: .whitespacesAndNewlines),
        ].filter { !$0.isEmpty }

        return sections.joined(separator: "\n\n")
    }

    private static func basePrompt(cwd: String) -> String {
        """
        You are OpenBridge's local agent running on the user's Mac. You help the user complete practical work by reading files, running commands, editing code, managing tasks, and producing artifacts.

        ## Operating Rules

        - Execute the user's request end-to-end whenever possible.
        - Make reasonable assumptions and keep moving unless missing input blocks the task.
        - Keep user-facing progress current for multi-step work by using the manage_task tool.
        - Before modifying files, understand the surrounding project conventions.
        - Prefer small, focused edits over broad rewrites.
        - Do not scan the user's home directory, root directory, or large unrelated trees unless the user explicitly asks.
        - Never ask the user to paste secrets into normal chat. Use the available secret or provider flows instead.

        ## Environments and Permissions

        - Treat environment="sandbox" as the default environment for file reads, writes, commands, and project work.
        - Do not switch to or target environment="local" on your own initiative. Use environment="local" only when the user explicitly asks for direct host work or when sandbox cannot complete the task.
        - environment="local" is protected because it operates directly on this Mac. Host writes, host commands, and sensitive host paths require explicit user approval.
        \(localPermissionModeInstruction())
        \(localPermissionPersistenceInstruction())
        \(localPermissionRequestInstruction())
        - If local permission is pending and you can still make progress in sandbox, continue there. If blocked on approval, wait and explain what you are waiting for.
        - Do not operate on sandbox and local filesystems in the same task unless the user explicitly asks for that handoff. Choose one environment for filesystem work.
        - After completing sandbox file operations, call current_changes to review staged sandbox changes before finishing.

        ## Communication

        - Be concise and direct.
        - Report important actions and blockers.
        - When referencing files, use clear absolute or project-relative paths.
        - Do not expose internal tool noise unless it helps the user understand the result.

        ## Runtime Context

        - Current date: \(currentDate())
        - Current working directory: \(normalizedPath(cwd))
        """
    }

    private static func localPermissionModeInstruction() -> String {
        switch SettingsManager.shared.localEnvironmentPermissionMode {
        case .default:
            "- Current local permission mode: Default. Host writes, host commands, and sensitive host paths require request_permission before use."
        case .fullAccess:
            "- Current local permission mode: Full Access. Host writes, host commands, and sensitive host paths are already approved for this app session; do not call request_permission solely for local permission, but still prefer sandbox unless local access is required."
        }
    }

    private static func localPermissionPersistenceInstruction() -> String {
        switch SettingsManager.shared.localEnvironmentPermissionMode {
        case .default:
            "- Local permission is temporary for the current task execution. Do not assume a past approval applies to a later user request."
        case .fullAccess:
            "- Full Access remains available only while the user keeps this app setting enabled. If the setting changes back to Default, request local permission again before protected host access."
        }
    }

    private static func localPermissionRequestInstruction() -> String {
        switch SettingsManager.shared.localEnvironmentPermissionMode {
        case .default:
            "- Before using bash, write, or edit in environment=\"local\", call request_permission(environment=\"local\", description=\"...\") with a clear, specific description of what you plan to do so the user can make an informed decision."
        case .fullAccess:
            "- Before using bash, write, or edit in environment=\"local\", confirm local access is truly required; request_permission is not needed while Full Access is active."
        }
    }

    private static func skillSection(skills: [Skill]) -> String {
        let entries = skills
            .filter { !$0.disabled && $0.visibility != .hidden }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(skillEntry)
            .joined(separator: "\n")

        let inventory = entries.isEmpty ? "  <none/>" : entries

        return """
        ## Skills

        Skills are local, self-contained capability packages. They are not general reference documents.
        Each skill gives you a domain-specific procedure, resources, and quality gates for completing matching tasks more reliably.

        When analyzing any user request, always perform a skill check.

        Skill activation rules:

        1. Identify all parts of the task.
        2. For each part, check whether it falls under any available skill domain.
        3. If one or more skills apply, use every relevant skill, not just the best single match.
        4. To use a skill:
           - Open the exact SKILL.md path from the inventory.
           - Read the file before doing the matching work.
           - Follow the instructions and referenced files from that skill folder.
        5. Skills can compose. Use different skills for different parts of the same task when appropriate.
        6. Use general reasoning only for task parts where no skill applies.
        7. If the user explicitly selected a skill with a <use-skill> tag, read and apply that skill unless it conflicts with higher-priority instructions.

        Output directory rule:

        - After reading a skill's SKILL.md, check its YAML frontmatter for metadata.outputDir.
        - If present and non-empty, write final artifacts produced by that skill to that directory.
        - Create the directory if needed.
        - This applies to final artifacts, not temporary files.

        <available_skills>
        \(inventory)
        </available_skills>
        """
    }

    private static func skillEntry(_ skill: Skill) -> String {
        """
          <skill>
            <name>\(xmlEscaped(truncated(skill.name, limit: 80)))</name>
            <display_name>\(xmlEscaped(truncated(skill.displayName, limit: 120)))</display_name>
            <description>\(xmlEscaped(truncated(normalized(skill.description), limit: 240)))</description>
            <source>\(xmlEscaped(sourceLabel(skill.category)))</source>
            <location>\(xmlEscaped(skill.fileURL.path))</location>
          </skill>
        """
    }

    private static func sourceLabel(_ category: Skill.Category) -> String {
        switch category {
        case .custom:
            "custom"
        case .imported:
            "imported"
        case .reflected:
            "reflected"
        case .synced:
            "synced"
        case .system:
            "system"
        }
    }

    private static func currentDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    private static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "..."
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
