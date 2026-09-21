import SwiftUI

struct RootPaletteView: View {
    @Environment(AppCore.self) private var core
    @Environment(PaletteState.self) private var vm
    @Environment(AppIndex.self) private var appIndex
    @Environment(ClipboardStore.self) private var store
    @Environment(FavoritesStore.self) private var favorites
    @Environment(VisibilityStore.self) private var visibility
    @Environment(CalculatorHistoryStore.self) private var calcHistory
    /// Observed so the card re-evaluates when a snapshot lands or consent changes.
    @Environment(CurrencyRateStore.self) private var currencyRates
    @Environment(FileSearchSession.self) private var fileSearch
    /// Observed so the join card's countdown redraws on the minute boundary.
    @Environment(QuicklinkStore.self) private var quicklinks
    @Environment(CustomCommandArgumentSession.self) private var customCommandArguments
    @Environment(ExtensionManager.self) private var extensions
    @Environment(AppSettings.self) private var settings
    @Environment(\.metrics) private var metrics
    @FocusState private var searchFocused: Bool
    /// Kept apart from the search field's own focus. See docs/features/palette.md.
    @FocusState private var argumentFocused: String?
    /// Which in-window menu is open; at most one, so the state cannot disagree with itself.
    @State private var openMenu: OpenMenu?
    /// Sampled once by `openActions`, so the running-only rows can't appear while the menu is up.
    @State private var selectionIsRunning = false
    /// Highlighted row of whichever menu is open; each open path sets where it starts.
    @State private var menuSelection = 0
    /// The argument field whose choices are up, so `menuContent` can rebuild the same menu.
    @State private var argumentOptionsField: String?
    @State private var menuPanel = MenuPanelController()
    /// The palette's own window, reported by `WindowReader`; the menu hangs off its frame.
    @State private var hostWindow: NSWindow?
    /// The pending scroll request; modes are exclusive, so one piece of state serves all.
    @State private var scroll = ScrollIntent(kind: .top)

    /// Compact vs. full; the source of truth is on `AppCore`, so the two can't disagree.
    private var isCollapsed: Bool { core.paletteCoordinator.paletteIsCollapsed }

    /// The current mode's screen: its rows are the visible order the flat selection indexes.
    private var screen: any PaletteScreen {
        switch vm.mode {
        case .launcher:
            return LauncherScreen(
                appIndex: appIndex, favorites: favorites, visibility: visibility,
                currencyRates: currencyRates, core: core, vm: vm, running: selectionIsRunning,
                openActions: openActions, openArgumentOptions: openArgumentOptions,
                scrollToFollow: { scroll = ScrollIntent(kind: .follow) })
        case .customCommandArguments:
            return CustomCommandArgumentsScreen(
                session: customCommandArguments, core: core, vm: vm)
        case .quicklinks:
            return QuicklinkListScreen(
                store: quicklinks, core: core, vm: vm, openActions: openActions,
                openArgumentOptions: openArgumentOptions)
        case .fileSearch:
            return FileSearchScreen(
                session: fileSearch, core: core, vm: vm, openActions: openActions)
        case .clipboard:
            return ClipboardScreen(
                store: store, core: core, vm: vm, openActions: openActions,
                scrollToFollow: { scroll = ScrollIntent(kind: .follow) })
        case .calculatorHistory:
            return CalculatorHistoryScreen(
                history: calcHistory, currencyRates: currencyRates, core: core, vm: vm,
                openActions: openActions)
        case .extensionCommand:
            return ExtensionCommandScreen(
                screen: extensionScreen, extensions: extensions, vm: vm, openActions: openActions)
        }
    }

    /// The running command's rendered screen, flattened. `.empty` until the first commit lands.
    private var extensionScreen: ExtensionScreen {
        guard vm.mode == .extensionCommand, case .rendered(let tree) = extensions.state else {
            return .empty
        }
        return ExtensionScreen(tree: tree, query: vm.query)
    }

    private func handleFormReturn(_ press: KeyPress) -> KeyPress.Result {
        guard !vm.isEditingField, !vm.isComposing else { return .ignored }
        let modifiers = press.modifiers.intersection([.command, .control, .option, .shift])
        guard modifiers == .command else { return .ignored }
        activateSelection()
        return .handled
    }

    private var isExtensionForm: Bool {
        vm.mode == .extensionCommand && extensionScreen.kind == .form
    }

    /// Selection clamped into the results: one source for highlight, preview and activation.
    private func selection(count: Int) -> Int {
        count == 0 ? 0 : min(max(vm.selection, 0), count - 1)
    }

    /// Takes a resolved screen — reaching `rows` costs a list build, so callers resolve it once.
    private func selection(in screen: any PaletteScreen) -> Int {
        selection(count: screen.rows.count)
    }

    private var menuOpen: Bool { openMenu != nil }

    // MARK: - Popover menu content

    /// The clipboard type filter's rows; activating one is the only way the filter changes.
    private var clipboardFilterContent: PopoverMenuContent {
        PopoverMenuContent(
            items: ClipboardFilter.allCases.enumerated().map { index, filter in
                PopoverMenuItem(
                    title: filter.title, systemImage: filter.systemImage,
                    startsSection: index == 1
                ) {
                    vm.clipboardFilter = filter
                }
            })
    }

    /// The file search type filter's rows, built the way the clipboard's are.
    private var fileSearchFilterContent: PopoverMenuContent {
        PopoverMenuContent(
            items: FileSearchFilter.allCases.map { filter in
                PopoverMenuItem(title: filter.title, systemImage: filter.systemImage) {
                    vm.fileSearchFilter = filter
                }
            })
    }

