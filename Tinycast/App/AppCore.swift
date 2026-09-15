import AppKit

/// Single owner of every long-lived manager. Wired up once from the app delegate.
@MainActor
@Observable
final class AppCore {
    static let shared = AppCore()

    let launcherRanking: LauncherRankingStore
    let appIndex: AppIndex
    let customCommands = CustomCommandStore()
    let quicklinks = QuicklinkStore()
    let clipboardStore = ClipboardStore()
    @ObservationIgnored private var clipboardTextIndexer: ClipboardTextIndexer?
    let clipboardManager: ClipboardManager
    let snippetsStore: SnippetsStore
    let snippetListener = SnippetKeywordListener(
        syntheticEventTag: Paster.tinycastEventTag)
    let textInjector: TextInjector
    let hotKeys = HotKeyManager()
    let hyperKeyTap = HyperKeyTap()
    let inputSourceSwitcher = InputSourceSwitcher()
    let settings: AppSettings
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private let iconStyle = IconStyleMonitor()
    let favorites = FavoritesStore()
    let visibility = VisibilityStore()
    let aliases = AliasStore()
    let fallbacks = FallbackStore()
    let calcHistory = CalculatorHistoryStore()
    let currencyRates = CurrencyRateStore()
    let updateChecker = UpdateCheckStore()
    let supportReminders: SupportReminderStore
    let runningApps = RunningAppsMonitor()
    let palette = PaletteState()
    let fileSearch = FileSearchSession()
    let menuSearch = MenuSearchSession()
    let activationPolicy = ActivationPolicy()
    let customCommandArguments = CustomCommandArgumentSession()
    let extensions: ExtensionManager

    /// Set when a quicklink editor should open with Settings; the pane consumes it.
    var pendingQuicklinkEdit: QuicklinkEditRequest?
    /// Set when a snippet editor should open with Settings; the pane consumes it.
    var pendingSnippetEdit: SnippetEditRequest?

    @ObservationIgnored private(set) lazy var snippetCoordinator = SnippetCoordinator(
        store: snippetsStore, listener: snippetListener, injector: textInjector,
        clipboardStore: clipboardStore, appIndex: appIndex, settings: settings,
        windowController: windowController, paletteCoordinator: paletteCoordinator,
        settingsCoordinator: settingsCoordinator,
        showMessage: { [unowned self] in self.showMessage($0) }, core: self)
    @ObservationIgnored private(set) lazy var quicklinkCoordinator = QuicklinkCoordinator(
        store: quicklinks, settings: settings,
        appIndex: appIndex, injector: textInjector, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases,
        windowController: windowController,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        clipboardHistory: { [unowned self] in self.snippetCoordinator.clipboardHistoryForExpansion() },
        core: self)

