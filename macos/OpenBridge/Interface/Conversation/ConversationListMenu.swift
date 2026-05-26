//
//  ConversationListMenu.swift
//  OpenBridge
//
//  Created by OpenBridge on 2025/11/25.
//

import AppKit
import Foundation
import Observation
import SwiftUI

private let conversationHistoryLoadMoreFooterHeight: CGFloat = 28

private struct ConversationHistoryMenuSectionsCache {
    let revision: Int
    let sections: [ConversationListSection]
}

private struct ConversationHistoryMenuLiquidLayoutCache {
    let revision: Int
    let includesLoadMoreFooter: Bool
    let layout: ConversationListLiquidVirtualization.Layout
}

@MainActor
@Observable
private final class ConversationHistoryMenuModel {
    let controller: ConversationListViewController
    let liquidPopupScrollState = ConversationListScrollState()
    var isLoading = false
    @ObservationIgnored private var liquidPopupSectionsCache: ConversationHistoryMenuSectionsCache?
    @ObservationIgnored private var liquidPopupLayoutCache: ConversationHistoryMenuLiquidLayoutCache?

    init(controller: ConversationListViewController = .shared) {
        self.controller = controller
    }

    var streamingConversationIds: Set<String> {
        ChatViewModel.shared.streamingConversationIds
    }

