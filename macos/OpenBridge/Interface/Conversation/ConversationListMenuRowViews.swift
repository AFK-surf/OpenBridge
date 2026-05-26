//
//  ConversationListMenuRowViews.swift
//  OpenBridge
//
//  Created by OpenBridge on 2026/4/13.
//

import SwiftUI

struct SessionRowButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: SessionListInfo
    let isSelected: Bool
    let isKeyboardFocused: Bool
    let isStreaming: Bool
    let onSelect: (SessionListInfo) -> Void
    let onRename: ((SessionListInfo) -> Void)?
    let onDelete: ((SessionListInfo) -> Void)?
    let onShareLink: ((SessionListInfo) -> Void)?
    let style: ConversationListPresentationStyle

    @State private var isHovered = false

    init(
        session: SessionListInfo,
        isSelected: Bool,
        isKeyboardFocused: Bool = false,
        isStreaming: Bool,
        onSelect: @escaping (SessionListInfo) -> Void,
        onRename: ((SessionListInfo) -> Void)?,
        onDelete: ((SessionListInfo) -> Void)?,
        onShareLink: ((SessionListInfo) -> Void)?,
        style: ConversationListPresentationStyle
    ) {
        self.session = session
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
        self.isStreaming = isStreaming
        self.onSelect = onSelect
        self.onRename = onRename
        self.onDelete = onDelete
        self.onShareLink = onShareLink
        self.style = style
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            selectionArea
            trailingAccessory
                .frame(minWidth: style.trailingAccessoryWidth, alignment: .trailing)
                .frame(height: 16)
                .padding(.trailing, style.rowHorizontalPadding)
                .padding(.vertical, style.rowVerticalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: style.rowHeight)
        .background(alignment: .center) {
            rowBackground
                .frame(height: style.rowHoverBackgroundHeight)
        }
        .zIndex(isHovered || isKeyboardFocused || isSelected ? 1 : 0)
        .onHover { isHovered = $0 }
    }

    private var selectionArea: some View {
        Button {
            onSelect(session)
        } label: {
            HStack(spacing: 8) {
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }

                titleContent

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, style.rowHorizontalPadding)
            .padding(.vertical, style.rowVerticalPadding)
            .padding(.trailing, style.trailingAccessoryWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var titleContent: some View {
        if style.showsPreview, let previewText {
            VStack(alignment: .leading, spacing: style == .liquidPopup ? 0 : 2) {
                Text(session.title.isEmpty ? "Untitled" : session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(previewText)
                    .font(style == .liquidPopup ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(session.title.isEmpty ? "Untitled" : session.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var previewText: String? {
        let preview = session.lastMessagePreview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preview, !preview.isEmpty else { return nil }
        return preview
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: style.rowCornerRadius, style: .continuous)
            .fill(
                ConversationListRowOverlayStyle.fillColor(
                    isHovered: isHovered || isKeyboardFocused,
                    isSelected: isSelected,
                    presentationStyle: style,
                    colorScheme: colorScheme
                )
            )
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isHovered {
            HStack(spacing: 4) {
                if let onShareLink {
                    Button { onShareLink(session) } label: {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Copy link"))
                }
                if let onRename {
                    Button { onRename(session) } label: {
                        Image(systemName: "pencil.and.scribble")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let onDelete {
                    Button { onDelete(session) } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if isSelected {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Menu Button") {
    @Previewable @State var currentConversationId: String?
    @Previewable @State var editorViewModel = ChatEditorViewModel()

    ConversationHistoryMenuButton(
        searchModel: ChatConversationSearchModel(
            messagesBridge: MessagesBridge(chatEditorViewModel: editorViewModel),
            requiresPresentation: false
        ),
        currentConversationId: currentConversationId,
        onSelect: { conversationId in
            print("Selected: \(conversationId)")
            currentConversationId = conversationId
        }, onNewChat: {
            print("Selected: nil")
            currentConversationId = nil
        }
    )
    .padding()
}

@available(macOS 26.0, *)
private struct PreviewConversationHistoryLiquidActionGroup: View {
    @State private var currentConversationId: String? = "preview-conversation"
    @State private var editorViewModel = ChatEditorViewModel()

    var body: some View {
        ConversationHistoryLiquidActionGroup(
            searchModel: ChatConversationSearchModel(
                messagesBridge: MessagesBridge(chatEditorViewModel: editorViewModel),
                requiresPresentation: false
            ),
            currentConversationId: currentConversationId,
            onSelect: { conversationId in
                print("Selected: \(conversationId)")
                currentConversationId = conversationId
            },
            onNewChat: {
                print("Selected: nil")
                currentConversationId = nil
            },
            onShareLink: nil,
            onAuxiliaryInteraction: nil,
            searchActivationToken: 0
        )
        .padding()
        .frame(width: 450, height: 600, alignment: .topTrailing)
        .background(.black.opacity(0.2))
        .clipShape(.rect(cornerRadius: 16))
    }
}

#Preview("Liquid Action Group") {
    if #available(macOS 26.0, *) {
        PreviewConversationHistoryLiquidActionGroup()
    }
}
