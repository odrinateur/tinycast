import SwiftUI

/// Pressing any menu bar item from the launcher.
struct NavigationSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.navigationEnabled) {
                    SettingsRowTitle(.navigationNavigation, "Enable navigation")
                    Text("Press any menu bar item from the launcher.")
                }
            } header: {
                SettingsSectionHeader(.navigationNavigation)
            }

            // No "show in launcher" switch: the per-command checkboxes below already are one.
            FeatureCommandsSection(owner: .navigation, anchor: .navigationCommands)
                .settingsEnabled(settings.navigationEnabled)

            // The two settings only the menu-search command reads.
            Section {
                Toggle(isOn: $settings.menuSearchShowsAppleMenu) {
                    SettingsRowTitle(.navigationMenuSearch, "Show Apple menu items")
                    Text("Include the Apple menu, which is the same under every application.")
                }

                SettingsRow(
                    title: "Disabled Applications",
                    subtitle:
                        "Search Menu Bar Items will not show menu items from these applications.",
                    anchor: .navigationMenuSearch
                ) {
                    EmptyView()
                }

                DisabledApplicationsList(bundleIDs: $settings.menuSearchDisabledApps)
            } header: {
                SettingsSectionHeader(.navigationMenuSearch)
            }
            .settingsEnabled(settings.navigationEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.navigation)
    }
}
