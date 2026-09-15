import Combine
import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Label(
                        accessibilityTrusted ? "Granted" : "Not granted",
                        systemImage: accessibilityTrusted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(accessibilityTrusted ? Color.green : Color.orange)
                } label: {
                    SettingsRowTitle(.permissionsAccessibility, "Accessibility")
                    Text("Lets Tinycast paste a clipboard item into the app you were using.")
                }

                LabeledContent {
                    Button(accessibilityTrusted ? "Open…" : "Grant Access…") {
                        Permissions.openAccessibilitySettings()
                    }
                } label: {
                    Text(accessibilityTrusted ? "Manage in System Settings" : "Grant access")
                    Text("Opens Privacy & Security › Accessibility.")
                }
            } header: {
                SettingsSectionHeader(.permissionsAccessibility)
            } footer: {
                Text("Access Tinycast needs to work with other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .settingsScrollTarget(.permissions)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        let trusted = Permissions.isAccessibilityTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }
}