    @ObservationIgnored private(set) lazy var paletteCoordinator = PaletteCoordinator(
        palette: palette, settings: settings, appIndex: appIndex,
        fileSearch: fileSearch, menuSearch: menuSearch,
        windowController: windowController)
    /// Its own window and lifecycle: neither coordinator shows or closes the other's surface.
    @ObservationIgnored private(set) lazy var settingsCoordinator = SettingsCoordinator(core: self)
    @ObservationIgnored private(set) lazy var onboardingCoordinator = OnboardingCoordinator(
        core: self)
    @ObservationIgnored private(set) lazy var extensionCoordinator = ExtensionCoordinator(
        extensions: extensions, palette: palette, paletteCoordinator: paletteCoordinator,
        settingsCoordinator: settingsCoordinator, settings: settings, core: self)
    @ObservationIgnored private(set) lazy var customCommandCoordinator = CustomCommandCoordinator(
        store: customCommands, argumentSession: customCommandArguments, settings: settings,
        appIndex: appIndex,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        hotKeys: hotKeys, favorites: favorites, visibility: visibility,
        ranking: launcherRanking, aliases: aliases, activationPolicy: activationPolicy, core: self)
    @ObservationIgnored private(set) lazy var launcherCoordinator = LauncherCoordinator(
        ranking: launcherRanking, windowController: windowController,
        paletteCoordinator: paletteCoordinator,
        settingsCoordinator: settingsCoordinator,
        customCommandCoordinator: customCommandCoordinator,
        quicklinkCoordinator: quicklinkCoordinator,
        snippetCoordinator: snippetCoordinator, fileSearchCoordinator: fileSearchCoordinator,
        menuSearchCoordinator: menuSearchCoordinator,
        extensionCoordinator: extensionCoordinator,
        core: self)
    @ObservationIgnored private(set) lazy var fallbackCoordinator = FallbackCoordinator(
        store: fallbacks, quicklinks: quicklinks, settings: settings, core: self)
    @ObservationIgnored private(set) lazy var clipboardCoordinator = ClipboardCoordinator(
        clipboardStore: clipboardStore, clipboardManager: clipboardManager, settings: settings,
        appIndex: appIndex, palette: palette, windowController: windowController,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var calculatorCoordinator = CalculatorCoordinator(
        calcHistory: calcHistory, paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var fileSearchCoordinator = FileSearchCoordinator(
        settings: settings, appIndex: appIndex, session: fileSearch, palette: palette,
        paletteCoordinator: paletteCoordinator, windowController: windowController, core: self)
    @ObservationIgnored private(set) lazy var menuSearchCoordinator = MenuSearchCoordinator(
        settings: settings, appIndex: appIndex, session: menuSearch, palette: palette,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var updateCoordinator = UpdateCoordinator(
        store: updateChecker, core: self)
    @ObservationIgnored private(set) lazy var supportCoordinator = SupportCoordinator(
        store: supportReminders, core: self)

    @ObservationIgnored private lazy var windowController = PaletteWindowController(core: self)
    @ObservationIgnored private lazy var messageHUD = MessageHUDController(settings: settings)
    /// Every confirmation, report and prompt; it also stops a held hotkey stacking them.
    @ObservationIgnored private lazy var dialogs = DialogController(settings: settings)
    private let healthTicker = HealthTicker()

    private init() {
        let launcherRanking = LauncherRankingStore()
        let settings = AppSettings()
        self.launcherRanking = launcherRanking
        self.settings = settings
        supportReminders = SupportReminderStore(settings: settings)
        appIndex = AppIndex(ranking: launcherRanking, aliases: aliases)
        let clipboardManager = ClipboardManager(store: clipboardStore, settings: settings)
        self.clipboardManager = clipboardManager
        extensions = ExtensionManager(clipboardStore: clipboardStore)
        snippetsStore = SnippetsStore()
        textInjector = TextInjector(
            clipboardManager: clipboardManager,
            settings: settings)
    }

    func start() {
        Signposts.interval("AppCore.start") {
            // Shorten AppKit's ~2–3s tooltip delay; registration domain, so a user default wins.
            UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
            NSApp.setActivationPolicy(.accessory)
            applyAppearance()
            observeEffectiveAppearance()

            appIndex.start(settings: settings)
            clipboardCoordinator.applyEnabled()
            extensions.start(appIndex: appIndex, coordinator: extensionCoordinator)
            extensionCoordinator.applyEnabled()
            fileSearchCoordinator.applyEnabled()
            menuSearchCoordinator.applyEnabled()
            fileSearchCoordinator.applyPolicy()
            customCommands.onChange = { [weak self] _ in
                self?.customCommandCoordinator.applyCustomCommandsPresence()
            }
            customCommandCoordinator.applyCustomCommandsPresence()
            quicklinks.onChange = { [weak self] _ in
                self?.quicklinkCoordinator.applyQuicklinksPresence()
            }
            // Before `hotKeys.start` even when off: the prune reads it. docs/features/quicklinks.md
            quicklinks.load()
            quicklinkCoordinator.applyQuicklinksPresence()
            updateCoordinator.applyEnabled()
            Task { await appIndex.refresh() }
            currencyRates.start()
            updateChecker.onUpdateAvailable = { [weak self] release in
                self?.updateCoordinator.presentIfAvailable(release) ?? true
            }
            updateChecker.start()
            supportReminders.onDue = { [weak self] in self?.supportCoordinator.presentIfDue() }
            supportReminders.start()

            hyperKeyTap.healthTicker = healthTicker
            hotKeys.doubleTapMonitor.healthTicker = healthTicker
            snippetListener.healthTicker = healthTicker

            hotKeys.onTogglePalette = { [weak self] in self?.paletteCoordinator.togglePalette() }
            hotKeys.onRunCommand = { [weak self] id in self?.launcherCoordinator.runCommand(id) }
            hotKeys.onRunCustomCommand = { [weak self] id in
                self?.customCommandCoordinator.runCustomCommand(id: id)
            }
            hotKeys.onOpenQuicklink = { [weak self] id in
                self?.quicklinkCoordinator.openQuicklink(id: id)
            }
            hotKeys.onRunExtensionCommand = { [weak self] entryID in
                self?.extensionCoordinator.runExtensionCommand(entryID: entryID)
            }
            extensions.onDidUninstall = { [weak self] entryIDs in
                self?.extensionCoordinator.removeExtensionReferences(entryIDs: entryIDs)
            }
            hotKeys.displayName = { [weak self] action in self?.hotKeyDisplayName(for: action) }
            hotKeys.allowsAction = { [weak self] action in
                guard let self, visibility.allowsHotKey(action) else { return false }
                // A disabled feature drops its commands from the launcher; their shortcuts go too.
                guard case .command(let id) = action else { return true }
                return appIndex.isCommandEnabled(id)
            }
            KeyShortcut.displayedHyperChord = { [settings] in
                guard settings.hyperKey != .none else { return nil }
                return KeyShortcut.hyperChord(includesShift: settings.hyperKeyIncludesShift)
            }
            hotKeys.start(
                customCommandIDs: Set(customCommands.commands.map(\.id)),
                quicklinkIDs: Set(quicklinks.quicklinks.map(\.id)))
            // Keeps running while Carbon pauses: the recorder needs its rewritten flags.
            hyperKeyTap.start(settings: settings)

            snippetsStore.onSnapshot = { [weak self] snapshot in
                guard let self else { return }
                self.snippetCoordinator.applySnippetsLauncherPresence()
                self.snippetListener.update(snapshot.records)
            }
            // Off out of the box, so an unused feature costs no load, watcher or tap.
            if settings.snippetsEnabled {
                Task { await snippetsStore.start() }
                snippetCoordinator.startSnippetKeywordListener()
            }
            // Unconditional: a disabled feature has to take its command rows down with it.
            snippetCoordinator.applySnippetsLauncherPresence()

            observeFeatureSwitches()

            // First launch binds no hotkey, so guide once; the marker is written at show-time.
            if !OnboardingState.hasOnboarded {
                OnboardingState.markShown()
                onboardingCoordinator.showOnboarding()
            }
        }
    }

    /// Clicking the Dock icon: raise whichever window is already open, else summon the launcher.
    func handleReopen() {
        if settingsCoordinator.focusExisting() { return }
        if onboardingCoordinator.focusExisting() { return }
        if updateCoordinator.focusExisting() { return }
        if supportCoordinator.focusExisting() { return }
        if customCommandCoordinator.focusOutputWindow() { return }
        paletteCoordinator.showPalette(mode: .launcher, restoreAnyMode: true)
    }

    func handleOpenURL(_ url: URL) {
        switch ExtensionOAuthSession.handleCallbackURL(url) {
        case .delivered:
            paletteCoordinator.showPalette(mode: .extensionCommand, restoreAnyMode: true)
            return
        case .expired:
            showMessage("Sign-in expired — run the command again", tone: .danger)
            return
        case .ignored:
            break
        }
        guard ExtensionDeepLink.claims(url) else { return }
        guard let link = ExtensionDeepLink.parse(url: url) else {
            paletteCoordinator.showPalette(mode: .launcher, restoreAnyMode: true)
            return
        }
        extensionCoordinator.runDeepLink(link)
    }

    /// The store-backed half of the conflict message; `HotKeyManager` names the catalogs itself.
    private func hotKeyDisplayName(for action: HotKeyAction) -> String? {
        switch action {
        case .app(let bundleID):
            return appIndex.apps.first { $0.kind == .application && $0.bundleID == bundleID }?.name
        case .settingsPane(let bundleID):
            return appIndex.apps.first { $0.kind == .systemSettings && $0.bundleID == bundleID }?
                .name
        case .customCommand(let id):
            return customCommands.command(id: id)?.name
        case .quicklink(let id):
            return quicklinks.quicklink(id: id)?.name
        case .extensionCommand(let entryID):
            return appIndex.apps.first { $0.kind == .extensionCommand && $0.id == entryID }?.name
        case .togglePalette, .command:
            return nil
        }
    }

    /// Idempotent: both switches are tracked, and either one flipping re-runs the whole decision.
    func applyClipboardTextSearch() {
        guard settings.clipboardEnabled, settings.clipboardTextSearchEnabled else {
            clipboardStore.onItemsChanged = nil
            clipboardStore.onSearchResultsChanged = nil
            clipboardStore.setTextSearchEnabled(false)
            clipboardTextIndexer?.stop()
            return
        }
        guard clipboardStore.setTextSearchEnabled(true) else {
            showMessage("Couldn't enable text recognition for clipboard history.", tone: .danger)
            return
        }
        clipboardStore.setTextSearchActive(palette.isVisible)
        // Kept across a disable: the indexer reschedules itself once a cancelled run winds down.
        let indexer =
            clipboardTextIndexer
            ?? ClipboardTextIndexer(store: clipboardStore, canRun: { ClipboardTextIndexer.isSystemIdle })
        clipboardTextIndexer = indexer
        clipboardStore.onItemsChanged = { [weak indexer] in indexer?.schedule() }
        clipboardStore.onSearchResultsChanged = { [weak self] query, previous, current in
            self?.clipboardCoordinator.followSearchResults(query: query, previous: previous, current: current)
        }
        indexer.start()
    }

    func prepareForTermination() {
        clipboardTextIndexer?.stop()
        // Caps Lock first: its remap is the one teardown that outlives the process.
        hyperKeyTap.prepareForTermination()
        inputSourceSwitcher.endSession()
        textInjector.prepareForTermination()
        snippetListener.stop()
        snippetsStore.stop()
    }

    // MARK: - Feature switches

    private func observeFeatureSwitches() {
        track(
            {
                _ = $0.customCommandsEnabled
                _ = $0.customCommandsShowInLauncher
            }, reproject: { $0.customCommandCoordinator.applyCustomCommandsPresence() })
        track(
            {
                _ = $0.quicklinksEnabled
                _ = $0.quicklinksShowInLauncher
            }, reproject: { $0.quicklinkCoordinator.applyQuicklinksPresence() })
        track(
            { _ = $0.clipboardEnabled }, reproject: { $0.clipboardCoordinator.applyEnabled() })
        track(
            { _ = $0.clipboardTextSearchEnabled }, reproject: { $0.applyClipboardTextSearch() })
        track({ _ = $0.fileSearchEnabled }, reproject: { $0.fileSearchCoordinator.applyEnabled() })
        track(
            { _ = $0.navigationEnabled },
            reproject: { $0.menuSearchCoordinator.applyEnabled() })
        track(
            {
                _ = $0.fileSearchScopes
                _ = $0.fileSearchIgnorePatterns
            }, reproject: { $0.fileSearchCoordinator.applyPolicy() })
        track({ _ = $0.snippetsEnabled }, reproject: { $0.snippetCoordinator.applySnippetsEnabled() })
        // Not a feature switch, but the same re-projection: a combo has the chord's ⇧ bit baked in.
        track({ _ = $0.hyperKeyIncludesShift }, reproject: { $0.applyHyperChord() })
        track(
            { _ = $0.snippetsShowInLauncher },
            reproject: { $0.snippetCoordinator.applySnippetsLauncherPresence() })
        track({ _ = $0.appearance }, reproject: { $0.applyAppearance() })
        track({ _ = $0.interfaceSize }, reproject: { $0.windowController.applyInterfaceSize() })
    }

    /// `.system` resolves to `nil`, so AppKit follows macOS with nothing polling.
    private func applyAppearance() {
        NSApp.appearance = settings.appearance.nsAppearance
    }

    /// IconCache is told here, not from `applyAppearance()`, which never fires under `.system`.
    private func observeEffectiveAppearance() {
        // Synchronous on main, so no row can cache a tile under the outgoing appearance's key.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial]) { app, _ in
            MainActor.assumeIsolated { IconCache.setDarkSurface(app.effectiveAppearance.isDark) }
        }
    }

    /// Fires synchronously on main before the write lands, so the task re-arms and re-reads.
    private func track(
        _ reads: @escaping @Sendable @MainActor (AppSettings) -> Void,
        reproject: @escaping @Sendable @MainActor (AppCore) -> Void
    ) {
        withObservationTracking {
            reads(settings)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.track(reads, reproject: reproject)
                reproject(self)
            }
        }
    }

    /// Without a Hyper key the chord means nothing, so a literal ⌃⌥⌘ combo is left as recorded.
    private func applyHyperChord() {
        guard settings.hyperKey != .none else { return }
        hotKeys.retargetHyperBindings(includesShift: settings.hyperKeyIncludesShift)
    }

    // MARK: - Interruption

    /// What the app is in the middle of; the update prompt and the support reminder both ask first.
    var currentActivity: UpdateActivity {
        UpdateActivity(
            isExpandingSnippet: textInjector.isDelivering,
            isRunningExtension: extensions.running != nil,
            isRecordingHotKey: hotKeys.recordingAction != nil,
            isPromptingForArguments: customCommandArguments.isActive,
            isShowingDialog: isShowingDialog,
            isPaletteVisible: paletteCoordinator.isVisible)
    }

    /// Whether a window may take focus without interrupting something the user started.
    var canInterruptUser: Bool { UpdateReadiness.evaluate(currentActivity) == nil }

    // MARK: - Dialogs, routed here so `dialogs` stays the single owner

    func showNotice(title: String, message: String, symbol: String, tone: DialogTone) async {
        await dialogs.notice(title: title, message: message, symbol: symbol, tone: tone)
    }

    /// True while a dialog is up, so a surface behind one can tell it apart from losing focus.
    var isShowingDialog: Bool { dialogs.isPresenting }

    /// `tone` styles the glyph, `confirmRole` the button; separate on purpose.
    func confirm(
        title: String, message: String?, symbol: String?, confirmTitle: String,
        tone: DialogTone = .danger, confirmRole: DialogAction.Role = .destructive,
        dismissTitle: String = "Cancel"
    ) async -> Bool {
        await dialogs.confirm(
            title: title, message: message, symbol: symbol, tone: tone, confirmTitle: confirmTitle,
            confirmRole: confirmRole, dismissTitle: dismissTitle)
    }

    /// A question with more than two answers; the returned index is into `options`.
    func choose(
        title: String, message: String?, symbol: String?, options: [DialogAction],
        defaultIndex: Int, tone: DialogTone = .neutral
    ) async -> Int {
        await dialogs.choose(
            title: title, message: message, symbol: symbol, tone: tone, options: options,
            defaultIndex: defaultIndex)
    }

    /// A failure with one usable second option; `true` when the user takes it.
    func reportFailure(
        title: String, message: String, symbol: String, recovery: String?
    ) async
        -> Bool
    {
        await dialogs.reportFailure(
            title: title, message: message, symbol: symbol, recovery: recovery)
    }

    /// The transient success/info pill, so `messageHUD` stays single-owned alongside `dialogs`.
    func showMessage(_ message: String, tone: DialogTone = .success) {
        messageHUD.show(message: message, tone: tone)
    }

    /// The same pill with a spinner, for work the reader started and cannot otherwise see running.
    func showProgress(_ message: String) {
        messageHUD.showProgress(message: message)
    }

    func hideProgress() {
        messageHUD.dismiss()
    }

    /// The snippet argument prompt, for the same reason.
    func fillSnippetArguments(
        snippetName: String, arguments: [SnippetTemplateEngine.MissingArgument]
    ) async -> [String: String]? {
        await dialogs.fillSnippetArguments(snippetName: snippetName, arguments: arguments)
    }
}
