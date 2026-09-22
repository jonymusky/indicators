import SwiftUI
import IndicatorsCore

@main
struct IndicatorsApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(title: store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }

    }
}

struct MenuBarLabel: View {
    let title: String

    var body: some View {
        // MenuBarExtra renders the label as a template image, so keep it monochrome.
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if !title.isEmpty {
                Text(title).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
            }
        }
    }
}
