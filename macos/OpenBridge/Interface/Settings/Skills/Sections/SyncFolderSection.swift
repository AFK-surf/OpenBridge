import AppKit
import ComposerEditor
import SwiftUI

struct SyncFolderSection: View {
    let onNavigateToAllSkills: ((URL) -> Void)?

    @State private var folders: [URL] = []
    @State private var selectedFolder: URL?
    @State private var showingRemoveConfirmation = false
    @State private var refreshRotations: [String: Double] = [:]
    @State private var alertMessage: String?
    @State private var showingAlert = false

    private let maxDisplayedSkills = 5

    private var suggestedFolders: [(source: SkillDirectories.SyncSkillSource, url: URL)] {
        let homeDirectory = SkillDirectories.homeDirectory
        let fileManager = FileManager.default

        return SkillDirectories.defaultSyncSkillSources.compactMap { source in
            let url = homeDirectory.appendingPathComponent(source.relativePath).standardized
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            guard !folders.contains(url) else { return nil }
            return (source, url)
        }
    }

    init(onNavigateToAllSkills: ((URL) -> Void)? = nil) {
        self.onNavigateToAllSkills = onNavigateToAllSkills
    }

    var body: some View {
        Group {
            syncFoldersSection

            if !suggestedFolders.isEmpty {
                suggestedFoldersSection
            }

            if !folders.isEmpty {
                syncedFolderSkillSections
            }
        }
        .onAppear {
            loadFolders()
        }
        .alert("Remove Sync Folder", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeSyncFolder()
            }
        } message: {
            if let selectedFolder {
                Text("Remove sync folder '\(selectedFolder)'? Skills from this folder will no longer be available.")
            }
        }
        .alert("Message", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let alertMessage {
                Text(alertMessage)
            }
        }
    }
}

