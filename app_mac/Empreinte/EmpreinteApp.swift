import SwiftUI

/// Point d'entrée. Avant d'ouvrir la moindre fenêtre, on regarde si l'app a
/// été lancée en ligne de commande pour la mise à jour (`--maj-verifier`,
/// `--maj-installer`, `--maj-retour`, `--version`) : c'est ce qui permet de
/// tester tout le mécanisme sans interface. En usage normal, aucun argument
/// n'est passé et l'app démarre comme avant.
@main
enum Lanceur {
    static func main() {
        if OutilMAJ.traiterArguments() { return }
        EmpreinteApp.main()
    }
}

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
