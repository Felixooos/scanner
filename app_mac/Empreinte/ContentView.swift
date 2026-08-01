import SwiftUI
import AppKit

// =========================================================================
// Aiguillage entre les quatre écrans + éléments communs (barre du haut,
// pastille de connexion, capture souris).
// =========================================================================

struct ContentView: View {
    @StateObject private var moteur = Moteur()

    var body: some View {
        // Toute l'interface grandit avec la fenêtre : une seule échelle est
        // calculée ici, puis lue partout via `@Environment(\.echelle)`.
        GeometryReader { geo in
            let echelle = Echelle.pour(geo.size)
            ZStack {
                MMD.creme.ignoresSafeArea()
                Group {
                    switch moteur.ecran {
                    case .accueil:  AccueilView(moteur: moteur)
                    case .commande: CommandeView(moteur: moteur)
                    case .scan:     ScanView(moteur: moteur)
                    case .cadrage:  CadrageView(moteur: moteur)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .environment(\.echelle, echelle)
            .animation(.easeInOut(duration: 0.22), value: moteur.ecran)
        }
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
            moteur.demarrer()
            // Vérification SILENCIEUSE, quelques secondes après le démarrage
            // (le moteur passe d'abord) : en cas de nouveauté, une simple
            // pastille rouge apparaît sur la roue dentée. Aucune fenêtre ne
            // s'impose, aucun message si Internet manque.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MiseAJour.partagee.verifier(silencieux: true)
            }
        }
        .onDisappear { moteur.arreter() }
    }
}

// MARK: - barre du haut (écrans autres que l'accueil)

struct BarreHaut: View {
    @ObservedObject var moteur: Moteur
    let titre: String
    var sousTitre: String? = nil
    var retour: (() -> Void)? = nil
    var libelleRetour: String = "Retour"
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 14 * echelle) {
            if let retour {
                Button(action: retour) {
                    HStack(spacing: 5 * echelle) {
                        Image(systemName: "chevron.left").police(12, .black)
                        Text(libelleRetour).police(13, .bold, .rounded)
                    }
                }
                .buttonStyle(BoutonDiscret())
            }
            LogoMarque(taille: 34 * echelle)
            VStack(alignment: .leading, spacing: 1 * echelle) {
                Text(titre)
                    .police(18, .black, .rounded)
                    .foregroundColor(MMD.noir)
                    .lineLimit(1)
                if let sousTitre {
                    Text(sousTitre).police(11.5, .medium)
                        .foregroundColor(MMD.gris).lineLimit(1)
                }
            }
            Spacer(minLength: 8 * echelle)
            PastilleConnexion(moteur: moteur)
        }
        .padding(.horizontal, 22 * echelle)
        .padding(.top, 16 * echelle).padding(.bottom, 12 * echelle)
        .background(MMD.creme)
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)
    }
}

/// État du capteur + choix du port série.
struct PastilleConnexion: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        Menu {
            if moteur.ports.isEmpty {
                Text("Aucun port détecté — branche le capteur en USB.")
            }
            ForEach(moteur.ports) { p in
                Button {
                    moteur.choisirPort(p.device)
                } label: {
                    Label(p.nom, systemImage: p.device == moteur.portActif
                          ? "checkmark.circle.fill" : "cable.connector")
                }
            }
            Divider()
            Button("Rechercher les capteurs") { moteur.rafraichirPorts() }
        } label: {
            HStack(spacing: 7 * echelle) {
                Circle().fill(couleur).frame(width: 8 * echelle, height: 8 * echelle)
                Text(texte).police(12, .bold, .rounded)
                    .foregroundColor(MMD.noir)
            }
            .padding(.horizontal, 12 * echelle).padding(.vertical, 7 * echelle)
            .background(Capsule().fill(Color.white)
                .overlay(Capsule().strokeBorder(MMD.noir.opacity(0.2),
                                                lineWidth: 1.3 * echelle)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var couleur: Color {
        moteur.capteurPret ? MMD.bleu : (moteur.connecte ? MMD.rouge : MMD.gris.opacity(0.5))
    }
    private var texte: String {
        moteur.capteurPret ? "Capteur prêt" : (moteur.connecte ? "Connecté" : "Pas de capteur")
    }
}

/// Bandeau d'information / erreur en bas d'écran.
struct BarreStatut: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 8 * echelle) {
            if let err = moteur.erreur {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(MMD.rouge).police(12)
                Text(err).foregroundColor(MMD.rouge)
            } else {
                Circle().fill(MMD.noir.opacity(0.25))
                    .frame(width: 5 * echelle, height: 5 * echelle)
                Text(moteur.statut).foregroundColor(MMD.gris)
            }
            Spacer(minLength: 0)
        }
        .police(12, .medium).lineLimit(2)
        .padding(.horizontal, 24 * echelle).padding(.vertical, 11 * echelle)
        .background(Color.white)
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .top)
    }
}

