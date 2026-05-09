import WidgetKit
import SwiftUI

@main
struct TransitHubWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextDeparturesWidget()
        TransitHubLiveActivityWidget()
    }
}