    func prepareMenu() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        for _ in 0 ..< 100 {
            if controller.state != .loading, controller.state != .idle {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func prepareLiquidPopupSections(revision: Int) {
        _ = liquidPopupSections(revision: revision)
    }

    func prepareLiquidPopupLayout(revision: Int, includesLoadMoreFooter: Bool) {
        _ = liquidPopupLayout(revision: revision, includesLoadMoreFooter: includesLoadMoreFooter)
    }

    func liquidPopupSections(revision: Int) -> [ConversationListSection] {
        if let liquidPopupSectionsCache, liquidPopupSectionsCache.revision == revision {
            return liquidPopupSectionsCache.sections
        }

        let sections = ConversationListSectionBuilder.buildSections(from: controller.sessions)
        liquidPopupSectionsCache = ConversationHistoryMenuSectionsCache(
            revision: revision,
            sections: sections
        )
        return sections
    }

    func liquidPopupLayout(
        revision: Int,
        includesLoadMoreFooter: Bool
    ) -> ConversationListLiquidVirtualization.Layout {
        if let liquidPopupLayoutCache,
           liquidPopupLayoutCache.revision == revision,
           liquidPopupLayoutCache.includesLoadMoreFooter == includesLoadMoreFooter
        {
            return liquidPopupLayoutCache.layout
        }

        let layout = ConversationListLiquidVirtualization.buildLayout(
            sections: liquidPopupSections(revision: revision),
            style: .liquidPopup,
            includesLoadMoreFooter: includesLoadMoreFooter,
            loadMoreFooterHeight: conversationHistoryLoadMoreFooterHeight
        )
        liquidPopupLayoutCache = ConversationHistoryMenuLiquidLayoutCache(
            revision: revision,
            includesLoadMoreFooter: includesLoadMoreFooter,
            layout: layout
        )
        return layout
    }

    func renameConversation(_ session: SessionListInfo) {
        ConversationListActionController.shared.renameConversation(session, controller: controller)
    }

    func deleteConversation(
        _ session: SessionListInfo,
        currentConversationId: String?,
        onDeletedCurrentConversation: @escaping () -> Void
    ) {
        ConversationListActionController.shared.deleteConversation(
            session,
            currentConversationId: currentConversationId,
            controller: controller,
            onDeletedCurrentConversation: onDeletedCurrentConversation
        )
    }
}

@MainActor
@Observable
final class ConversationListScrollState {
    var verticalOffset: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var hasStoredOffset = false
}

// MARK: - History badge (background activity count)

@MainActor
private func historyActivityBadgeCount(
    streamingConversationIds: Set<String>,
    currentConversationId: String?,
    taskViewModel: TaskViewModel
) -> Int {
    let streaming = if let id = currentConversationId {
        streamingConversationIds.count(where: { $0 != id })
    } else {
        streamingConversationIds.count
    }
    let running = taskViewModel.liveInfo.type == .running ? taskViewModel.liveInfo.count : 0
    return streaming + running
}

private struct HistoryBadgeLabel: View {
    let count: Int
    var xOffset: CGFloat = 8
    var yOffset: CGFloat = -8

    private var displayText: String {
        if count > 99 {
            "99+"
        } else {
            "\(count)"
        }
    }

    /// Square frame keeps `Circle` truly circular (not elliptical when text is wide).
    private var badgeDiameter: CGFloat {
        switch displayText.count {
        case 1: 14
        case 2: 16
        default: 20
        }
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .frame(width: badgeDiameter, height: badgeDiameter)
            .background(Circle().fill(Color.accentColor))
            .fixedSize()
            .offset(x: xOffset, y: yOffset)
            .accessibilityLabel(Text(verbatim: "\(count) background \(count == 1 ? "activity" : "activities")"))
    }
}

// MARK: - Conversation History Menu Button

@MainActor
struct ConversationHistoryMenuButton: View {
    @State private var menuModel = ConversationHistoryMenuModel()
    @State private var taskViewModel = TaskViewModel.shared
    @State private var popupMonitor = ConversationHistoryPopupMonitor()
    @State private var isPopupPresented = false
    @State private var searchFocusToken = 0

    private let popupHorizontalOffset: CGFloat = 30
    private let popupVerticalOffset: CGFloat = 24

    let searchModel: ChatConversationSearchModel
    let currentConversationId: String?
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onShareLink: ((SessionListInfo) -> Void)?
    let onBeforePresentMenu: (() -> Void)?
    let searchActivationToken: Int

    init(
        searchModel: ChatConversationSearchModel,
        currentConversationId: String? = nil,
        onSelect: @escaping (String) -> Void,
        onNewChat: @escaping () -> Void,
        onShareLink: ((SessionListInfo) -> Void)? = nil,
        onBeforePresentMenu: (() -> Void)? = nil,
        searchActivationToken: Int = 0
    ) {
        self.searchModel = searchModel
        self.currentConversationId = currentConversationId
        self.onSelect = onSelect
        self.onNewChat = onNewChat
        self.onShareLink = onShareLink
        self.onBeforePresentMenu = onBeforePresentMenu
        self.searchActivationToken = searchActivationToken
    }

    private var historyBadgeCount: Int {
        historyActivityBadgeCount(
            streamingConversationIds: menuModel.streamingConversationIds,
            currentConversationId: currentConversationId,
            taskViewModel: taskViewModel
        )
    }

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                if isPopupPresented {
                    historyPopupContent
                        .offset(x: popupHorizontalOffset)
                        .offset(y: popupVerticalOffset)
                        .transition(.conversationHistoryMenuContent)
                }

                Button(action: handleTap) {
                    Group {
                        if menuModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "clock")
                        }
                    }
                    .frame(width: 16, height: 16)
                    .overlay(alignment: .topTrailing) {
                        if historyBadgeCount > 0 {
                            HistoryBadgeLabel(count: historyBadgeCount)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(menuModel.isLoading)
            }
        }
        .fixedSize()
        .background(MenuAnchorView { popupMonitor.popupView = $0 })
        .keyboardShortcut("h", modifiers: .command)
        .help("History (\u{2318}H)")
        .accessibilityIdentifier(AccessibilityID.Chat.historyButton)
        .frame(width: 16, height: 16, alignment: .topTrailing)
        .zIndex(isPopupPresented ? 10 : 0)
        .animation(.spring(duration: 0.28, bounce: 0.18), value: isPopupPresented)
        .onChange(of: isPopupPresented) { _, isPresented in
            if isPresented {
                popupMonitor.start(
                    isPresented: Binding(
                        get: { isPopupPresented },
                        set: { nextValue in
                            if !nextValue {
                                dismissPopup()
                            }
                        }
                    ),
                    animation: .spring(duration: 0.28, bounce: 0.18)
                )
            } else {
                popupMonitor.stop()
                searchModel.dismiss()
            }
        }
        .onChange(of: searchActivationToken) { _, token in
            guard token > 0 else { return }
            openPopup(focusSearch: true)
        }
        .onDisappear {
            popupMonitor.stop()
        }
    }

    private var historyPopupContent: some View {
        ConversationHistoryPopupContent(
            searchModel: searchModel,
            controller: menuModel.controller,
            currentConversationId: currentConversationId,
            streamingConversationIds: menuModel.streamingConversationIds,
            sections: nil,
            liquidLayout: nil,
            scrollState: menuModel.liquidPopupScrollState,
            style: .menu,
            searchFocusToken: searchFocusToken,
            onSelect: { session in
                dismissPopup()
                onSelect(session.id)
            },
            onRename: { session in
                dismissPopup()
                menuModel.renameConversation(session)
            },
            onDelete: { session in
                dismissPopup()
                menuModel.deleteConversation(
                    session,
                    currentConversationId: currentConversationId,
                    onDeletedCurrentConversation: onNewChat
                )
            },
            onShareLink: onShareLink.map { handler in
                { session in
                    dismissPopup()
                    handler(session)
                }
            },
            onDismiss: dismissPopup,
            onKeyDownHandlerChange: { popupMonitor.onKeyDown = $0 }
        )
        .background(MenuAnchorView { popupMonitor.popupView = $0 })
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }

    private func handleTap() {
        openPopup(focusSearch: false)
    }

    private func openPopup(focusSearch: Bool) {
        if focusSearch {
            searchFocusToken += 1
        }

        withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
            isPopupPresented = true
        }
    }

    private func dismissPopup() {
        searchModel.dismiss()
        withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
            isPopupPresented = false
        }
    }
}

@available(macOS 26.0, *)
private enum HeaderActionPopup: Equatable {
    case history
    case more
}

@available(macOS 26.0, *)
@MainActor
struct ConversationHistoryLiquidActionGroup: View {
    @State private var menuModel = ConversationHistoryMenuModel()
    @State private var taskViewModel = TaskViewModel.shared
    @State private var popupMonitor = ConversationHistoryPopupMonitor()
    @State private var presentedPopup: HeaderActionPopup?
    @State private var searchFocusToken = 0
    @State private var isHistoryHovered = false
    @State private var isNewChatHovered = false
    @State private var isMoreHovered = false

    let searchModel: ChatConversationSearchModel
    let currentConversationId: String?
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    var onShareLink: ((SessionListInfo) -> Void)?
    var onAuxiliaryInteraction: (() -> Void)?
    let searchActivationToken: Int

    private let morphAnimation: Animation = .spring(duration: 0.32, bounce: 0.22)
    private let iconSize: CGFloat = 18
    private let buttonWidth: CGFloat = 22
    private let buttonHeight: CGFloat = 32
    private let buttonSpacing: CGFloat = 2
    private let hoverCircleDiameter = ChatHeaderIconHoverStyle.compactHoverDiameter
    private let capsuleHorizontalPadding: CGFloat = 4
    private let menuCornerRadius: CGFloat = 22

    private var isPopupPresented: Bool {
        presentedPopup != nil
    }

    private var popupPresentedBinding: Binding<Bool> {
        Binding(
            get: { presentedPopup != nil },
            set: { isPresented in
                if !isPresented {
                    presentedPopup = nil
                }
            }
        )
    }

    private var capsuleWidth: CGFloat {
        buttonWidth * 3 + buttonSpacing * 2 + capsuleHorizontalPadding * 2
    }

    private var capsuleHeight: CGFloat {
        buttonHeight
    }

    private var capsuleCornerRadius: CGFloat {
        capsuleHeight / 2
    }

    private var includesLoadMoreFooter: Bool {
        menuModel.controller.hasMore || menuModel.controller.isLoadingMore
    }

    private var historyBadgeCount: Int {
        historyActivityBadgeCount(
            streamingConversationIds: menuModel.streamingConversationIds,
            currentConversationId: currentConversationId,
            taskViewModel: taskViewModel
        )
    }