private extension SyncFolderSection {
    var syncFoldersSection: some View {
        Section {
            List {
                if folders.isEmpty {
                    Text("No sync folders found")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .frame(height: 48)
                } else {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        folderRow(folder, isLast: index == folders.count - 1)
                    }
                }

                folderToolbarRow
            }
        } header: {
            Text("Sync Folders")
        } footer: {
            Text("Sync skills from any folder you use. Select a folder from another app, and we'll automatically monitor and keep your skills synchronized.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    func folderRow(_ folder: URL, isLast: Bool) -> some View {
        let isSelected = selectedFolder == folder
        let source = SkillDirectories.syncSkillSource(for: folder)

        return HStack {
            Label {
                Text(folder.path)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                if let imageName = source?.imageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "folder")
                }
            }
            .labelStyle(
                source?.imageName != nil
                    ? SettingItemLabelStyle(iconSize: 20, containerSize: 28, iconCornerRadius: 8)
                    : SettingItemLabelStyle(
                        style: AnyShapeStyle(Color.blue.gradient),
                        containerSize: 28,
                        iconSize: 14,
                        iconCornerRadius: 8
                    )
            )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFolder = isSelected ? nil : folder
        }
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .listRowSeparator(isLast ? .hidden : .automatic)
    }

    var folderToolbarRow: some View {
        HStack {
            Button {
                addSyncFolder()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help("Add folder")

            Divider()

            Button {
                guard selectedFolder != nil else { return }
                showingRemoveConfirmation = true
            } label: {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help("Remove folder")
            .disabled(selectedFolder == nil)

            Spacer()
        }
        .listRowBackground(Color.primary.opacity(0.06))
    }

    var suggestedFoldersSection: some View {
        Section {
            List {
                ForEach(suggestedFolders, id: \.source.key) { item in
                    SuggestedSyncFolderRow(source: item.source, url: item.url) {
                        addSuggestedFolder(item)
                    }
                }
            }
        } header: {
            Text("Suggested")
        }
    }

    var syncedFolderSkillSections: some View {
        ForEach(folders, id: \.self) { folder in
            let syncSkills = SkillManager.shared.getSkillsFromSyncFolder(folder: folder)

            if !syncSkills.isEmpty {
                Section {
                    List {
                        ForEach(syncSkills.prefix(maxDisplayedSkills), id: \.name) { skill in
                            SkillRow(skill: skill)
                        }

                        if syncSkills.count > maxDisplayedSkills {
                            Button {
                                onNavigateToAllSkills?(folder)
                            } label: {
                                HStack {
                                    Text("Show more")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    syncSkillsHeader(for: folder)
                }
            }
        }
    }

    func syncSkillsHeader(for folder: URL) -> some View {
        HStack {
            Text(folder.path)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                refreshFolder(folder)
            } label: {
                HStack {
                    Text("Refresh")
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .rotationEffect(.degrees(refreshRotations[folder.path, default: 0]))
                }
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}

private extension SyncFolderSection {
    func loadFolders() {
        folders = SkillManager.shared.skillDirs.getResolvedSyncSkillFolderURLs()
    }

    func addSuggestedFolder(_ item: (source: SkillDirectories.SyncSkillSource, url: URL)) {
        do {
            try SkillManager.shared.addSyncSkillFolder(url: item.url, alias: item.source.key)
            loadFolders()
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    func addSyncFolder() {
        Task { @MainActor in
            let urls = await FilePicker.pickURLs(
                canChooseFiles: false,
                canChooseDirectories: true,
                allowsMultipleSelection: false,
                showsHiddenFiles: true,
                directoryURL: URL(fileURLWithPath: NSHomeDirectory()),
                message: "Select a folder containing skills to sync"
            )
            guard let url = urls.first else { return }

            do {
                try SkillManager.shared.addSyncSkillFolder(url: url)
                loadFolders()
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    func removeSyncFolder() {
        guard let selectedFolder else { return }

        do {
            try SkillManager.shared.removeSyncSkillFolder(url: selectedFolder)
            self.selectedFolder = nil
            loadFolders()
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    func refreshFolder(_ folder: URL) {
        withAnimation(.linear(duration: 1)) {
            refreshRotations[folder.path, default: 0] += 360
        }
        SkillManager.shared.scanSkills()
        loadFolders()
    }
}

private struct SuggestedSyncFolderRow: View {
    let source: SkillDirectories.SyncSkillSource
    let url: URL
    let onAdd: () -> Void

    private var displayPath: String {
        let home = SkillDirectories.homeDirectory.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.system(size: 13))
                    Text(displayPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                if let imageName = source.imageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "folder")
                }
            }
            .labelStyle(
                source.imageName != nil
                    ? SettingItemLabelStyle(iconSize: 20, containerSize: 28, iconCornerRadius: 8)
                    : SettingItemLabelStyle(
                        style: AnyShapeStyle(Color.blue.gradient),
                        containerSize: 28,
                        iconSize: 14,
                        iconCornerRadius: 8
                    )
            )

            Spacer()

            Button(String(localized: "Add")) {
                onAdd()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.Settings.syncedSkillsSuggestedAddButton(source.key))
        }
        .padding(.vertical, 4)
    }
}

struct AllSyncFolderSkillsView: View {
    let folder: URL

    @State private var refreshRotation: Double = 0

    private var syncSkills: [Skill] {
        SkillManager.shared.getSkillsFromSyncFolder(folder: folder)
    }

    var body: some View {
        Form {
            Section {
                List {
                    if syncSkills.isEmpty {
                        Text("No skills found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(syncSkills, id: \.name) { skill in
                            SkillRow(skill: skill)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(folder.path)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        withAnimation(.linear(duration: 1)) {
                            refreshRotation += 360
                        }
                        SkillManager.shared.scanSkills()
                    } label: {
                        HStack {
                            Text("Refresh")
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                .rotationEffect(.degrees(refreshRotation))
                        }
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(folder.lastPathComponent)
    }
}
