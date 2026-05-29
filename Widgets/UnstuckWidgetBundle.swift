import WidgetKit
import SwiftUI

@main
struct UnstuckWidgetBundle: WidgetBundle {
    var body: some Widget {
        StartNextWidget()
        FocusLiveActivity()   // ActivityKit (iOS 16.1+; deployment target is 17)
    }
}
