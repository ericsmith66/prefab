//
//  prefabApp.swift
//  prefab
//
//  Created by Kelly Plummer on 2/14/24.
//

import SwiftUI
import OSLog


@main
struct prefabApp: App {
    private let server = Server()
    @State var displayInstall: Bool = false
    
    init() {
        // Disable excessive os_log from Apple's frameworks (especially HomeKit)
        // This prevents "QUARANTINED DUE TO HIGH LOGGING VOLUME" messages
        // HMFoundation logs 100,000+ times per 10 minutes with active sensors
        setenv("OS_ACTIVITY_MODE", "disable", 0)  // 0 = don't overwrite if already set
        
        // Force HomeBase singleton initialization to set up delegates and subscriptions
        _ = HomeBase.shared
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(homebase: HomeBase.shared)
                .alert("This will install the prefab tool on your PATH", isPresented: $displayInstall) {
                    Button("OK", role: .none, action: {
//                        install the tool
                    })
                    Button("Cancel", role: .cancel){}

                }
        }
        .commands {
            CommandGroup(after: CommandGroupPlacement.appSettings, addition: {
                Button(action: {
                        displayInstall = true
                    }, label: {
                        Text("Install Tool...")
                    })
            })
        }
    }
}
