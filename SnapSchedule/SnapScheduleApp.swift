import SwiftUI

@main
struct SnapScheduleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 560)
            #endif
        }
    }
}
