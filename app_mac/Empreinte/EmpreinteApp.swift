import SwiftUI

@main
struct EmpreinteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}   // pas de « Nouvelle fenêtre »
        }
    }
}
