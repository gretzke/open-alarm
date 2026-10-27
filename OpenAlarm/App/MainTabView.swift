import SwiftUI

enum MainTab: Hashable {
    case alarm
    case settings
}

struct MainTabView: View {
    var onPresentNapBedside: (UUID) -> Void = { _ in }
    @State private var selectedTab: MainTab = .alarm

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: MainTab.alarm) {
                AlarmHomeView(onPresentNapBedside: onPresentNapBedside)
            } label: {
                Label(L10n.tabAlarm, systemImage: "alarm.fill")
            }

            Tab(value: MainTab.settings) {
                SettingsHomeView()
            } label: {
                Label(L10n.tabSettings, systemImage: "gearshape.fill")
            }
        }
        .tint(OAColor.actionCyan)
        .background(OAColor.background.ignoresSafeArea())
    }
}

#Preview {
    MainTabView()
        .environmentObject(AlarmStore())
}
