import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 18) {
            SourceHeader()
            Spacer(minLength: 4)
            DelayReadout()
            DelaySlider()
            NudgeRow()
            Spacer(minLength: 4)
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.dismissError() }
            }
            TransportRow()
            VolumeRow()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .tint(.accentColor)
        .sheet(isPresented: $model.isEditingStreamURL) {
            StreamURLSheet()
                .environment(model)
        }
    }
}

#Preview {
    ContentView()
        .environment(PlayerModel(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .preferredColorScheme(.dark)
}