    private var currentShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isPopupPresented ? menuCornerRadius : capsuleCornerRadius,
            style: .continuous
        )
    }

    private var historySectionsRevision: Int {
        var hasher = Hasher()
        hasher.combine(Locale.current.identifier)
        hasher.combine(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate)
        hasher.combine(menuModel.controller.sessionsRevision)

        return hasher.finalize()
    }

    private var historyPopupContent: some View {
        let sections = menuModel.liquidPopupSections(revision: historySectionsRevision)
        let layout = menuModel.liquidPopupLayout(
            revision: historySectionsRevision,
            includesLoadMoreFooter: includesLoadMoreFooter
        )

        return ConversationHistoryPopupContent(
            searchModel: searchModel,
            controller: menuModel.controller,
            currentConversationId: currentConversationId,
            streamingConversationIds: menuModel.streamingConversationIds,
            sections: sections,
            liquidLayout: layout,
            scrollState: menuModel.liquidPopupScrollState,
            style: .liquidPopup,
            searchFocusToken: searchFocusToken,
            onSelect: { session in
                dismissPopup()
                onSelect(session.id)
            },
            onRename: { session in
                dismissPopup()
                menuModel.renameConversation(session)
            },
            onDelete: { session in
                dismissPopup()
                menuModel.deleteConversation(
                    session,
                    currentConversationId: currentConversationId,
                    onDeletedCurrentConversation: onNewChat
                )
            },
            onShareLink: onShareLink.map { handler in
                { session in
                    dismissPopup()
                    handler(session)
                }
            },
            onDismiss: dismissPopup,
            onKeyDownHandlerChange: { popupMonitor.onKeyDown = $0 }
        )
    }

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                if presentedPopup == .history {
                    historyPopupContent
                        .transition(.conversationHistoryMenuContent)
                }

                if presentedPopup == .more {
                    HeaderMoreMenuContent(
                        onOpenSettings: {
                            dismissPopup()
                            Windows.shared.open(.settings)
                        },
                        onOpenSkillSettings: {
                            dismissPopup()
                            SettingsNavigation.shared.navigate(to: .mySkills)
                            Windows.shared.open(.settings)
                        },
                        onExploreMoreSkills: {
                            dismissPopup()
                            NSWorkspace.shared.open(Constant.skillsURL)
                        }
                    )
                    .background(MenuAnchorView { popupMonitor.popupView = $0 })
                    .transition(.conversationHistoryMenuContent)
                }

                capsuleButtons
                    .opacity(isPopupPresented ? 0 : 1)
                    .allowsHitTesting(!isPopupPresented)
            }
            .padding(.horizontal, capsuleHorizontalPadding)
            .clipShape(currentShape)
            .chatHeaderLiquidGlass(in: currentShape)
        }
        .fixedSize()
        .shadow(
            color: .black.opacity(isPopupPresented ? 0.18 : 0.08),
            radius: isPopupPresented ? 22 : 8,
            y: isPopupPresented ? 10 : 4
        )
        .background(MenuAnchorView { popupMonitor.popupView = $0 })
        .animation(morphAnimation, value: presentedPopup)
        .frame(width: capsuleWidth, height: capsuleHeight, alignment: .topTrailing)
        .zIndex(isPopupPresented ? 10 : 0)
        .onChange(of: presentedPopup) { previousPopup, popup in
            if previousPopup == .history, popup != .history {
                searchModel.dismiss()
            }

            if popup != nil {
                popupMonitor.start(isPresented: popupPresentedBinding, animation: morphAnimation)
            } else {
                popupMonitor.stop()
            }
        }
        .onAppear {
            menuModel.prepareLiquidPopupLayout(
                revision: historySectionsRevision,
                includesLoadMoreFooter: includesLoadMoreFooter
            )
        }
        .onChange(of: historySectionsRevision) { _, revision in
            menuModel.prepareLiquidPopupLayout(
                revision: revision,
                includesLoadMoreFooter: includesLoadMoreFooter
            )
        }
        .onChange(of: includesLoadMoreFooter) { _, includesFooter in
            menuModel.prepareLiquidPopupLayout(
                revision: historySectionsRevision,
                includesLoadMoreFooter: includesFooter
            )
        }
        .onChange(of: searchActivationToken) { _, token in
            guard token > 0 else { return }
            showHistoryMenu(focusSearch: true)
        }
        .onDisappear {
            popupMonitor.stop()
        }
    }

    // MARK: - Capsule Buttons

    private var capsuleButtons: some View {
        HStack(spacing: buttonSpacing) {
            Button(action: {
                onAuxiliaryInteraction?()
                onNewChat()
            }) {
                Image(systemName: "plus")
                    .frame(width: iconSize, height: iconSize)
                    .frame(width: buttonWidth, height: buttonHeight)
                    .contentShape(Circle())
                    .background { hoverBackground(isHovered: isNewChatHovered) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New Chat (⌘N)")
            .accessibilityLabel("New Chat")
            .accessibilityIdentifier(AccessibilityID.Chat.newChatButton)
            .onHover { isNewChatHovered = $0 }

            Button(action: openHistoryMenu) {
                historyIcon
                    .frame(width: buttonWidth, height: buttonHeight)
                    .contentShape(Circle())
                    .background { hoverBackground(isHovered: isHistoryHovered) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("h", modifiers: .command)
            .help("History (\u{2318}H)")
            .accessibilityIdentifier(AccessibilityID.Chat.historyButton)
            .onHover { isHistoryHovered = $0 }

            Button(action: openMoreMenu) {
                Image(systemName: "ellipsis")
                    .frame(width: iconSize, height: iconSize)
                    .frame(width: buttonWidth, height: buttonHeight)
                    .contentShape(Circle())
                    .background { hoverBackground(isHovered: isMoreHovered) }
            }
            .buttonStyle(.plain)
            .help(String(localized: "More…"))
            .accessibilityLabel(String(localized: "More…"))
            .accessibilityIdentifier(AccessibilityID.Chat.moreButton)
            .onHover { isMoreHovered = $0 }
        }
    }

    private func hoverBackground(isHovered: Bool) -> some View {
        ChatHeaderIconHoverBackground(
            isHovered: isHovered,
            diameter: hoverCircleDiameter
        )
    }

    private var historyIcon: some View {
        Image(systemName: "clock")
            .frame(width: iconSize, height: iconSize)
            .overlay(alignment: .topTrailing) {
                if historyBadgeCount > 0 {
                    HistoryBadgeLabel(count: historyBadgeCount, xOffset: 7, yOffset: -7)
                }
            }
    }

    // MARK: - Actions

    private func openHistoryMenu() {
        if presentedPopup == .history {
            dismissPopup()
        } else {
            showHistoryMenu(focusSearch: false)
        }
    }

    private func showHistoryMenu(focusSearch: Bool) {
        if focusSearch {
            searchFocusToken += 1
        }
        withAnimation(morphAnimation) {
            presentedPopup = .history
        }
    }

    private func openMoreMenu() {
        guard !isPopupPresented else { return }
        onAuxiliaryInteraction?()
        withAnimation(morphAnimation) {
            presentedPopup = .more
        }
    }

    private func dismissPopup() {
        searchModel.dismiss()
        withAnimation(morphAnimation) {
            presentedPopup = nil
        }
    }
}

@MainActor
private struct ConversationListScrollContainer<Content: View>: NSViewRepresentable {
    let scrollState: ConversationListScrollState
    @ViewBuilder let content: () -> Content

    func makeNSView(context _: Context) -> ConversationListScrollView<Content> {
        ConversationListScrollView(content: content(), scrollState: scrollState)
    }

    func updateNSView(_ nsView: ConversationListScrollView<Content>, context _: Context) {
        nsView.updateContent(content())
    }
}

@MainActor
private struct ConversationListNativeScrollViewConfigurator: NSViewRepresentable {
    let showsVerticalScroller: Bool

    func makeNSView(context _: Context) -> ScrollConfiguratorView {
        ScrollConfiguratorView(showsVerticalScroller: showsVerticalScroller)
    }

    func updateNSView(_ nsView: ScrollConfiguratorView, context _: Context) {
        nsView.showsVerticalScroller = showsVerticalScroller
        nsView.scheduleConfigurationUpdate()
    }
}

@MainActor
private final class ScrollConfiguratorView: NSView {
    var showsVerticalScroller: Bool

    init(showsVerticalScroller: Bool) {
        self.showsVerticalScroller = showsVerticalScroller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfigurationUpdate()
    }

    override func layout() {
        super.layout()
        scheduleConfigurationUpdate()
    }

    func scheduleConfigurationUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.configureAncestorScrollView()
        }
    }

    private func configureAncestorScrollView() {
        guard let scrollView = enclosingScrollView else { return }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.verticalScroller?.controlSize = .small
    }
}

@MainActor
private struct ConversationListScrollContent<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

@MainActor
private final class ConversationListScrollView<Content: View>: NSScrollView {
    private let containerView = FlippedConversationListScrollDocumentView()
    private let hostingView: NSHostingView<ConversationListScrollContent<Content>>
    private let scrollState: ConversationListScrollState
    private var hoverTrackingArea: NSTrackingArea?
    private var hideScrollerWorkItem: DispatchWorkItem?
    private var isPointerInside = false
    private var isScrollerVisible = false
    private var isRestoringScrollPosition = false
    private var needsScrollRestore = true

    init(content: Content, scrollState: ConversationListScrollState) {
        hostingView = NSHostingView(rootView: ConversationListScrollContent(content: content))
        self.scrollState = scrollState
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        scrollerStyle = .overlay
        scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 3)
        automaticallyAdjustsContentInsets = false
        contentInsets = .zero
        contentView.contentInsets = .zero
        contentView.postsBoundsChangedNotifications = true
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none

        containerView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)
        documentView = containerView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBoundsDidChangeNotification),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )

        updateScrollerVisibility(visible: false, animated: false)
        scheduleScrollRestore()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateContent(_ content: Content) {
        hostingView.rootView = ConversationListScrollContent(content: content)
        hostingView.layoutSubtreeIfNeeded()
        scheduleScrollRestore()
    }

    override func layout() {
        super.layout()
        updateVisibleHeight()
        restoreScrollPositionIfNeeded()
    }

    override func tile() {
        super.tile()
        applyScrollerAppearance(animated: false)
        updateVisibleHeight()
        restoreScrollPositionIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
        cancelPendingScrollerHide()
        updateScrollerVisibility(visible: true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        scheduleScrollerHide()
    }

    override func scrollWheel(with event: NSEvent) {
        revealScroller()
        super.scrollWheel(with: event)
    }

    private func revealScroller() {
        updateScrollerVisibility(visible: true, animated: true)
        guard !isPointerInside else { return }
        scheduleScrollerHide(after: 0.35)
    }

    private func scheduleScrollerHide(after delay: TimeInterval = 0.12) {
        cancelPendingScrollerHide()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInside else { return }
            updateScrollerVisibility(visible: false, animated: true)
        }
        hideScrollerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingScrollerHide() {
        hideScrollerWorkItem?.cancel()
        hideScrollerWorkItem = nil
    }

    private func updateScrollerVisibility(visible: Bool, animated: Bool) {
        isScrollerVisible = visible
        applyScrollerAppearance(animated: animated)
    }

    private func scheduleScrollRestore() {
        needsScrollRestore = true
        DispatchQueue.main.async { [weak self] in
            self?.restoreScrollPositionIfNeeded()
        }
    }

    private func updateVisibleHeight() {
        let height = max(CGFloat.zero, contentView.bounds.height)
        guard abs(scrollState.visibleHeight - height) > 0.5 else { return }
        scrollState.visibleHeight = height
    }

    private func restoreScrollPositionIfNeeded() {
        guard needsScrollRestore, let documentView else { return }

        let documentHeight = documentView.bounds.height
        let visibleHeight = contentView.bounds.height
        guard documentHeight > 0, visibleHeight > 0 else { return }

        needsScrollRestore = false

        let maxOffset = max(0, documentHeight - visibleHeight)
        let targetOffset = if scrollState.hasStoredOffset {
            min(max(scrollState.verticalOffset, CGFloat.zero), maxOffset)
        } else {
            CGFloat.zero
        }

        guard abs(contentView.bounds.minY - targetOffset) > 0.5 else { return }

        isRestoringScrollPosition = true
        contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
        reflectScrolledClipView(contentView)
        isRestoringScrollPosition = false
    }

    private func storeScrollPosition() {
        guard !isRestoringScrollPosition else { return }

        let offset = max(CGFloat.zero, contentView.bounds.minY)
        if !scrollState.hasStoredOffset || abs(scrollState.verticalOffset - offset) > 0.5 {
            scrollState.verticalOffset = offset
            scrollState.hasStoredOffset = true
        }
    }

    @objc
    private func handleBoundsDidChangeNotification() {
        storeScrollPosition()
        updateVisibleHeight()
    }

    private func applyScrollerAppearance(animated: Bool) {
        guard let verticalScroller else { return }

        let targetAlpha: CGFloat = isScrollerVisible ? 1 : 0
        verticalScroller.controlSize = .small

        guard animated else {
            verticalScroller.alphaValue = targetAlpha
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            verticalScroller.animator().alphaValue = targetAlpha
        }
    }
}

