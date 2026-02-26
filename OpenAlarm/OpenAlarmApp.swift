import SwiftUI

@main
struct OpenAlarmApp: App {
    @UIApplicationDelegateAdaptor(OpenAlarmNotificationDelegate.self) private var notificationDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
