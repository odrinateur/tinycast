import SwiftUI

@main
struct TinycastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // `@AppStorage` republishes only on change, avoiding a scene ⇄ binding loop.
    @AppStorage(SettingsKey.showInMenuBar) private var showInMenuBar = true

    // Channel-aware: "Tinycast", "Tinycast Dev", or "Tinycast Beta".
    private let appName = Bundle.main.appDisplayName

    /// The one menu-bar item, gated by its own preference.
    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarMenu(appName: appName)
        } label: {
            MenuBarLabel(appName: appName)
        }
        .commands { menuBarCommands }
    }

    /// Declared, not assigned to `NSApp.mainMenu`: SwiftUI rebuilds the menu on any scene change.
    @CommandsBuilder
    private var menuBarCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(appName)") { AppCore.shared.settingsCoordinator.showAbout() }
            Button("Check for Updates…") { AppCore.shared.updateCoordinator.checkForUpdates() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppCore.shared.settingsCoordinator.showSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .appTermination) {
            Button("Close Settings") { AppCore.shared.settingsCoordinator.closeSettings() }
                .keyboardShortcut("q")
        }
    }
}