private final class FlippedConversationListScrollDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

enum ConversationListPresentationStyle: Equatable {
    case menu
    case liquidPopup

    var menuWidth: CGFloat {
        switch self {
        case .menu:
            260
        case .liquidPopup:
            320
        }
    }

    /// Header More popover width; derived from `menuWidth` so it stays slightly narrower than the chat history panel.
    var headerMoreMenuWidth: CGFloat {
        menuWidth * headerMoreMenuWidthRelativeToMenuWidth
    }

    private var headerMoreMenuWidthRelativeToMenuWidth: CGFloat {
        switch self {
        case .menu:
            1
        case .liquidPopup:
            0.9 * 0.9 * 0.9
        }
    }

    var maxHeight: CGFloat {
        switch self {
        case .menu:
            500
        case .liquidPopup:
            420
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .menu:
            4
        case .liquidPopup:
            8
        }
    }

    var sectionHeaderHeight: CGFloat {
        switch self {
        case .menu:
            24
        case .liquidPopup:
            26
        }
    }

    var dividerHeight: CGFloat {
        switch self {
        case .menu:
            9
        case .liquidPopup:
            12
        }
    }

    var showsSectionDivider: Bool {
        switch self {
        case .menu:
            true
        case .liquidPopup:
            false
        }
    }

