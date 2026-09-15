import Foundation

/// Staged bundle → live stores. Everything merges except Launcher Learning, which replaces.
@MainActor
enum BackupApplier {
    struct Summary: Sendable {
        var settings: SettingsBackup.ApplySummary?
        var clipboard = 0
        var learning = 0
        /// Reported rather than thrown: a failure here must not abort the categories after it.
        var problems: [String] = []
    }

    static func apply(
        _ categories: Set<BackupCategory>, from bundle: BackupBundle, to core: AppCore
    ) async -> Summary {
        var summary = Summary()
        if categories.contains(.configuration), let data = try? Data(contentsOf: bundle.settingsURL),
            let backup = try? SettingsBackup(json: data)
        {
            summary.settings = backup.apply(to: core)
        }
        if categories.contains(.clipboard) {
            summary.clipboard = await importClipboard(bundle, into: core.clipboardStore)
            if summary.clipboard > 0 { core.clipboardStore.load() }
        }
        if categories.contains(.learning) {
            summary.learning = applyLearning(bundle, to: core)
        }
        return summary
    }

    // MARK: - Parts

    /// Off-main and streamed: a restored history runs to hundreds of thousands of clips.
    private nonisolated static func importClipboard(
        _ bundle: BackupBundle, into store: ClipboardStore
    ) async -> Int {
        ClipboardStore.importStoredItems(
            inDatabaseAt: store.dbURL, adoptingImagesInto: store.imagesDir,
            bundle.clipboardItems().lazy.compactMap { staged($0, in: bundle) })
    }

    /// The row still points into staging; the store adopts the blob once it accepts the clip.
    private nonisolated static func staged(
        _ item: BackupClipboardItem, in bundle: BackupBundle
    ) -> ClipboardItem? {
        switch item.kind {
        case .text:
            guard let text = item.text else { return nil }
            return ClipboardItem(
                id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: item.createdAt,
                sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
        case .image:
            guard let name = item.imageName, let url = bundle.clipboardImageURL(named: name) else {
                return nil
            }
            return ClipboardItem(
                id: UUID(), kind: .image, text: nil, imagePath: url.path,
                createdAt: item.createdAt, sourceBundleID: item.sourceBundleID,
                pinnedAt: item.pinnedAt)
        case .file:
            // A path from another Mac names nothing here, so the row is dropped rather than dead.
            guard let path = item.text, FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return ClipboardItem(
                id: UUID(), kind: .file, text: path, imagePath: nil, createdAt: item.createdAt,
                sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
        }
    }

    private static func applyLearning(_ bundle: BackupBundle, to core: AppCore) -> Int {
        var applied = 0
        if let records = bundle.decodeLearning(.ranking, as: [LauncherRankingRecord].self) {
            core.launcherRanking.replace(records)
            applied += records.count
        }
        if let entries = bundle.decodeLearning(.calculator, as: [CalcHistoryEntry].self) {
            core.calcHistory.replace(entries)
            applied += entries.count
        }
        return applied
    }

    /// Name and body together, so two snippets sharing one name still both survive an import.
    private struct Pair: Hashable {
        let name: String
        let text: String

        init(_ name: String, _ text: String) {
            self.name = name
            self.text = text
        }
    }
}
