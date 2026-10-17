//
//  watchApp.swift
//  watch Watch App
//
//  Created by Reynard Amadeus  on 13/10/26.
//

import Combine
import SwiftUI

@main
struct watch_Watch_AppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(bridge: .shared)
        }
    }
}
