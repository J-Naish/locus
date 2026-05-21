import SwiftUI

@main
struct LocusApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .windowResizability(.contentMinSize)
    }
}
