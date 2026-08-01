import SwiftUI
import WidgetKit

/// The widget extension's entry point. Only the recording Live Activity for now.
@main
struct BounceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
