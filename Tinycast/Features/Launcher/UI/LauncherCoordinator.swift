import AppKit

/// Owns launcher activation: the one funnel from a palette row to whatever the entry's kind runs.
@MainActor
final class LauncherCoordinator {
    private let ranking: LauncherRankingStore
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let customCommandCoordinator: CustomCommandCoordinator
    private let quicklinkCoordinator: QuicklinkCoordinator
    private let fileSearchCoordinator: FileSearchCoordinator
    private let extensionCoordinator: ExtensionCoordinator
    /// The backup commands only, which need the live stores to gather from and apply to.
    private unowned let core: AppCore

    init(
        ranking: LauncherRankingStore,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator,
        customCommandCoordinator: CustomCommandCoordinator,
        quicklinkCoordinator: QuicklinkCoordinator,
        fileSearchCoordinator: FileSearchCoordinator,
        extensionCoordinator: ExtensionCoordinator,
        core: AppCore
    ) {
        self.ranking = ranking
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.customCommandCoordinator = customCommandCoordinator
        self.quicklinkCoordinator = quicklinkCoordinator
        self.fileSearchCoordinator = fileSearchCoordinator
        self.extensionCoordinator = extensionCoordinator
        self.core = core
    }

    // MARK: - Activation

    func launch(
        _ app: AppEntry, searchQuery: String? = nil, arguments: [String: String] = [:]
    ) {
        // A category listing is no search: learning it would rank the row under "s".
        if let searchQuery, AppEntry.Kind.named(by: searchQuery) == nil,
            !CommandCatalog.isQueryDriven(app)
        {
            ranking.record(itemKey: app.preferenceKey, query: searchQuery)
        }
        // Commands dispatch before the palette hides: mode-switching commands keep it open.
        if app.kind == .command {
            guard let id = CommandCatalog.command(for: app) else { return }
            // Query-driven: only this row knows the URL the typed text resolved to.
            if id == .openInBrowser {
                paletteCoordinator.hidePalette(restoreFocus: false)
                AppLauncher.open(app.url)
                return
            }
            runCommand(id)
            return
        }
        if app.kind == .customCommand {
            guard let id = CustomCommand.id(fromEntryID: app.id) else { return }
            customCommandCoordinator.runCustomCommand(id: id)
            return
        }
        // Before the palette hides: a view command takes the palette over rather than closing it.
        if app.kind == .extensionCommand {
            extensionCoordinator.runExtensionCommand(app, arguments: arguments)
            return
        }
        // Before the palette hides: an unfilled quicklink stays up to ask first.
        if app.kind == .quicklink {
            guard let id = Quicklink.id(fromEntryID: app.id) else { return }
            quicklinkCoordinator.openQuicklink(id: id, values: arguments)
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        switch app.kind {
        case .application:
            AppLauncher.launch(app.url)
        case .systemSettings:
            guard let bundleID = app.bundleID else { return }
            AppLauncher.openSettingsPane(bundleID: bundleID)
        case .command, .customCommand,
            .quicklink, .extensionCommand:
            break  // handled above
        }
    }

    /// The one funnel a built-in command runs through, from a palette row or its global shortcut.
    func runCommand(_ id: CommandID) {
        switch id {
        case .calculatorHistory:
            paletteCoordinator.togglePalette(mode: .calculatorHistory)
        case .clipboardHistory:
            paletteCoordinator.togglePalette(mode: .clipboard)
        case .searchFiles:
            fileSearchCoordinator.show()
        case .openInBrowser, .runShellCommand:
            break  // Query-driven: each runs where the typed text is, never through this funnel.
        case .searchQuicklinks:
            paletteCoordinator.togglePalette(mode: .quicklinks)
        case .createQuicklink:
            dismissPalette()
            quicklinkCoordinator.editQuicklink(nil)
        case .importQuicklinks:
            dismissPalette()
            Task { await quicklinkCoordinator.importQuicklinks() }
        case .exportQuicklinks:
            dismissPalette()
            Task { await quicklinkCoordinator.exportQuicklinks() }
        case .exportSettings:
            dismissPalette()
            Task { await BackupActions.runExportCommand(core: core) }
        case .importSettings:
            dismissPalette()
            Task { await BackupActions.runImportCommand(core: core) }
        case .importFromRaycast:
            dismissPalette()
            settingsCoordinator.showBackupSettings()
        case .checkForUpdates:
            dismissPalette()
            core.updateCoordinator.checkForUpdates()
        case .settings:
            dismissPalette()
            settingsCoordinator.showSettings()
        case .about:
            dismissPalette()
            settingsCoordinator.showAbout()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// A shortcut runs these with nothing open, where a plain hide would still reset palette state.
    private func dismissPalette() {
        guard paletteCoordinator.isVisible else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
    }

    // MARK: - Row actions

    func resetRanking(for app: AppEntry) {
        ranking.reset(itemKey: app.preferenceKey)
    }

    func showInFinder(_ app: AppEntry) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(app.url)
    }

    /// Focus is never handed back: the relaunch takes it, or the app that refused has it.
    func restart(_ app: AppEntry) {
        guard app.kind == .application, let bundleID = app.bundleID else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task { await AppLauncher.restart(bundleID: bundleID, url: app.url) }
    }

    /// Quits the app behind an entry; a no-op (palette stays put) when it isn't running.
    func quit(_ app: AppEntry) {
        guard app.kind == .application, let bundleID = app.bundleID else { return }
        // Nothing here takes focus, so hand it back unless that app is on its way out.
        let quittingPreviousApp = windowController.previousApp?.bundleIdentifier == bundleID
        guard AppLauncher.quit(bundleID: bundleID) else { return }
        paletteCoordinator.hidePalette(restoreFocus: !quittingPreviousApp)
    }
}
