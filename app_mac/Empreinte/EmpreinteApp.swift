import SwiftUI
import AppKit

/// Point d'entrée. Avant d'ouvrir la moindre fenêtre, on regarde si l'app a
/// été lancée en ligne de commande :
///   - pour la mise à jour (`--maj-verifier`, `--maj-installer`,
///     `--maj-retour`, `--version`) : tout le mécanisme se teste sans
///     interface ;
///   - pour les captures d'écran (`--captures <dossier>`) : chaque écran est
///     rendu en PNG avec des données factices, pour contrôler l'interface
///     sans capteur ni moteur.
/// En usage normal, aucun argument n'est passé et l'app démarre comme avant.
@main
enum Lanceur {
    @MainActor
    static func main() {
        if OutilMAJ.traiterArguments() { return }
        if Captures.traiterArguments() { return }
        EmpreinteApp.main()
    }
}

/// Force l'apparence claire : la direction artistique de la maison est sur
/// papier crème, elle ne se décline pas en sombre.
final class DelegueApp: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

struct EmpreinteApp: App {
    @NSApplicationDelegateAdaptor(DelegueApp.self) private var delegue

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}   // pas de « Nouvelle fenêtre »
        }
    }
}
