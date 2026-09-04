import SwiftUI

@main
struct RadioSyncApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}