    /// The bottom-left app menu content (About / Settings).
    private var appMenuContent: PopoverMenuContent {
        PopoverMenuContent(items: [
            PopoverMenuItem(title: "About Tinycast", systemImage: "info.circle") {
                core.settingsCoordinator.showAbout()
            },
            PopoverMenuItem(title: "Settings", systemImage: "gearshape", shortcut: "⌘,") {
                core.settingsCoordinator.showSettings()
            }
        ])
    }

    /// The one source every menu path addresses rows through, so none can disagree.
    private var menuContent: PaletteMenuContent? {
        switch openMenu {
        case .actions:
            let screen = screen
            let sel = selection(in: screen)
            // An extension draws its own panel, so it narrows its own rows from the same filter.
            if let extensionScreen = screen as? ExtensionCommandScreen {
                return extensionScreen.menuContent(
                    at: sel, menuSelection: $menuSelection, onActivate: activateMenuItem)
            }
            guard let content = screen.actions(at: sel) else { return nil }
            return PaletteMenuContent(
                popover: content.filtered(by: vm.menuFilter), selection: $menuSelection,
                onActivate: activateMenuItem)
        case .app:
            return PaletteMenuContent(
                popover: appMenuContent, selection: $menuSelection, onActivate: activateMenuItem)
        case .clipboardFilter:
            return headerMenu(clipboardFilterContent, width: metrics.size.clipboardFilterMenuWidth)
        case .fileSearchFilter:
            return headerMenu(fileSearchFilterContent, width: metrics.size.fileSearchFilterMenuWidth)
        case .argumentOptions:
            guard let field = argumentOptionsField,
                let popover = headerAccessory?.optionsMenu(field)
            else { return nil }
            return headerMenu(popover, width: metrics.size.menuWidth)
        case .extensionAccessory:
            return extensionCommandScreen?.searchAccessoryMenu(
                menuSelection: $menuSelection, onActivate: activateMenuItem)
        case nil: return nil
        }
    }

