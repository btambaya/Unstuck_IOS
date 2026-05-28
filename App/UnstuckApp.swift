import SwiftUI
import UnstuckDesign

@main
struct UnstuckApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .unstuckTheme()
                .onOpenURL { model.handleDeepLink($0) }
                .task { await model.start() }
        }
    }
}
