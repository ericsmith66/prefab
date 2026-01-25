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
        print("Startup code executing - attempting to force HomeBase init")
        
        // Force HomeBase singleton initialization to set up delegates and subscriptions
        _ = HomeBase.shared
        Logger().log("Forced HomeBase.shared initialization at app startup")
        
        print("HomeBase.shared is accessible - homes.count: \(HomeBase.shared.homeManager.homes.count)")
        print("HomeBase.shared.homes: \(HomeBase.shared.homes.map { $0.name })")
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
