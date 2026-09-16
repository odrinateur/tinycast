import Foundation

/// The independently importable categories in a Raycast export, so the user can pick a subset.
struct RaycastImportOptions: OptionSet, Sendable {
    let rawValue: Int
    static let shortcuts = RaycastImportOptions(rawValue: 1 << 0)
    static let favorites = RaycastImportOptions(rawValue: 1 << 1)
    static let suggestions = RaycastImportOptions(rawValue: 1 << 2)
    static let launchAtLogin = RaycastImportOptions(rawValue: 1 << 3)
    static let menuBarVisibility = RaycastImportOptions(rawValue: 1 << 4)
    static let clipboardHistory = RaycastImportOptions(rawValue: 1 << 5)
    static let popToRoot = RaycastImportOptions(rawValue: 1 << 6)
    static let compactMode = RaycastImportOptions(rawValue: 1 << 7)
    static let aliases = RaycastImportOptions(rawValue: 1 << 9)
    static let quicklinks = RaycastImportOptions(rawValue: 1 << 10)
    static let all: RaycastImportOptions = [
        .shortcuts, .favorites, .suggestions, .launchAtLogin, .menuBarVisibility, .clipboardHistory,
        .popToRoot, .compactMode, .aliases, .quicklinks
    ]
}

/// A quicklink frecency row keyed by link; the import mints fresh UUIDs, so links reconcile.
struct QuicklinkSeed: Sendable {
    var link: String
    var query: String
    var count: Int
    var lastUsed: Date
}

/// What a `.rayconfig` yields, before it reaches the app. See docs/features/raycast-import.md.
enum RaycastImport {
    struct Result {
        var backup: SettingsBackup
        var clipboard: [ClipboardItem]
        var quicklinks: [Quicklink]
        /// Raycast frecency as learned rows; merged, never replacing what Tinycast learned.
        var rankingSeeds: [LauncherRankingRecord]
        /// Quicklink frecency keyed by link; reconciled against the library at apply time.
        var quicklinkSeeds: [QuicklinkSeed]
        /// Image clips whose file no longer exists, reported so the UI can note them.
        var missingImages: Int

        /// Trimmed to the chosen categories; `apply()` being per-field, dropping is enough.
        func selecting(_ options: RaycastImportOptions) -> Result {
            var trimmed = SettingsBackup()
            if options.contains(.shortcuts) { trimmed.hotkeys = backup.hotkeys }
            if options.contains(.favorites) { trimmed.favoriteApps = backup.favoriteApps }
            if options.contains(.aliases) { trimmed.launcherAliases = backup.launcherAliases }

            var settings = SettingsBackup.SettingsData()
            var hasSettings = false
            if options.contains(.launchAtLogin), let launch = backup.settings?.launchAtLogin {
                settings.launchAtLogin = launch
                hasSettings = true
            }
            if options.contains(.menuBarVisibility), let show = backup.settings?.showInMenuBar {
                settings.showInMenuBar = show
                hasSettings = true
            }
            if options.contains(.popToRoot), let secs = backup.settings?.popToRootSeconds {
                settings.popToRootSeconds = secs
                hasSettings = true
            }
            if options.contains(.compactMode) {
                if let compact = backup.settings?.compactMode {
                    settings.compactMode = compact
                    hasSettings = true
                }
                if let showFavorites = backup.settings?.showFavoritesInCompactMode {
                    settings.showFavoritesInCompactMode = showFavorites
                    hasSettings = true
                }
            }
            if options.contains(.shortcuts) {
                if let shift = backup.settings?.hyperKeyIncludesShift {
                    settings.hyperKeyIncludesShift = shift
                    hasSettings = true
                }
                if let key = backup.settings?.hyperKey {
                    settings.hyperKey = key
                    hasSettings = true
                }
            }

            let keepClipboard = options.contains(.clipboardHistory)
            // The per-app exclusion list belongs to clipboard history, not to settings as a whole.
            if keepClipboard, let disabled = backup.settings?.clipboardDisabledApps {
                settings.clipboardDisabledApps = disabled
                hasSettings = true
            }
            if hasSettings { trimmed.settings = settings }

            return Result(
                backup: trimmed,
                clipboard: keepClipboard ? clipboard : [],
                quicklinks: options.contains(.quicklinks) ? quicklinks : [],
                rankingSeeds: options.contains(.suggestions) ? rankingSeeds : [],
                quicklinkSeeds: options.contains(.suggestions) ? quicklinkSeeds : [],
                missingImages: keepClipboard ? missingImages : 0)
        }
    }

    /// Quicklink seeds onto library rows, matched by rewritten link: the UUIDs never survive.
    static func rankingRecords(
        for seeds: [QuicklinkSeed], in library: [Quicklink]
    ) -> [LauncherRankingRecord] {
        var entryIDs: [String: String] = [:]
        for quicklink in library { entryIDs[quicklink.link] = quicklink.entryID }
        var records: [LauncherRankingRecord] = []
        for seed in seeds {
            let link = RaycastQuicklinkImport.rewrittenLink(
                seed.link.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let entryID = entryIDs[link] else { continue }
            records.append(
                LauncherRankingRecord(
                    itemKey: entryID, submittedQuery: seed.query, count: seed.count,
                    lastUsed: seed.lastUsed))
        }
        return records
    }
}