    var body: some View {
        // Resolve the screen once per render, so the flat index can't drift from the rows.
        let screen = screen
        let count = screen.rows.count
        let sel = selection(count: count)
        // The argument forms and an extension's Form have no rows to count, but ↵ still acts.
        let showActionGroup =
            (count > 0 || vm.mode.isArgumentForm || screen.actsWithoutRows)
            && screen.hasPrimaryAction(at: sel)

        // One header position, so focus survives the swap. See docs/features/palette.md.
        return keyHandlers(
            stateObservers(
                Group {
                    if isCollapsed {
                        Color.clear
                    } else {
                        screen.body(selection: sel, scroll: scroll)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isCollapsed {
                        bottomBar(
                            pillLabel: screen.primaryActionTitle, showActionGroup: showActionGroup,
                            formPrimaryShortcut: isExtensionForm,
                            showActions: screen.hasActions(at: sel))
                        }
                }
                // The panel has no title bar, so this thin top margin is the only place left to grab it.
                .overlay(alignment: .top) { topDragStrip }
                .modifier(
                    ExtensionToastOverlay(extensions: extensions, showing: vm.mode == .extensionCommand)
                )
                // Never conditionally mounted: unmounting strands SwiftUI's hover target and eats clicks.
                .overlay {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        // Not a tap: a drifting press must still dismiss, the way a native menu's does.
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in closeMenus() })
                        .onRightClick { closeMenus() }
                        .allowsHitTesting(menuOpen)
                }
                // The menu lives in its own window; this only reports the one to hang it from.
                .background(
                    WindowReader {
                        hostWindow = $0
                        installHeaderArrowHandler(in: $0)
                    }
                )
                // The window's frame is the size source, so the glass and clip stay matched.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(PaletteBackground(window: hostWindow))
                .clipShape(RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous))),
            selection: sel)
    }

    /// Split from `body` for the same reason `keyHandlers` is: one chain cannot carry them all.
    private func applyDefaultLauncherSelection() {
        if vm.mode == .launcher && vm.query.isEmpty, let launcher = screen as? LauncherScreen {
            vm.selection = launcher.defaultSelection
        }
    }

    /// Index 0 is the pinned block, so an empty history opens on the newest clip instead.
    @discardableResult
    private func applyClipboardOpeningSelection() -> Bool {
        guard vm.mode == .clipboard, vm.query.isEmpty, let clipboard = screen as? ClipboardScreen
        else { return false }
        vm.selection = clipboard.defaultSelection
        return true
    }

    private var scrollForCurrentSelection: ScrollIntent.Kind {
        vm.mode == .clipboard && vm.query.isEmpty && vm.selection > 0 ? .follow : .top
    }

    private func handleFocusToken() {
        searchFocused = !screen.hidesSearchField
        applyDefaultLauncherSelection()
    }

    private func handleQueryChange() {
        if vm.collapseQueryLineBreaks() { return }
        if vm.mode == .launcher && vm.query.isEmpty, let launcher = screen as? LauncherScreen {
            vm.selection = launcher.defaultSelection
        } else if !applyClipboardOpeningSelection() {
            vm.selection = 0
        }
        scroll = ScrollIntent(kind: scrollForCurrentSelection)
        if vm.mode == .fileSearch { fileSearch.search(vm.query, filter: vm.fileSearchFilter) }
        if vm.mode == .extensionCommand, let handler = extensionScreen.searchTextHandler {
            extensions.dispatch(handler: handler, arguments: [vm.query])
        }
    }

    private func handleModeChange() {
        vm.clipboardFilter = .all
        vm.fileSearchFilter = .all
        vm.fileSearchQuickLook = false
        if vm.mode == .launcher && vm.query.isEmpty, let launcher = screen as? LauncherScreen {
            vm.selection = launcher.defaultSelection
        } else if !applyClipboardOpeningSelection() {
            vm.selection = 0
        }
        if menuOpen { closeMenus() }
        scroll = ScrollIntent(kind: scrollForCurrentSelection)
        searchFocused = !screen.hidesSearchField
        if vm.mode == .fileSearch {
            fileSearch.search(vm.query, filter: vm.fileSearchFilter)
        } else {
            fileSearch.cancel()
        }
        if vm.mode != .extensionCommand, extensions.running != nil, !extensions.isAuthorizing {
            Task { await extensions.stop() }
        }
        if vm.mode != .customCommandArguments {
            core.customCommandCoordinator.cancelCustomCommandArguments()
        }
    }

    private func handleResetToken() {
        if menuOpen { closeMenus() }
        applyDefaultLauncherSelection()
        applyClipboardOpeningSelection()
        scroll = ScrollIntent(kind: scrollForCurrentSelection)
    }

    private func handleAppear() {
        searchFocused = !screen.hidesSearchField
        applyDefaultLauncherSelection()
    }

    /// Split from `body` for the same reason `keyHandlers` is: one chain cannot carry them all.
    @ViewBuilder
    private func stateObservers(_ content: some View) -> some View {
        lifecycleObservers(
            domainObservers(content)
        )
    }

    @ViewBuilder
    private func domainObservers(_ content: some View) -> some View {
        content
            // Every show bumps focusToken so the search field refocuses.
            .onChange(of: vm.focusToken) { handleFocusToken() }
            // A preserved screen re-summons as it was left, so a menu must end with the palette.
            .onChange(of: vm.isVisible) {
                if !vm.isVisible, menuOpen { closeMenus() }
            }
            .onChange(of: vm.query) { handleQueryChange() }
            // Anything typed while the command was still starting predates its handler.
            .onChange(of: extensionScreen.searchTextHandler) { previous, handler in
                guard previous == nil, let handler, !vm.query.isEmpty else { return }
                extensions.dispatch(handler: handler, arguments: [vm.query])
            }
            .modifier(ExtensionSelectionForwarder(screen: extensionScreen, selection: vm.selection))
            // A narrower list means the old index points at a different row, or at none.
            .onChange(of: vm.clipboardFilter) {
                guard vm.mode == .clipboard else { return }
                if !applyClipboardOpeningSelection() { vm.selection = 0 }
                scroll = ScrollIntent(kind: scrollForCurrentSelection)
            }
            // The filter is part of the query, so narrowing re-runs it rather than thinning rows.
            .onChange(of: vm.fileSearchFilter) {
                vm.selection = 0
                scroll = ScrollIntent(kind: .top)
                fileSearch.search(vm.query, filter: vm.fileSearchFilter)
            }
            .onChange(of: vm.mode) { handleModeChange() }
            // `prepare` may change nothing, so this intent still snaps the scroll to the origin.
            .onChange(of: vm.resetToken) { handleResetToken() }
            // ⌘. arrives as a token rather than a key press. See `PaletteState.pinChordToken`.
            .onChange(of: vm.pinChordToken) { performShortcut(.pin) }
            // ⌘1…⌘0 arrives as a slot index from AppKit keyCode matching.
            .onChange(of: vm.favoriteSlotToken) {
                if let index = vm.favoriteSlotIndex { performShortcut(.favoriteSlot(index)) }
            }
    }

    @ViewBuilder
    private func lifecycleObservers(_ content: some View) -> some View {
        content
            // One optional makes "exactly one menu" structural; this only mirrors it for the panel.
            .onChange(of: openMenu) {
                vm.menuOpen = menuOpen
                vm.menuFilterEnabled = openMenu == .actions
                if !menuOpen { vm.menuFilter = "" }
                guard menuOpen else { return }
                syncMenuPanel(presenting: true)
            }
            // A narrowed menu restarts on its first row, like a narrowed list does.
            .onChange(of: vm.menuFilter) {
                menuSelection = 0
                syncMenuPanel(presenting: false)
            }
            // The hosted tree is its own hierarchy, so the highlight has to be pushed into it.
            .onChange(of: menuSelection) { syncMenuPanel(presenting: false) }
            .onDisappear {
                menuPanel.hide()
                (hostWindow as? PalettePanel)?.onHeaderFieldBoundaryArrow = nil
            }
            .onAppear { handleAppear() }
            .modifier(SearchFieldHiding(hidden: hidesSearchField, apply: applySearchFieldHiding))
            // Several paths flip `paletteIsCollapsed`, so resize the window to match.
            .onChange(of: core.paletteCoordinator.paletteIsCollapsed) {
                core.paletteCoordinator.syncPaletteSize()
            }
    }


    @ViewBuilder
    private func keyHandlers(_ content: some View, selection sel: Int) -> some View {
        content
            // Repeat included: holding the key keeps stepping, as the bare-key form does.
            .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { press in
                if let reorder = movePinnedOrFavorite(1, modifiers: press.modifiers) { return reorder }
                // A control's own list owns every navigation key while it is up.
                if vm.isControlListOpen { return .ignored }
                if isCollapsed {
                    // The compact bar shows no selection, so Down reveals the list's first row.
                    vm.selection = 0
                    core.paletteCoordinator.expandFromCompact()
                    return .handled
                }
                if menuOpen {
                    moveMenu(1)
                    return .handled
                }
                return moveVertically(1)
            }
            .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { press in
                if let reorder = movePinnedOrFavorite(-1, modifiers: press.modifiers) { return reorder }
                if vm.isControlListOpen { return .ignored }
                if isCollapsed { return .ignored }
                if menuOpen {
                    moveMenu(-1)
                    return .handled
                }
                return moveVertically(-1)
            }
            // Horizontal arrows step the grid; elsewhere they stay with the caret.
            .onKeyPress(.leftArrow) {
                if vm.isControlListOpen { return .ignored }
                if menuOpen { return .handled }
                return moveHorizontally(-1) ? .handled : .ignored
            }
            .onKeyPress(.rightArrow) {
                if vm.isControlListOpen { return .ignored }
                if menuOpen { return .handled }
                return moveHorizontally(1) ? .handled : .ignored
            }
            // Plain ↵ runs an open menu's row or non-form selection; ⌘↵ submits forms.
            .onKeyPress(keys: [.return], phases: .down) { press in
                let command = press.modifiers.contains(.command)
                let option = press.modifiers.contains(.option)
                if menuOpen, !command, !option {
                    activateMenuItem(menuSelection)
                    return .handled
                }
                if isExtensionForm { return handleFormReturn(press) }
                let screen = screen
                guard command || option else {
                    guard !vm.isComposing else { return .ignored }
                    // The fallback for a hidden-field screen with no control focused to answer.
                    let answersWithoutFocus = screen.hidesSearchField && screen.rows.isEmpty
                    guard searchFocused || answersWithoutFocus else { return .ignored }
                    activateSelection()
                    return .handled
                }
                let selection = selection(in: screen)
                if command { return screen.secondary(at: selection) ? .handled : .ignored }
                return screen.pasteKeepingWindowOpen(at: selection) ? .handled : .ignored
            }
            .onKeyPress(.escape) {
                if menuPanel.isClosing { return .handled }
                // An open list closes itself first, exactly as the ⌘K menu does.
                if vm.isControlListOpen { return .ignored }
                // A filtered ⌘K menu clears its filter before it closes, like a narrowing query.
                if openMenu == .actions, !vm.menuFilter.isEmpty {
                    vm.menuFilter = ""
                    return .handled
                }
                switch PaletteEscapeAction.resolve(
                    menuOpen: menuOpen, argumentFocused: argumentFocused != nil, query: vm.query,
                    mode: vm.mode, canGoBack: vm.canGoBack,
                    behavior: settings.escapeKeyBehavior)
                {
                case .closeMenu:
                    closeMenus()
                case .leaveArgumentField:
                    returnFocusToSearchField()
                case .clearQuery:
                    vm.query = ""
                case .exitExtensionScreen:
                    core.extensionCoordinator.exitExtensionScreen()
                case .goBack:
                    goBack()
                case .goToRoot:
                    core.palette.prepare(mode: .launcher)
                case .hidePalette:
                    core.paletteCoordinator.hidePalette()
                    // This behavior promises a root search on reopen, whatever the delay says.
                    if settings.escapeKeyBehavior == .closeAndPopToRoot {
                        core.paletteCoordinator.popToRootNow()
                    }
                }
                return .handled
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                // ⇥ inside an open list belongs to the list, not to the form's field order.
                if vm.isControlListOpen { return .handled }
                if !menuOpen { advanceTabFocus(backwards: press.modifiers.contains(.shift)) }
                return .handled
            }
            .modifier(
                ExtensionShortcutKeys(
                    screen: menuOpen ? nil : screen as? ExtensionCommandScreen, selection: sel)
            )
            // ⌘K toggles the actions panel for the current selection.
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command),
                    ASCIIKeyboardLayout.matches(press.key, character: "k")
                else { return .ignored }
                // A control's open list owns the screen, so a second panel may never open over it.
                guard !vm.isControlListOpen else { return .handled }
                // The Actions menu has no anchor in the compact bar, so swallow ⌘K there.
                guard !isCollapsed else { return .handled }
                let screen = screen
                guard !screen.rows.isEmpty || screen.actsWithoutRows else { return .handled }
                // An error calc card is the selection but has no actions — don't open an empty panel.
                guard screen.hasPrimaryAction(at: selection(in: screen)) else { return .handled }
                // Same for a menu the footer doesn't offer: ⌘K opens exactly what the bar advertises.
                guard screen.hasActions(at: selection(in: screen)) else { return .handled }
                toggleActions()
                return .handled
            }
            // The screen answers row chords; a bare backspace is intercepted in `sendEvent`.
            .onKeyPress(phases: .down) { press in
                let isDeleteKey = press.key == .delete || press.key == .deleteForward
                if isDeleteKey, menuOpen { return .handled }
                guard
                    let shortcut = PaletteShortcut.resolve(
                        command: press.modifiers.contains(.command),
                        shift: press.modifiers.contains(.shift),
                        option: press.modifiers.contains(.option),
                        control: press.modifiers.contains(.control),
                        isDeleteKey: isDeleteKey,
                        matches: { ASCIIKeyboardLayout.matches(press.key, character: $0) })
                else { return .ignored }
                guard !shortcut.requiresExpanded || !isCollapsed else { return .ignored }
                if shortcut == .commandDelete, vm.menuFilterEnabled, !vm.menuFilter.isEmpty {
                    vm.menuFilter = ""
                    return .handled
                }
                let screen = screen
                guard screen.perform(shortcut, at: selection(in: screen)) else { return .ignored }
                if shortcut.closesMenu, menuOpen { closeMenus() }
                return .handled
            }
            // Never gated on the rows: an over-narrow filter empties them, and this is the way out.
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command),
                    ASCIIKeyboardLayout.matches(press.key, character: "p")
                else { return .ignored }
                switch PaletteFilterAction.resolve(
                    collapsed: isCollapsed, mode: vm.mode,
                    commandHasAccessory: extensionCommandScreen?.searchAccessory != nil)
                {
                case .extensionAccessory: toggleExtensionSearchAccessory()
                case .clipboardFilter: toggleClipboardFilter()
                case .fileSearchFilter: toggleFileSearchFilter()
                case .ignored: return .ignored
                }
                return .handled
            }
    }

    /// A thin strip along the top edge for grabbing the window; the Appearance setting gates it.
    private var topDragStrip: some View {
        Color.clear
            .frame(height: metrics.size.headerPadding)
            .windowDraggable(settings.paletteDraggable, onBegan: beginDrag, onEnded: endDrag)
    }

    /// A header sliver nothing occupies — safe to drag; the search field handles its own.
    private func headerGutter(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .windowDraggable(settings.paletteDraggable, onBegan: beginDrag, onEnded: endDrag)
    }

    private func beginDrag() { core.paletteCoordinator.beginPaletteDrag() }
    private func endDrag() { core.paletteCoordinator.endPaletteDrag() }

    /// A command can push a Form over its own list, which takes the keyboard mid-session.
    private func applySearchFieldHiding(_ hidden: Bool) {
        searchFocused = !hidden
        if hidden { vm.query = "" }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            // Matches the list rows and section headers' own indent below.
            headerGutter(width: metrics.spacing.md * 2)
            // Sub-screens leave through a chevron; the launcher gives the slot to the field.
            if vm.mode != .launcher {
                HeaderBackButton(help: backHelp, action: goBack)
                headerGutter(width: metrics.spacing.md)
            }
            // One structural position: a field inside a branch loses first responder when it flips.
            headerField
            if let accessory = headerAccessory {
                accessory.view
                Spacer(minLength: 0)
            }
            // Keyed off the mode, which says which screen is up; the field just flexes narrower.
            if !isCollapsed, vm.mode == .clipboard {
                headerGutter(width: metrics.spacing.md)
                ClipboardFilterButton(
                    filter: vm.clipboardFilter, isOpen: openMenu == .clipboardFilter,
                    action: toggleClipboardFilter)
            }
            if !isCollapsed, vm.mode == .fileSearch {
                headerGutter(width: metrics.spacing.md)
                HeaderMenuButton(
                    title: vm.fileSearchFilter.title, systemImage: vm.fileSearchFilter.systemImage,
                    isOpen: openMenu == .fileSearchFilter, help: "Filter by type  ⌘P",
                    action: toggleFileSearchFilter)
            }
            // Compact pins favorites beside the field; expanded shows them as rows.
            if isCollapsed, settings.showFavoritesInCompactMode,
                let launcher = screen as? LauncherScreen
            {
                let favorites = launcher.compactFavorites
                if !favorites.isEmpty {
                    headerGutter(width: metrics.spacing.md)
                    CompactFavoritesRow(
                        favorites: favorites,
                        showsOverflow: launcher.hasUnshownFavorites,
                        onLaunch: { core.launcherCoordinator.launch($0) },
                        onOverflow: { core.paletteCoordinator.expandFromCompact() }
                    )
                }
            }
            if !isCollapsed, let command = extensionCommandScreen,
                let accessory = command.searchAccessory
            {
                headerGutter(width: metrics.spacing.md)
                command.searchAccessoryButton(
                    accessory, isOpen: openMenu == .extensionAccessory,
                    action: toggleExtensionSearchAccessory)
            }
            headerGutter(width: metrics.spacing.md * 2)
        }
        // Identical metrics in both states, so typing can't move the search bar.
        // Same scrim as the panel behind it, so rows hide beneath with no visible band.
        .frame(height: metrics.size.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.panelScrim(transparency: settings.paletteTransparency))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
        }
        // Set after the show, so the field it names is focused rather than the search field.
        .onChange(of: vm.pendingArgumentEntryID) { focusPendingArgument() }
    }

    /// Mode-gated ahead of the cast, which would otherwise cost every other mode a list build.
    private var extensionCommandScreen: ExtensionCommandScreen? {
        guard vm.mode == .extensionCommand else { return nil }
        return screen as? ExtensionCommandScreen
    }

    /// Whichever screen offers one; the compact bar has no room for it.
    private var headerAccessory: PaletteHeaderAccessory? {
        guard !isCollapsed else { return nil }
        let screen = screen
        return screen.headerAccessory(at: selection(in: screen), focus: $argumentFocused)
    }

    /// True when the screen took the keyboard over, which leaves the header empty beside the chevron.
    private var hidesSearchField: Bool { !isCollapsed && screen.hidesSearchField }

    /// The field, kept mounted and hidden rather than swapped: a branch would tear its editor down.
    private var headerField: some View {
        searchField
            .frame(width: searchFieldWidth)
            .opacity(hidesSearchField ? 0 : 1)
            .allowsHitTesting(!hidesSearchField)
            .accessibilityHidden(hidesSearchField)
            // The frame it publishes is where the panel puts an I-beam; hidden, it owns nowhere.
            .onChange(of: hidesSearchField) { _, hidden in
                if hidden { vm.searchFieldFrame = .zero }
            }
    }

    /// Fixed only where something shares the row: the accessory strip, or a screen's own title.
    private var searchFieldWidth: CGFloat? {
        if hidesSearchField { return nil }
        return headerAccessory.map(searchFieldWidth)
    }

    /// The field's own text, floored for the caret and capped so the strip stays on screen.
    /// Empty, that is the prompt where one is drawn — which is what seats the strip right after it.
    private func searchFieldWidth(for accessory: PaletteHeaderAccessory) -> CGFloat {
        let font = metrics.typography.searchFieldNSFont
        let text = vm.query.isEmpty ? searchPrompt : vm.query
        let typed = (text as NSString).size(withAttributes: [.font: font]).width
        let chrome = metrics.size.headerIconSlot + metrics.spacing.md * 4
        // +3pt so the caret sits after the last glyph rather than on top of it.
        return min(
            max(typed + metrics.scaled(3), metrics.scaled(18)),
            max(metrics.size.panelWidth - accessory.width - chrome, metrics.scaled(60)))
    }

    /// In the argument form the field is that argument's input, so it names the argument.
    private var searchPrompt: String {
        // Squeezed to the caret, the field has no room for a prompt; beside one it keeps it.
        if headerAccessory?.placement == .afterQuery { return "" }
        if vm.mode == .customCommandArguments {
            return customCommandArguments.prompt ?? vm.mode.placeholder
        }
        // Inside a running command the search bar belongs to the extension.
        if vm.mode == .extensionCommand, let placeholder = extensionScreen.searchPlaceholder {
            return placeholder
        }
        return vm.mode.placeholder
    }

    /// The one search field — empty it's a drag handle, and any text hands every press to editing.
    private var searchField: some View {
        @Bindable var vm = vm
        return TextField("", text: $vm.query)
            .textFieldStyle(.plain)
            .font(metrics.typography.searchField)
            .tint(Theme.Colors.textPrimary)
            .focused($searchFocused)
            // Fills the row's height, so there's no gap above it for topDragStrip to meet.
            .frame(maxHeight: .infinity)
            .background(alignment: .leading) {
                // An IME's marked text leaves `query` empty, so the placeholder would overlap it.
                if vm.query.isEmpty, !vm.isComposing {
                    Text(searchPrompt)
                        .font(metrics.typography.searchField)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        // Never a click target: tapping the placeholder must still land the caret.
                        .allowsHitTesting(false)
                }
            }
            // The prompt used to carry this; without it the field would be unlabelled.
            .accessibilityLabel(Text(searchPrompt))
            // Never branches on query — that tore down the field editor mid-keystroke once.
            .overlay {
                if settings.paletteDraggable {
                    EmptyFieldDragHandle(
                        // Marked text leaves `query` empty, and composing it is still editing.
                        isEmpty: vm.query.isEmpty && !vm.isComposing,
                        onBegan: beginDrag, onEnded: endDrag,
                        // A press that never moved was aimed at the field the handle covers.
                        onClick: { searchFocused = true })
                }
            }
            // The panel resolves the pointer against this rather than hit-testing for the field.
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                // A hidden field takes no caret, so it claims no I-beam region either.
                vm.searchFieldFrame = hidesSearchField ? .zero : $0
            }
    }

    private var pillTint: Color { .primary }

    private func bottomBar(
        pillLabel: String, showActionGroup: Bool, formPrimaryShortcut: Bool, showActions: Bool
    ) -> some View {
        // Same scrim as the panel behind it, so rows hide beneath with no visible band.
        HStack(spacing: 0) {
            appMenuButton
            Spacer()
            if showActionGroup {
                actionGroup(
                    pillLabel: pillLabel, formPrimaryShortcut: formPrimaryShortcut,
                    showActions: showActions)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .frame(height: metrics.size.bottomBarHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.panelScrim(transparency: settings.paletteTransparency))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
        }
    }

    private var appMenuButton: some View {
        MenuCircleButton {
            if openMenu == .app { closeMenus() } else { open(.app, highlighting: 0) }
        }
    }

    /// The footer actions: bare buttons on the panel, separated the way Raycast separates them.
    private func actionGroup(
        pillLabel: String, formPrimaryShortcut: Bool, showActions: Bool
    ) -> some View {
        HStack(spacing: metrics.spacing.md) {
            BarButton(action: activateSelection) {
                HStack(spacing: metrics.spacing.sm) {
                    Text(pillLabel)
                        .font(metrics.typography.bar)
                        .foregroundStyle(pillTint)
                    if formPrimaryShortcut {
                        HStack(spacing: metrics.spacing.xxs) {
                            KeyCapChip(text: "⌘", style: .outline)
                            KeyCapChip(text: "↵", style: .outline)
                        }
                    } else {
                        KeyCapChip(text: "↵", style: .outline)
                    }
                }
            }
            if showActions {
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: Theme.Size.hairline, height: 16)
                BarButton(action: toggleActions) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Actions")
                            .font(metrics.typography.bar)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        HStack(spacing: metrics.spacing.xxs) {
                            KeyCapChip(text: "⌘", style: .outline)
                            KeyCapChip(text: "K", style: .outline)
                        }
                    }
                }
            }
        }
    }

    /// The one path opening the Actions menu, sampling the state its rows depend on.
    private func openActions() {
        let launcher = screen as? LauncherScreen
        selectionIsRunning = launcher.map { $0.isRunning(at: selection(in: $0)) } ?? false
        open(.actions, highlighting: 0)
    }

    private func toggleActions() {
        if openMenu == .actions {
            closeMenus()
        } else {
            openActions()
        }
    }

    /// Opens on the active filter, so the current value is the highlighted row like a pop-up's.
    private func toggleClipboardFilter() {
        if openMenu == .clipboardFilter {
            closeMenus()
            return
        }
        let active = ClipboardFilter.allCases.firstIndex(of: vm.clipboardFilter) ?? 0
        open(.clipboardFilter, highlighting: active)
    }

    private func toggleFileSearchFilter() {
        if openMenu == .fileSearchFilter {
            closeMenus()
            return
        }
        let active = FileSearchFilter.allCases.firstIndex(of: vm.fileSearchFilter) ?? 0
        open(.fileSearchFilter, highlighting: active)
    }

    /// Opens on the choice the dropdown holds, exactly as the clipboard filter opens on its own.
    private func toggleExtensionSearchAccessory() {
        if openMenu == .extensionAccessory {
            closeMenus()
            return
        }
        guard let accessory = extensionCommandScreen?.searchAccessory else { return }
        let value = extensions.accessorySelection(accessory)
        open(.extensionAccessory, highlighting: accessory.index(of: value))
    }

    /// Every header menu states its own width, so resizing one never moves another.
    private func headerMenu(_ popover: PopoverMenuContent, width: CGFloat) -> PaletteMenuContent {
        PaletteMenuContent(
            popover: popover, selection: $menuSelection, width: width, onActivate: activateMenuItem)
    }

    /// Every open path lands here, so the highlight is always stated rather than left behind.
    private func open(_ menu: OpenMenu, highlighting row: Int) {
        if menu == .actions { vm.menuFilter = "" }
        menuSelection = row
        vm.noteMenuPresentation()
        openMenu = menu
    }

    private func closeMenus() {
        menuPanel.hide()
        openMenu = nil
        vm.menuFilter = ""
        argumentOptionsField = nil
    }

    /// Drives the menu's window from the two pieces of state that decide what it shows.
    private func syncMenuPanel(presenting: Bool) {
        guard let content = menuContent, let corner = menuCorner else {
            menuPanel.hide()
            return
        }
        let view = content.view(corner)
        if presenting, let hostWindow {
            menuPanel.show(
                view, corner: corner, parent: hostWindow, core: core,
                clipPath: content.clipPath, motion: content.motion)
        } else {
            menuPanel.update(
                view, corner: corner, core: core, clipPath: content.clipPath,
                motion: content.motion)
        }
    }

    /// An action can remove the last visible pin; never leave an invisible menu owning input.
    private func refreshActionsMenu() {
        guard openMenu == .actions else { return }
        guard menuContent != nil else {
            closeMenus()
            return
        }
        syncMenuPanel(presenting: false)
    }

    private var menuCorner: MenuPanelCorner? {
        switch openMenu {
        case .app: .bottomLeading
        case .actions: .bottomTrailing
        case .argumentOptions: .belowHeaderTrailing
        case .clipboardFilter, .fileSearchFilter,
            .extensionAccessory:
            .belowHeaderTrailing
        case nil: nil
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int, in screen: any PaletteScreen) {
        let count = screen.rows.count
        guard count > 0 else { return }
        vm.selection = min(max(selection(count: count) + delta, 0), count - 1)
        scroll = ScrollIntent(kind: .follow)
    }

    /// ↑/↓: the screen's own move where it has one, else a linear step through the rows.
    private func moveVertically(_ delta: Int) -> KeyPress.Result {
        let screen = screen
        // A control editing with ↑/↓ keeps them; only ⇥ leaves it.
        guard !screen.ownsVerticalKeys(at: selection(in: screen)) else { return .ignored }
        // Moving off a command takes its argument fields with it, so hand focus back first.
        if argumentFocused != nil { returnFocusToSearchField() }
        guard let next = screen.move(delta, axis: .vertical, from: selection(in: screen)) else {
            move(delta, in: screen)
            return .handled
        }
        vm.selection = next
        scroll = ScrollIntent(kind: .follow)
        return .handled
    }

    /// ←/→: consumed only by a horizontally navigating screen, else the caret keeps them.
    private func moveHorizontally(_ delta: Int) -> Bool {
        let screen = screen
        guard let next = screen.move(delta, axis: .horizontal, from: selection(in: screen)) else {
            return false
        }
        vm.selection = next
        scroll = ScrollIntent(kind: .follow)
        return true
    }

    /// Claimed whole on the launcher, so a press at an end cannot reach the caret.
    private func movePinnedOrFavorite(
        _ delta: Int, modifiers: EventModifiers
    ) -> KeyPress.Result? {
        guard modifiers.contains(.command), modifiers.contains(.option), !isCollapsed else {
            return nil
        }
        if let launcher = screen as? LauncherScreen {
            if launcher.moveFavorite(delta, at: selection(in: launcher)), menuOpen { closeMenus() }
            return .handled
        }
        return nil
    }

    /// Move the open menu's highlight past rows it cannot land on, stopping at the ends (no wrap).
    private func moveMenu(_ delta: Int) {
        guard let content = menuContent else { return }
        var row = menuSelection + delta
        while (0..<content.rowCount).contains(row) {
            if content.isSelectable(row) {
                menuSelection = row
                return
            }
            row += delta
        }
    }

    /// The one activation path for a menu row: run its action, then close.
    private func activateMenuItem(_ index: Int) {
        guard let content = menuContent, (0..<content.rowCount).contains(index) else { return }
        guard content.isSelectable(index) else { return }
        content.activate(index)
        closeMenus()
        // A mouse click on a row takes the caret with it; menus close back into the field.
        if argumentFocused == nil { searchFocused = true }
    }

    /// For the chords the panel hands over as tokens, which work while a menu is open.
    private func performShortcut(_ shortcut: PaletteShortcut) {
        let screen = screen
        _ = screen.perform(shortcut, at: selection(in: screen))
    }

    /// A ring hop leaves a step back — except the hop closing the ring on the launcher, its root.
    private func cycleMode() {
        switch PaletteTabAction.resolve(
            mode: vm.mode,
            clipboardEnabled: settings.clipboardEnabled)
        {
        case .carryQuery(.launcher):
            vm.mode = .launcher
            vm.resetNavigation()
        case .carryQuery(let mode): vm.pushCarryingQuery(mode: mode)
        case .freshScreen(let mode): vm.push(mode: mode)
        }
    }

    /// Tab walks a screen's own fields first, then the inline arguments, then rings the modes.
    private func advanceTabFocus(backwards: Bool) {
        let screen = screen
        if let next = screen.tabTarget(from: selection(in: screen), backwards: backwards) {
            vm.selection = next
            scroll = ScrollIntent(kind: .follow)
            return
        }
        guard let accessory = headerAccessory, !accessory.fieldNames.isEmpty else {
            return cycleMode()
        }
        // Read from the local value: a `@FocusState` set in this tick still reads back stale.
        let next = accessory.field(after: argumentFocused, backwards: backwards)
        argumentFocused = next
        searchFocused = next == nil
    }

    /// Right at an inline field's end and Left at its start continue the same ring as Tab.
    private func installHeaderArrowHandler(in window: NSWindow?) {
        guard let panel = window as? PalettePanel else { return }
        panel.onHeaderFieldBoundaryArrow = { boundary in
            guard !menuOpen, !vm.isControlListOpen, !isCollapsed,
                let accessory = headerAccessory, !accessory.fieldNames.isEmpty
            else { return false }
            switch boundary {
            case .leading:
                // Query's left edge keeps its normal caret behavior; an argument moves back.
                guard argumentFocused != nil else { return false }
                advanceTabFocus(backwards: true)
            case .trailing:
                advanceTabFocus(backwards: false)
            }
            return true
        }
    }

    /// AppKit selects the whole query as the field editor comes back, which is the wanted reset.
    private func returnFocusToSearchField() {
        argumentFocused = nil
        searchFocused = true
    }

    /// The palette was opened to fill one row's fields, so the caret starts in the first empty one.
    private func focusPendingArgument() {
        guard vm.pendingArgumentEntryID != nil,
            let field = headerAccessory?.firstIncompleteField
        else { return }
        argumentFocused = field
        searchFocused = false
        vm.pendingArgumentEntryID = nil
    }

    /// An `options=` field is chosen from the palette's own menu, never typed into.
    private func openArgumentOptions(_ field: String) {
        guard let accessory = headerAccessory, accessory.optionsMenu(field) != nil else { return }
        argumentFocused = field
        searchFocused = false
        argumentOptionsField = field
        open(.argumentOptions, highlighting: 0)
    }

    /// An extension keeps its own stack, so it can have a step back the palette cannot see.
    private var hasBackStep: Bool {
        vm.canGoBack || (vm.mode == .extensionCommand && extensions.navigationDepth > 1)
    }

    /// Never promises a step the click does not take: a root screen closes rather than backs.
    private var backHelp: String {
        let escape = hasBackStep ? "Esc to go back" : "Esc to close"
        return "\(escape) or ⌘ Esc to go to root search"
    }

    private func goBack() {
        if vm.mode == .extensionCommand {
            core.extensionCoordinator.exitExtensionScreen()
            return
        }
        if !vm.pop() { core.paletteCoordinator.hidePalette() }
    }

    private func activateSelection() {
        // Nothing is visibly selected when collapsed, so launch via ⌘1–⌘5 or typing.
        guard !isCollapsed else { return }
        // An unfilled field blocks the launch; focus it instead of acting on a half-typed row.
        if let incomplete = headerAccessory?.firstIncompleteField {
            argumentFocused = incomplete
            searchFocused = false
            return
        }
        let screen = screen
        screen.activate(at: selection(in: screen))
    }

}

/// The palette's in-window menus. One optional of these is the whole "only one is open" invariant.
private enum OpenMenu {
    case actions
    case extensionAccessory
    /// An `options=` argument field's choices, hung under the header where the chip sits.
    case argumentOptions
    case app
    case clipboardFilter
    case fileSearchFilter
}

/// Its own modifier: the palette's body is already at the type-checker's limit.
private struct SearchFieldHiding: ViewModifier {
    let hidden: Bool
    let apply: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: hidden) { _, hidden in apply(hidden) }
    }
}

/// The footer's menu circle; hover lives here, so a sweep never re-renders the body.
private struct MenuCircleButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().frame(width: 14, height: 1.5)
                Capsule().frame(width: 8, height: 1.5)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: metrics.size.menuButton, height: metrics.size.menuButton)
            .background(Circle().fill(hovered ? Theme.Colors.rowHover : Color.clear))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Hover state lives here, so lighting the chevron never re-renders the header around it.
private struct HeaderBackButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(metrics.typography.headerIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .frame(width: metrics.size.headerIconSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .help(help)
    }
}