    /// Session list scroll height budget (liquid rows: title + preview). Single-line rows use padding + intrinsic sizing like `SessionRowButton` without preview.
    var rowHeight: CGFloat {
        switch self {
        case .menu:
            30
        case .liquidPopup:
            36
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .menu:
            2
        case .liquidPopup:
            0
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .menu:
            0
        case .liquidPopup:
            12
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .menu:
            12
        case .liquidPopup:
            14
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .menu:
            6
        case .liquidPopup:
            3
        }
    }

    var rowCornerRadius: CGFloat {
        switch self {
        case .menu:
            8
        case .liquidPopup:
            14
        }
    }

    var rowHoverBackgroundHeight: CGFloat {
        rowHeight
    }

    var rowOuterHorizontalPadding: CGFloat {
        switch self {
        case .menu:
            4
        case .liquidPopup:
            6
        }
    }

    var trailingAccessoryWidth: CGFloat {
        switch self {
        case .menu:
            56
        case .liquidPopup:
            64
        }
    }

    var showsPreview: Bool {
        false
    }

    var sectionFont: Font {
        switch self {
        case .menu:
            .caption
        case .liquidPopup:
            .caption2.weight(.semibold)
        }
    }

    /// Reserved width for optional leading SF Symbol in header more menu rows (aligns rows with/without icons).
    var headerMoreMenuLeadingSymbolColumnWidth: CGFloat {
        switch self {
        case .menu:
            20
        case .liquidPopup:
            24
        }
    }
}

