import SwiftUI

enum MainTab: Hashable {
    case alarm
    case settings
}

struct MainTabView: View {
    @State private var selectedTab: MainTab = .alarm

    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmHomeView()
                .tag(MainTab.alarm)
                .tabItem {
                    Label {
                        Text(L10n.tabAlarm)
                    } icon: {
                        Image(systemName: "alarm.fill")
                    }
                }

            SettingsHomeView()
                .tag(MainTab.settings)
                .tabItem {
                    Label {
                        Text(L10n.tabSettings)
                    } icon: {
                        Image(systemName: "gearshape.fill")
                    }
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
