import SwiftUI

private enum MainTab: Hashable {
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

private struct AlarmHomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.alarmHomeTitle)
                .font(.largeTitle.bold())
                .foregroundStyle(OAColor.textPrimary)

            Text(L10n.alarmHomeSubtitle)
                .font(.body)
                .foregroundStyle(OAColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct SettingsHomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.settingsTitle)
                .font(.title.bold())
                .foregroundStyle(OAColor.textPrimary)

            Text(L10n.settingsSubtitle)
                .font(.body)
                .foregroundStyle(OAColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

#Preview {
    MainTabView()
}