enum ConversationListRowOverlayStyle {
    static func fillColor(
        isHovered: Bool,
        isSelected: Bool = false,
        presentationStyle: ConversationListPresentationStyle,
        colorScheme: ColorScheme
    ) -> Color {
        let opacity = overlayOpacity(
            isHovered: isHovered,
            isSelected: isSelected,
            presentationStyle: presentationStyle,
            colorScheme: colorScheme
        )

        guard opacity > 0 else { return .clear }

        let baseColor: Color = switch colorScheme {
        case .dark:
            .white
        default:
            .black
        }

        return baseColor.opacity(opacity)
    }

    private static func overlayOpacity(
        isHovered: Bool,
        isSelected: Bool,
        presentationStyle: ConversationListPresentationStyle,
        colorScheme: ColorScheme
    ) -> Double {
        if isHovered {
            switch (presentationStyle, colorScheme) {
            case (.liquidPopup, .dark):
                0.10
            case (.liquidPopup, _):
                0.045
            case (.menu, .dark):
                0.10
            case (.menu, _):
                0.06
            }
        } else if isSelected {
            switch (presentationStyle, colorScheme) {
            case (.liquidPopup, .dark):
                0.08
            case (.liquidPopup, _):
                0.04
            case (.menu, _):
                0
            }
        } else {
            0
        }
    }
}

// MARK: - Menu Content View

@MainActor
struct ConversationListMenuContent: View {
    let controller: ConversationListViewController
    let currentConversationId: String?
    let streamingConversationIds: Set<String>
    let sections: [ConversationListSection]?
    let liquidLayout: ConversationListLiquidVirtualization.Layout?
    let onSelect: (SessionListInfo) -> Void
    let onRename: ((SessionListInfo) -> Void)?
    let onDelete: ((SessionListInfo) -> Void)?
    let onShareLink: ((SessionListInfo) -> Void)?
    let scrollState: ConversationListScrollState
    let style: ConversationListPresentationStyle
    var keyboardFocusedSessionID: String?
    var maxHeight: CGFloat?

    private var contentMaxHeight: CGFloat {
        maxHeight ?? style.maxHeight
    }

    var body: some View {
        listView
            .frame(width: style.menuWidth)
    }

