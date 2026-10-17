//
//  watchApp.swift
//  watch (iPhone relay app)
//
//  Created by Reynard Amadeus  on 13/10/26.
//

import Combine
import SwiftUI

@main
struct watchApp: App {
    init() {
        // Activate WatchConnectivity at launch, including background launches
        // triggered by the watch, so its messages are always answered.
        PhoneBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(bridge: .shared)
        }
    }
}
