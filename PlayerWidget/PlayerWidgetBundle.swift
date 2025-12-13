//
//  PlayerWidgetBundle.swift
//  PlayerWidget
//
//  Created by CLQ on 07/12/2025.
//

import WidgetKit
import SwiftUI

@main
struct PlayerWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlayerWidget()
        PlaylistWidget()
        // PlayerWidgetControl() - Control Center widget (iOS 18+)
        // PlayerWidgetLiveActivity() - Live Activity / Dynamic Island
    }
}