// MARK: - capture souris + molette (AppKit)

/// Couche transparente qui capte le glissement (déplacer), la molette
/// (zoomer) et la molette + Option (faire tourner).
struct ZoneInteraction: NSViewRepresentable {
    var onPan: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onZoom: (CGFloat) -> Void = { _ in }
    var onRotation: ((CGFloat) -> Void)? = nil      // molette + Option
    var onFin: (() -> Void)? = nil
    var main: Bool = false                          // curseur « main »

    func makeNSView(context: Context) -> VueInteraction {
        let v = VueInteraction()
        appliquer(v)
        return v
    }
    func updateNSView(_ v: VueInteraction, context: Context) { appliquer(v) }

    private func appliquer(_ v: VueInteraction) {
        v.onPan = onPan; v.onZoom = onZoom; v.onRotation = onRotation
        v.onFin = onFin; v.main = main
        v.window?.invalidateCursorRects(for: v)
    }

    final class VueInteraction: NSView {
        var onPan: ((CGFloat, CGFloat) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        var onRotation: ((CGFloat) -> Void)?
        var onFin: (() -> Void)?
        var main = false
        private var dernier: NSPoint?

        override func scrollWheel(with e: NSEvent) {
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 3
            if e.modifierFlags.contains(.option), let onRotation {
                onRotation(d)
            } else {
                onZoom?(d)
            }
        }
        override func mouseDown(with e: NSEvent) {
            dernier = convert(e.locationInWindow, from: nil)
        }
        override func mouseDragged(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            if let l = dernier {
                onPan?(p.x - l.x, -(p.y - l.y))   // AppKit : y monte, SwiftUI : y descend
            }
            dernier = p
        }
        override func mouseUp(with e: NSEvent) { dernier = nil; onFin?() }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() {
            if main { addCursorRect(bounds, cursor: .openHand) }
        }
    }
}

// MARK: - petites animations

/// Le compte à rebours 3… 2… 1…
struct PulseNombre: View {
    let valeur: Int
    @State private var grossi = false
    var body: some View {
        Text("\(valeur)")
            .police(120, .black, .rounded)
            .foregroundColor(.white)
            .scaleEffect(grossi ? 1.0 : 0.6).opacity(grossi ? 1 : 0.2).id(valeur)
            .onAppear {
                grossi = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { grossi = true }
            }
    }
}

/// Le doigt lumineux pendant la lecture du capteur.
struct DoigtAnime: View {
    var couleur: Color = .white
    var taille: CGFloat = 74
    @State private var anim = false
    var body: some View {
        Image(systemName: "hand.point.up.braille.fill")
            .police(taille, .regular)
            .foregroundColor(couleur)
            .scaleEffect(anim ? 1.07 : 0.93)
            .opacity(anim ? 1 : 0.75)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    anim = true
                }
            }
    }
}

/// Apparition douce des cartes (léger ressort, décalé selon la position).
struct Apparition: ViewModifier {
    let rang: Int
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.96)
            .offset(y: visible ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)
                    .delay(Double(min(rang, 12)) * 0.035)) { visible = true }
            }
    }
}

extension View {
    func apparition(_ rang: Int) -> some View { modifier(Apparition(rang: rang)) }
}
