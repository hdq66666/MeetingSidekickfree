import SwiftUI

@main
struct MeetingSidekickfreeApp: App {
    @StateObject private var model = MeetingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        Settings {
            SettingsView()
                .environmentObject(model)
                .padding(20)
                .frame(width: 560)
        }
    }
}
