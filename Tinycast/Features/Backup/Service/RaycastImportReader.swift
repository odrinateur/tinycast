import AppKit
import Foundation

/// Maps a decrypted Raycast payload onto Tinycast's fields. See docs/features/raycast-import.md.
enum RaycastImportReader {
    static func read(file: URL, passphrase: String) throws -> RaycastImport.Result {
        try map(RaycastDecoder.decrypt(try Data(contentsOf: file), passphrase: passphrase))
    }

    private static func map(_ decrypted: Data) throws -> RaycastImport.Result {
        guard let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            throw RaycastImportError.corrupt
        }
        // The sealed file is package-keyed; the container is category-keyed.
        if json["builtin_package_raycastPreferences"] != nil {
            return mapPackages(json)
        }
        var backup = SettingsBackup()
        backup.settings = mapSettings(json)
        backup.hotkeys = mapHotkeys(json)
        backup.favoriteApps = mapFavorites(json)
        backup.launcherAliases = mapAliases(json)
        let (clipboard, missing) = mapClipboard(json)
        let quicklinks = RaycastQuicklinkImport.parse(json["quicklinks"])
        return RaycastImport.Result(
            backup: backup,
            clipboard: clipboard,
            quicklinks: quicklinks,
            rankingSeeds: [],
            quicklinkSeeds: [],
            missingImages: missing)
    }

    // MARK: - Sealed payload

    /// What the package-keyed payload yields; favorites and per-app hotkeys have no package.
    private static func mapPackages(_ json: [String: Any]) -> RaycastImport.Result {
        var backup = SettingsBackup()
        backup.settings = mapPackageSettings(json)
        backup.hotkeys = mapPackageHotkeys(json)
        let (clipboard, missing) = mapPackageClipboard(json)
        return RaycastImport.Result(
            backup: backup,
            clipboard: clipboard,
            quicklinks: mapPackageQuicklinks(json),
            rankingSeeds: mapPackageRankingSeeds(json),
            quicklinkSeeds: mapPackageQuicklinkSeeds(json),
            missingImages: missing)
    }

    private static func mapPackageSettings(_ json: [String: Any]) -> SettingsBackup.SettingsData? {
        let prefs = json["builtin_package_raycastPreferences"] as? [String: Any]
        let advanced = prefs?["preferencesAdvanced"] as? [String: Any]
        let appearance = prefs?["preferencesAppearance"] as? [String: Any]
        var data = SettingsBackup.SettingsData()
        var mapped = false
        // Disabled in Raycast, the tap stays off here too: the switch is the consent.
        if let hyper = advanced?["raycast_hyperKey_state"] as? [String: Any],
            hyper["enabled"] as? Bool == true
        {
            if let shift = hyper["includeShiftKey"] as? Bool {
                data.hyperKeyIncludesShift = shift
                mapped = true
            }
            if let code = hyper["keyCode"] as? Int,
                let key = HyperKeyPhysicalKey.allCases.first(where: { $0.keyCode == code })
            {
                data.hyperKey = key.rawValue
                mapped = true
            }
        }
        if let show = appearance?["statusBarIsVisible"] as? Bool {
            data.showInMenuBar = show
            mapped = true
        }
        if let secs = advanced?["popToRootTimeout"] as? Int,
            let timeout = PopToRootTimeout(rawValue: secs)
        {
            data.popToRootSeconds = timeout.rawValue
            mapped = true
        }
        if appearance?["raycastPreferredWindowMode"] as? String != nil {
            data.compactMode = appearance?["raycastPreferredWindowMode"] as? String == "compact"
            mapped = true
        }
        if let showFavorites = appearance?["showFavoritesInCompactMode"] as? Bool {
            data.showFavoritesInCompactMode = showFavorites
            mapped = true
        }
        if let disabled = (json["builtin_package_clipboardHistory"] as? [String: Any])?[
            "clipboardHistoryDisabledApplications"] as? [String]
        {
            data.clipboardDisabledApps = disabled
            mapped = true
        }
        return mapped ? data : nil
    }

    /// The global hotkey only; per-command hotkeys have no package in the sealed payload.
    private static func mapPackageHotkeys(_ json: [String: Any]) -> SettingsBackup.HotkeyBackup? {
        let general =
            (json["builtin_package_raycastPreferences"] as? [String: Any])?["preferencesGeneral"]
            as? [String: Any]
        guard let raw = general?["raycastGlobalHotkey"] as? String,
            let binding = chordBinding(from: raw)
        else { return nil }
        var hotkeys = SettingsBackup.HotkeyBackup()
        hotkeys.togglePalette = binding
        return hotkeys
    }

    /// "Command-49": named modifiers around a trailing carbon key code, always a `.combo`.
    private static func chordBinding(from chord: String) -> HotKeyBinding? {
        let parts = chord.split(separator: "-").map(String.init)
        guard parts.count >= 2, let code = Int(parts.last!) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "command": flags.insert(.command)
            case "control": flags.insert(.control)
            case "option", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: return nil
            }
        }
        guard !flags.isEmpty else { return nil }
        return .combo(
            KeyShortcut(
                carbonKeyCode: code, carbonModifiers: KeyShortcut.carbonModifiers(from: flags)))
    }

    /// The category decides: an image record's `text` is only its size label, never content.
    private static func mapPackageClipboard(
        _ json: [String: Any]
    ) -> (
        items: [ClipboardItem], missing: Int
    ) {
        guard
            let entries = (json["builtin_package_clipboardHistory"] as? [String: Any])?[
                "clipboardHistoryRecords"] as? [[String: Any]]
        else { return ([], 0) }
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items: [ClipboardItem] = []
        var missing = 0
        for entry in entries {
            let createdAt = parseDate(entry["createdAt"] as? String, using: dateParser) ?? Date()
            let source = (entry["applicationPath"] as? String).flatMap(bundleID(at:))
            switch entry["category"] as? String {
            case "image":
                guard let path = trimmed(entry["filePath"]),
                    FileManager.default.fileExists(atPath: path)
                else {
                    missing += 1
                    continue
                }
                items.append(
                    ClipboardItem(imagePath: path, createdAt: createdAt, sourceBundleID: source))
            case "file":
                guard let path = trimmed(entry["filePath"]),
                    FileManager.default.fileExists(atPath: path)
                else {
                    missing += 1
                    continue
                }
                items.append(
                    ClipboardItem(filePath: path, createdAt: createdAt, sourceBundleID: source))
            case "text", "link", "color":
                guard let text = trimmed(entry["text"]) ?? trimmed(entry["textContent"]) else {
                    continue
                }
                items.append(
                    ClipboardItem(
                        id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: createdAt,
                        sourceBundleID: source))
            default:
                if let text = trimmed(entry["text"]) ?? trimmed(entry["textContent"]) {
                    items.append(
                        ClipboardItem(
                            id: UUID(), kind: .text, text: text, imagePath: nil,
                            createdAt: createdAt, sourceBundleID: source))
                }
            }
        }
        return (items, missing)
    }

    /// Reshaped onto the shared parser, so `{Query}` and dates behave exactly as before.
    private static func mapPackageQuicklinks(_ json: [String: Any]) -> [Quicklink] {
        guard
            let entries = (json["builtin_package_quicklinks"] as? [String: Any])?["quicklinks"]
                as? [[String: Any]]
        else { return [] }
        let shaped: [[String: Any]] = entries.compactMap { entry in
            guard entry["isEnabled"] as? Bool ?? true else { return nil }
            var row = entry
            if let url = entry["url"] { row["link"] = url }
            if let updated = entry["updatedAt"] { row["createdAt"] = updated }
            return row
        }
        return RaycastQuicklinkImport.parse(shaped)
    }

    /// Raycast frecency as learned rows: one per submitted prefix-term, counted by repetition.
    private static func mapPackageRankingSeeds(_ json: [String: Any]) -> [LauncherRankingRecord] {
        // Only bundle-ID keys meet a Tinycast preference key; commands have no counterpart.
        var counts: [String: [String: Int]] = [:]
        var lastUsed: [String: Date] = [:]
        for entry in rootSearchEntries(json) {
            guard (entry["type"] as? String) == "systemApp",
                let key = trimmed(entry["key"]), !key.isEmpty,
                let terms = entry["searchTerms"] as? String
            else { continue }
            foldTerms(
                terms, used: referenceDate(from: entry["openedAt"]) ?? Date(),
                counts: &counts, lastUsed: &lastUsed, identity: key)
        }
        var seeds: [LauncherRankingRecord] = []
        for (key, queries) in counts {
            for (query, count) in queries {
                seeds.append(
                    LauncherRankingRecord(
                        itemKey: key, submittedQuery: query, count: count,
                        lastUsed: lastUsed[key] ?? Date()))
            }
        }
        return seeds
    }

    /// Quicklink frecency keyed by link; the UUIDs never survive, reconciled at apply time.
    private static func mapPackageQuicklinkSeeds(_ json: [String: Any]) -> [QuicklinkSeed] {
        var counts: [String: [String: Int]] = [:]
        var lastUsed: [String: Date] = [:]
        for entry in rootSearchEntries(json) {
            guard (entry["type"] as? String) == "quicklink",
                let link = trimmed(entry["path"]), !link.isEmpty,
                let terms = entry["searchTerms"] as? String
            else { continue }
            foldTerms(
                terms, used: referenceDate(from: entry["openedAt"]) ?? Date(),
                counts: &counts, lastUsed: &lastUsed, identity: link)
        }
        var seeds: [QuicklinkSeed] = []
        for (link, queries) in counts {
            for (query, count) in queries {
                seeds.append(
                    QuicklinkSeed(
                        link: link, query: query, count: count, lastUsed: lastUsed[link] ?? Date()))
            }
        }
        return seeds
    }

    private static func rootSearchEntries(_ json: [String: Any]) -> [[String: Any]] {
        (json["builtin_package_rootSearch"] as? [String: Any])?["rootSearch"]
            as? [[String: Any]] ?? []
    }

    private static func foldTerms(
        _ terms: String, used: Date, counts: inout [String: [String: Int]],
        lastUsed: inout [String: Date], identity: String
    ) {
        for rawTerm in terms.split(separator: ",") {
            let term = LauncherRankingStore.normalize(String(rawTerm))
            guard !term.isEmpty, term.count <= LauncherRankingStore.queryLimit else { continue }
            counts[identity, default: [:]][term, default: 0] += 1
            lastUsed[identity] = max(lastUsed[identity] ?? .distantPast, used)
        }
    }

    /// Raycast dates are CFAbsoluteTime; anything else is not a date at all.
    private static func referenceDate(from value: Any?) -> Date? {
        guard let secs = value as? Double, secs > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    private static func bundleID(at path: String) -> String? {
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Raycast's hyper key code → ours; nothing maps to `.none`, so none is cleared.
    private static let hyperKeyCodes: [String: HyperKeyPhysicalKey] = [
        "caps_lock": .capsLock,
        "right_control": .rightControl,
        "right_shift": .rightShift,
        "right_option": .rightOption,
        "right_command": .rightCommand
    ]

    private static func mapSettings(_ json: [String: Any]) -> SettingsBackup.SettingsData? {
        let general = (json["settings"] as? [String: Any])?["general"] as? [String: Any]
        var data = SettingsBackup.SettingsData()
        var mapped = false
        if let openAtLogin = general?["openAtLogin"] as? Bool {
            data.launchAtLogin = openAtLogin
            mapped = true
        }
        if let includeShift = general?["hyperKeyIncludeShift"] as? Bool {
            data.hyperKeyIncludesShift = includeShift
            mapped = true
        }
        // Without the physical key the imported chord shortcuts can't be triggered.
        if let code = general?["hyperKeyCode"] as? String, let key = hyperKeyCodes[code] {
            data.hyperKey = key.rawValue
            mapped = true
        }
        if let showInMenuBar = general?["showInMenuBar"] as? Bool {
            data.showInMenuBar = showInMenuBar
            mapped = true
        }
        // Exact-match only: a timeout outside our option set is skipped, not clamped.
        if let secs = general?["popToRootTimeout"] as? Int,
            let timeout = PopToRootTimeout(rawValue: secs)
        {
            data.popToRootSeconds = timeout.rawValue
            mapped = true
        }
        // Raycast's window mode is a string; we only have the compact toggle.
        if let mode = general?["windowMode"] as? String {
            data.compactMode = (mode == "compact")
            mapped = true
        }
        if let showFavorites = general?["showFavoritesInCompactMode"] as? Bool {
            data.showFavoritesInCompactMode = showFavorites
            mapped = true
        }
        return mapped ? data : nil
    }

    /// Every Raycast hotkey, in one shape. See docs/features/raycast-import.md.
    private static func mapHotkeys(_ json: [String: Any]) -> SettingsBackup.HotkeyBackup? {
        let settings = json["settings"] as? [String: Any]
        var hotkeys = SettingsBackup.HotkeyBackup()
        var apps: [String: HotKeyBinding] = [:]
        var commands: [String: HotKeyBinding] = [:]
        var mapped = false

        if let general = settings?["general"] as? [String: Any],
            let binding = binding(from: general["globalHotkey"])
        {
            hotkeys.togglePalette = binding
            mapped = true
        }

        for command in settings?["commands"] as? [[String: Any]] ?? [] {
            guard let binding = binding(from: command["macosHotkey"]) else { continue }
            switch command["extensionId"] as? String {
            case "e:r:clipboard-history":
                commands[CommandID.clipboardHistory.rawValue] = binding
                mapped = true
            case "e:r:applications":
                if let path = appPath(fromCommandID: command["id"] as? String),
                    let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
                {
                    apps[bundleID] = binding
                    mapped = true
                }
            default:
                break
            }
        }
        if !apps.isEmpty { hotkeys.apps = apps }
        if !commands.isEmpty { hotkeys.commands = commands }
        return mapped ? hotkeys : nil
    }

    /// A binding from a Raycast hotkey; always a `.combo`, Raycast having no double-tap.
    private static func binding(from hotkey: Any?) -> HotKeyBinding? {
        guard let dict = hotkey as? [String: Any],
            let shortcut = (dict["kind"] as? [String: Any])?["shortcut"] as? [String: Any],
            let key = shortcut["key"] as? [String: Any],
            (key["type"] as? String) == "LayoutIndependent",
            let code = key["code"] as? Int
        else { return nil }

        var flags: NSEvent.ModifierFlags = []
        for entry in (shortcut["modifiers"] as? [[String: Any]]) ?? [] {
            switch entry["modifier"] as? String {
            case "Meta": flags.insert(.command)
            case "Ctrl": flags.insert(.control)
            case "Alt": flags.insert(.option)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        return .combo(
            KeyShortcut(
                carbonKeyCode: code, carbonModifiers: KeyShortcut.carbonModifiers(from: flags)))
    }

    /// Only app favorites map over, keyed by bundle ID, preserving Raycast's order.
    private static func mapFavorites(_ json: [String: Any]) -> [String]? {
        guard let commands = (json["settings"] as? [String: Any])?["commands"] as? [[String: Any]]
        else { return nil }
        let favorites =
            commands
            .compactMap { command -> (order: Int, bundleID: String)? in
                guard let order = command["favoriteOrder"] as? Int,
                    command["extensionId"] as? String == "e:r:applications",
                    let path = appPath(fromCommandID: command["id"] as? String),
                    let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
                else { return nil }
                return (order, bundleID)
            }
            .sorted { $0.order < $1.order }
            .map(\.bundleID)
        return favorites.isEmpty ? nil : favorites
    }

    /// Only application aliases map over, keyed by bundle ID like the hotkeys above.
    private static func mapAliases(_ json: [String: Any]) -> [String: String]? {
        guard let commands = (json["settings"] as? [String: Any])?["commands"] as? [[String: Any]]
        else { return nil }
        var aliases: [String: String] = [:]
        for command in commands {
            guard command["extensionId"] as? String == "e:r:applications",
                let alias = (command["alias"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !alias.isEmpty,
                let path = appPath(fromCommandID: command["id"] as? String),
                let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
            else { continue }
            aliases[bundleID] = alias
        }
        return aliases.isEmpty ? nil : aliases
    }

    /// The launched app's path is the tail of an applications command id.
    private static func appPath(fromCommandID id: String?) -> String? {
        guard let id, let range = id.range(of: "::=::") else { return nil }
        let path = String(id[range.upperBound...])
        return path.isEmpty ? nil : path
    }

    // MARK: - Clipboard

    private static func mapClipboard(_ json: [String: Any]) -> (items: [ClipboardItem], missing: Int) {
        guard
            let entries = (json["clipboardHistory"] as? [String: Any])?["clipboardEntries"]
                as? [[String: Any]]
        else { return ([], 0) }

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var items: [ClipboardItem] = []
        var missing = 0
        for entry in entries {
            let createdAt = parseDate(entry["createdAt"] as? String, using: dateParser) ?? Date()
            let reps = (entry["items"] as? [[String: Any]] ?? [])
                .flatMap { ($0["representations"] as? [[String: Any]]) ?? [] }

            if let text = reps.first(where: {
                ($0["mimeType"] as? String)?.hasPrefix("text/plain") == true
            })?["content"] as? String, !text.isEmpty {
                items.append(
                    ClipboardItem(
                        id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: createdAt,
                        sourceBundleID: nil))
                continue
            }

            if let path = reps.first(where: {
                ($0["mimeType"] as? String)?.hasPrefix("image/") == true
                    && ($0["contentType"] as? String) == "url"
            })?["content"] as? String {
                guard FileManager.default.fileExists(atPath: path) else {
                    missing += 1
                    continue
                }
                items.append(
                    ClipboardItem(imagePath: path, createdAt: createdAt, sourceBundleID: nil))
            }
        }
        return (items, missing)
    }

    // MARK: - Helpers

    private static func parseDate(_ string: String?, using parser: ISO8601DateFormatter) -> Date? {
        guard let string else { return nil }
        // Fractional-seconds parser first; fall back to a whole-second timestamp.
        return parser.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// First value stored under `key` anywhere in a nested JSON object/array tree.
    private static func firstValue(forKey key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let hit = dict[key] { return hit }
            for value in dict.values {
                if let hit = firstValue(forKey: key, in: value) { return hit }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let hit = firstValue(forKey: key, in: value) { return hit }
            }
        }
        return nil
    }
}
