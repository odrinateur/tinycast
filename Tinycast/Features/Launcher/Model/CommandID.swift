import Foundation

/// Built-in launcher actions, surfaced alongside the user-authored ones.
enum CommandID: String, CaseIterable, Sendable {
    case calculatorHistory = "command:calculator-history"
    case clipboardHistory = "command:clipboard-history"
    case searchFiles = "command:search-files"
    case openInBrowser = "command:open-in-browser"
    case runShellCommand = "command:run-shell-command"
    case createWindowLayout = "command:create-window-layout"
    case captureWindowLayout = "command:capture-window-layout"
    case createQuicklink = "command:create-quicklink"
    case searchQuicklinks = "command:search-quicklinks"
    case importQuicklinks = "command:import-quicklinks"
    case exportQuicklinks = "command:export-quicklinks"
    case exportSettings = "command:export-settings"
    case importSettings = "command:import-settings"
    case importFromRaycast = "command:import-from-raycast"
    case checkForUpdates = "command:check-for-updates"
    case settings = "command:settings"
    case about = "command:about"
    case restart = "command:restart"
    case quit = "command:quit"

    var name: String {
        switch self {
        case .calculatorHistory: return "Calculator History"
        case .clipboardHistory: return "Clipboard History"
        case .searchFiles: return "Search Files"
        case .openInBrowser: return "Open in Browser"
        case .runShellCommand: return "Run Shell Command"
        case .createWindowLayout: return "Create Window Layout"
        case .captureWindowLayout: return "Create Layout from Current Windows"
        case .createQuicklink: return "Create Quicklink"
        case .searchQuicklinks: return "Search Quicklinks"
        case .importQuicklinks: return "Import Quicklinks"
        case .exportQuicklinks: return "Export Quicklinks"
        case .exportSettings: return "Export Backup"
        case .importSettings: return "Import Backup"
        case .importFromRaycast: return "Import from Raycast"
        case .checkForUpdates: return "Check for Updates"
        case .settings: return "Settings"
        case .about: return "About Tinycast"
        case .restart: return "Restart Tinycast"
        case .quit: return "Quit Tinycast"
        }
    }

    var sfSymbol: String {
        switch self {
        case .calculatorHistory: return "plus.forwardslash.minus"
        case .clipboardHistory: return "doc.on.clipboard"
        case .searchFiles: return "doc.text.magnifyingglass"
        case .openInBrowser: return "globe"
        case .runShellCommand: return "terminal"
        case .createWindowLayout: return "plus.rectangle.on.rectangle"
        case .captureWindowLayout: return "macwindow.badge.plus"
        case .createQuicklink: return "link.badge.plus"
        case .searchQuicklinks: return Quicklink.sfSymbol
        case .importQuicklinks: return "square.and.arrow.down"
        case .exportQuicklinks: return "square.and.arrow.up"
        case .exportSettings: return "square.and.arrow.up"
        case .importSettings: return "square.and.arrow.down"
        case .importFromRaycast: return "arrow.down.doc"
        case .checkForUpdates: return "arrow.down.circle"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        case .restart: return "arrow.clockwise"
        case .quit: return "power"
        }
    }

    /// Query-driven: the typed text is their input, so they are built where offered, never listed.
    var isQueryDriven: Bool {
        self == .openInBrowser || self == .runShellCommand
    }

    /// A chord carries no query, and none should be able to terminate the app outright.
    var hotKeyAction: HotKeyAction? {
        isQueryDriven || self == .quit || self == .restart ? nil : .command(self)
    }
}