    @ViewBuilder
    private var listView: some View {
        let sessions = controller.sessions

        if sessions.isEmpty {
            emptyState
        } else {
            let groups = sections ?? groupedSessions
            let contentHeight = liquidLayout?.contentHeight ?? (calculateContentHeight(groups) + loadMoreContentHeight)
            if style == .liquidPopup,
               let liquidLayout,
               contentHeight > contentMaxHeight
            {
                ConversationListScrollContainer(scrollState: scrollState) {
                    virtualizedListContent(liquidLayout)
                }
                .frame(height: min(contentHeight, contentMaxHeight))
            } else if contentHeight > contentMaxHeight || controller.hasMore || controller.isLoadingMore {
                if style == .liquidPopup {
                    ConversationListScrollContainer(scrollState: scrollState) {
                        VStack(alignment: .leading, spacing: 0) {
                            listContent(groups)
                            loadMoreFooter
                        }
                    }
                    .frame(height: min(contentHeight, contentMaxHeight))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            listContent(groups)
                            loadMoreFooter
                        }
                        .background(
                            ConversationListNativeScrollViewConfigurator(
                                showsVerticalScroller: false
                            )
                        )
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: min(contentHeight, contentMaxHeight))
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    listContent(groups)
                    loadMoreFooter
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch controller.state {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading conversations…")
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 88)
            .frame(maxWidth: .infinity)

        case .failed:
            VStack(spacing: 8) {
                Text(controller.errorMessage ?? String(localized: "Failed to load conversations"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(String(localized: "Retry")) {
                    controller.refresh(force: true, silent: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 88)
            .frame(maxWidth: .infinity)

        case .loaded:
            Text("No conversations")
                .foregroundStyle(style == .liquidPopup ? .primary : .secondary)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
        }
    }

    private func listContent(_ groups: [ConversationListSection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    if style.showsSectionDivider {
                        Divider().padding(.vertical, 4)
                    } else if style.sectionSpacing > 0 {
                        Color.clear.frame(height: style.sectionSpacing)
                    }
                }
                sectionView(section)
            }
        }
        .padding(.vertical, style.verticalPadding)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if controller.hasMore || controller.isLoadingMore {
            VStack(spacing: 0) {
                if controller.hasMore {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            controller.loadMoreIfNeeded()
                        }
                }

                if controller.isLoadingMore {
                    HStack {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var loadMoreContentHeight: CGFloat {
        (controller.hasMore || controller.isLoadingMore) ? conversationHistoryLoadMoreFooterHeight : 0
    }

    private func sectionView(_ section: ConversationListSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title.prefix(1).uppercased() + section.title.dropFirst())
                .font(style.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, style.rowHorizontalPadding + style.rowOuterHorizontalPadding)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: style.rowSpacing) {
                ForEach(section.items, id: \.id) { session in
                    sessionRow(session)
                        .padding(.horizontal, style.rowOuterHorizontalPadding)
                        .frame(height: style.rowHeight)
                }
            }
        }
    }

    private func calculateContentHeight(_ groups: [ConversationListSection]) -> CGFloat {
        let padding = style.verticalPadding * 2

        var height: CGFloat = padding
        for (index, section) in groups.enumerated() {
            if index > 0 {
                height += style.showsSectionDivider ? style.dividerHeight : style.sectionSpacing
            }
            height += style.sectionHeaderHeight
            height += CGFloat(section.items.count) * style.rowHeight
            height += CGFloat(max(section.items.count - 1, 0)) * style.rowSpacing
        }
        return height
    }

    private var groupedSessions: [ConversationListSection] {
        ConversationListSectionBuilder.buildSections(from: controller.sessions)
    }

    private func virtualizedListContent(
        _ layout: ConversationListLiquidVirtualization.Layout
    ) -> some View {
        let viewportHeight = max(scrollState.visibleHeight, min(layout.contentHeight, contentMaxHeight))
        let visibleRows = Array(layout.visibleRows(
            offset: scrollState.verticalOffset,
            visibleHeight: viewportHeight
        ))
        let topSpacerHeight = max(0, visibleRows.first?.minY ?? layout.contentHeight)
        let bottomSpacerHeight = max(0, layout.contentHeight - (visibleRows.last?.maxY ?? 0))

        return VStack(alignment: .leading, spacing: 0) {
            if topSpacerHeight > 0 {
                Color.clear
                    .frame(height: topSpacerHeight)
            }

            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                virtualizedRowView(row)

                if index < visibleRows.count - 1 {
                    let gapHeight = max(0, visibleRows[index + 1].minY - row.maxY)
                    if gapHeight > 0 {
                        Color.clear
                            .frame(height: gapHeight)
                    }
                }
            }

            if bottomSpacerHeight > 0 {
                Color.clear
                    .frame(height: bottomSpacerHeight)
            }
        }
    }

    @ViewBuilder
    private func virtualizedRowView(_ row: ConversationListLiquidVirtualization.Row) -> some View {
        switch row.kind {
        case .divider:
            Divider()
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .frame(height: row.height)

        case let .sectionHeader(title):
            Text(title.prefix(1).uppercased() + title.dropFirst())
                .font(style.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, style.rowHorizontalPadding + style.rowOuterHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: row.height)

        case let .session(session):
            sessionRow(session)
                .padding(.horizontal, style.rowOuterHorizontalPadding)
                .frame(height: row.height)

        case .loadMore:
            loadMoreFooter
                .frame(height: row.height)
        }
    }

    private func sessionRow(_ session: SessionListInfo) -> some View {
        SessionRowButton(
            session: session,
            isSelected: session.id == currentConversationId,
            isKeyboardFocused: session.id == keyboardFocusedSessionID,
            isStreaming: streamingConversationIds.contains(session.id),
            onSelect: onSelect,
            onRename: onRename,
            onDelete: onDelete,
            onShareLink: onShareLink,
            style: style
        )
    }
}
