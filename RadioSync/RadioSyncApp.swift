import SwiftUI

@main
struct RadioSyncApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Testing hook: `xcrun simctl launch <udid> com.beloose.RadioSync -autoplay 1`
                    // presses Play on launch (the argument domain is not persisted).
                    if UserDefaults.standard.bool(forKey: "autoplay") { model.play() }
                }
        }
    }
}
