import SwiftUI
import AppKit

// =========================================================================
// Aiguillage entre les quatre écrans + éléments communs (barre du haut,
// pastille de connexion, pied de statut, toast d'erreur, capture souris,
// feuille de saisie d'un nom).
// =========================================================================

struct ContentView: View {
    @StateObject private var moteur = Moteur()

    var body: some View {
        Racine(moteur: moteur)
            .frame(minWidth: 1000, minHeight: 680)
            .onAppear {
                moteur.demarrer()
                // Vérification SILENCIEUSE, quelques secondes après le
                // démarrage (le moteur passe d'abord) : en cas de nouveauté,
                // une simple pastille apparaît sur la roue dentée. Aucune
                // fenêtre ne s'impose, aucun message si Internet manque.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    MiseAJour.partagee.verifier(silencieux: true)
                }
            }
            .onDisappear { moteur.arreter() }
    }
}

/// La racine commune à l'app et au mode captures : calcule l'échelle, pose
/// le papier crème, affiche l'écran courant et le toast d'erreur.
struct Racine: View {
    @ObservedObject var moteur: Moteur

    var body: some View {
        // Toute l'interface grandit avec la fenêtre : une seule échelle est
        // calculée ici, puis lue partout via `@Environment(\.echelle)`.
        GeometryReader { geo in
            let echelle = Echelle.pour(geo.size)
            ZStack(alignment: .bottom) {
                Papier().ignoresSafeArea()
                Group {
                    switch moteur.ecran {
                    case .accueil:  AccueilView(moteur: moteur)
                    case .commande: CommandeView(moteur: moteur)
                    case .scan:     ScanView(moteur: moteur)
                    case .cadrage:  CadrageView(moteur: moteur)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 14 * echelle)),
                    removal: .opacity))

                if let err = moteur.erreur {
                    Toast(texte: err)
                        .padding(.bottom, 52 * echelle)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .environment(\.echelle, echelle)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: moteur.ecran)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: moteur.erreur)
        }
        .preferredColorScheme(.light)
    }
}

/// Le papier crème, à peine nuancé (un voile plus clair en haut à gauche,
/// une pointe de rose en bas à droite) : chaleureux sans jamais se voir.
struct Papier: View {
    var body: some View {
        ZStack {
            MMD.creme
            RadialGradient(colors: [Color.white.opacity(0.55), Color.clear],
                           center: .topLeading, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [MMD.rose.opacity(0.10), Color.clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 700)
        }
    }
}

// MARK: - barre du haut (écrans autres que l'accueil)

struct BarreHaut: View {
    @ObservedObject var moteur: Moteur
    let titre: String
    var sousTitre: String? = nil
    var retour: (() -> Void)? = nil
    var libelleRetour: String = "Retour"
    var accessoire: AnyView? = nil
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 14 * echelle) {
            if let retour {
                Button(action: retour) {
                    HStack(spacing: 5 * echelle) {
                        Image(systemName: "chevron.left").police(12, .heavy)
                        Text(libelleRetour)
                    }
                }
                .buttonStyle(BoutonDiscret())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Retour (Échap)")
            }
            Logo(taille: 36)
            VStack(alignment: .leading, spacing: 1 * echelle) {
                Text(titre)
                    .police(19, .heavy)
                    .foregroundColor(MMD.encre)
                    .lineLimit(1)
                if let sousTitre {
                    Text(sousTitre).police(11.5, .medium)
                        .foregroundColor(MMD.gris).lineLimit(1)
                }
            }
            Spacer(minLength: 8 * echelle)
            if let accessoire { accessoire }
            PastilleConnexion(moteur: moteur)
        }
        .padding(.horizontal, 24 * echelle)
        .padding(.top, 16 * echelle).padding(.bottom, 12 * echelle)
    }
}

/// État du capteur, en un coup d'œil ; un clic ouvre le choix du port.
struct PastilleConnexion: View {
    @ObservedObject var moteur: Moteur
    @State private var ouvert = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button { ouvert.toggle() } label: {
            HStack(spacing: 7 * echelle) {
                ZStack {
                    Circle().fill(couleur.opacity(0.25))
                        .frame(width: 14 * echelle, height: 14 * echelle)
                    Circle().fill(couleur)
                        .frame(width: 8 * echelle, height: 8 * echelle)
                }
                Text(moteur.etatCapteur).police(12, .bold)
                    .foregroundColor(MMD.encre)
            }
            .padding(.leading, 9 * echelle).padding(.trailing, 13 * echelle)
            .padding(.vertical, 7 * echelle)
        }
        .buttonStyle(BoutonCapsule())
        .help("Capteur : \(moteur.portActif ?? "aucun port")")
        .popover(isPresented: $ouvert, arrowEdge: .bottom) {
            PanneauCapteur(moteur: moteur)
                .environment(\.echelle, echelle)
        }
    }

    private var couleur: Color {
        moteur.capteurPret ? MMD.vert : (moteur.connecte ? MMD.dore : MMD.grisClair)
    }
}

/// Bouton capsule blanc cerné (pastilles de la barre du haut).
struct BoutonCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration)
    }
    private struct Corps: View {
        let configuration: Configuration
        @Environment(\.echelle) private var echelle
        @State private var survol = false
        var body: some View {
            configuration.label
                .background(Capsule().fill(survol ? MMD.voile : MMD.blanc)
                    .overlay(Capsule().strokeBorder(MMD.encre.opacity(0.16),
                                                    lineWidth: 1.2 * echelle)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: survol)
                .onHover { survol = $0 }
        }
    }
}

/// Le contenu du popover « capteur » : état, ports, recherche.
struct PanneauCapteur: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * echelle) {
            HStack(spacing: 8 * echelle) {
                Image(systemName: "sensor").police(14, .bold).foregroundColor(MMD.encre)
                Text("Capteur d'empreintes").police(14, .heavy).foregroundColor(MMD.encre)
            }
            Text(moteur.capteurPret ? "Prêt : pose un doigt pour scanner."
                 : (moteur.connecte ? "Connecté, capteur non confirmé — tu peux essayer."
                    : "Aucun capteur détecté. Branche-le en USB."))
                .police(12, .medium).foregroundColor(MMD.gris)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2 * echelle)
            TitreSection(texte: "Ports")
            if moteur.ports.isEmpty {
                Text("Aucun port détecté.").police(12).foregroundColor(MMD.gris)
            }
            ForEach(moteur.ports) { p in
                Button { moteur.choisirPort(p.device) } label: {
                    HStack(spacing: 8 * echelle) {
                        Image(systemName: p.device == moteur.portActif
                              ? "checkmark.circle.fill" : (p.typique ? "cable.connector" : "circle.dotted"))
                            .police(12, .bold)
                            .foregroundColor(p.device == moteur.portActif ? MMD.vert : MMD.gris)
                        Text(p.nom).police(12.5, .semibold).foregroundColor(MMD.encre)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BoutonDiscret())
            }
            Button {
                moteur.rafraichirPorts()
            } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "arrow.clockwise").police(11, .bold)
                    Text("Rechercher les capteurs")
                }
            }
            .buttonStyle(BoutonSecondaire())
            .padding(.top, 4 * echelle)
        }
        .padding(18 * echelle)
        .frame(width: 300 * echelle)
        .background(MMD.creme)
    }
}

// MARK: - pied de statut et toast

/// Fine ligne d'état en bas de fenêtre : ce que fait l'app, en mots simples.
struct PiedStatut: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 9 * echelle) {
            if moteur.occupe || moteur.apercuEnCours || moteur.composeEnCours
                || moteur.exportEnCours || moteur.chargementListe {
                Logo(taille: 15, tourne: true, encre: MMD.gris, drapeau: false)
            } else {
                Circle().fill(MMD.encre.opacity(0.22))
                    .frame(width: 5 * echelle, height: 5 * echelle)
            }
            Text(moteur.statut).police(11.5, .medium).foregroundColor(MMD.gris)
                .lineLimit(1)
            Spacer(minLength: 0)
            Tricolore(largeur: 30, hauteur: 2.5).opacity(0.8)
        }
        .padding(.horizontal, 24 * echelle).padding(.vertical, 9 * echelle)
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .top)
    }
}

/// Message d'erreur posé en bas, qui s'efface tout seul (Moteur.signaler).
struct Toast: View {
    let texte: String
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 10 * echelle) {
            Image(systemName: "exclamationmark.circle.fill")
                .police(15, .bold).foregroundColor(MMD.rouge)
            Text(texte).police(12.5, .semibold).foregroundColor(MMD.encre)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16 * echelle).padding(.vertical, 12 * echelle)
        .frame(maxWidth: 520 * echelle)
        .background(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous)
            .fill(MMD.roseClair)
            .overlay(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous)
                .strokeBorder(MMD.rose, lineWidth: 1.2 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.12), radius: 16 * echelle, y: 6 * echelle)
    }
}

// MARK: - feuille « donne-moi un nom »

/// Petite feuille pour saisir un nom (client, prénom) : gros champ, deux
/// boutons, Entrée pour valider, Échap pour annuler.
struct FeuilleNom: View {
    let titre: String
    let explication: String
    let invite: String
    var libelleValider: String = "Créer"
    var symbole: String = "plus"
    var defaut: String = ""
    let valider: (String) -> Void
    @Environment(\.dismiss) private var fermer
    @Environment(\.echelle) private var echelle
    @State private var texte = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * echelle) {
            HStack(spacing: 12 * echelle) {
                Logo(taille: 40)
                VStack(alignment: .leading, spacing: 2 * echelle) {
                    Text(titre).police(19, .heavy).foregroundColor(MMD.encre)
                    Text(explication).police(12.5, .medium).foregroundColor(MMD.gris)
                }
            }
            ChampTexte(invite: invite, texte: $texte, grand: true, auFocus: true) { confirmer() }
            HStack {
                Spacer()
                Button("Annuler") { fermer() }
                    .buttonStyle(BoutonSecondaire())
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirmer()
                } label: {
                    HStack(spacing: 7 * echelle) {
                        Image(systemName: symbole).police(12, .heavy)
                        Text(libelleValider)
                    }
                }
                .buttonStyle(BoutonPrincipal())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26 * echelle)
        .frame(width: 440 * echelle)
        .background(Papier())
        .onAppear { texte = defaut }
    }

    private func confirmer() {
        let n = Moteur.nettoyer(texte)
        fermer()
        valider(n)
    }
}

// MARK: - capture souris + molette (AppKit)

/// Couche transparente qui capte le glissement (déplacer), la molette
/// (zoomer), la molette + Option (faire tourner) et le double-clic.
/// En capture (ImageRenderer ne sait pas dessiner une vue AppKit et met un
/// gros « interdit » à la place), elle s'efface.
struct ZoneInteraction: View {
    var onPan: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onZoom: (CGFloat) -> Void = { _ in }
    var onRotation: ((CGFloat) -> Void)? = nil      // molette + Option
    var onFin: (() -> Void)? = nil
    var onDoubleClic: (() -> Void)? = nil
    var main: Bool = false                          // curseur « main »
    @Environment(\.statique) private var statique

    var body: some View {
        if statique {
            Color.clear
        } else {
            CoucheInteraction(onPan: onPan, onZoom: onZoom, onRotation: onRotation,
                              onFin: onFin, onDoubleClic: onDoubleClic, main: main)
        }
    }
}

struct CoucheInteraction: NSViewRepresentable {
    var onPan: (CGFloat, CGFloat) -> Void
    var onZoom: (CGFloat) -> Void
    var onRotation: ((CGFloat) -> Void)?
    var onFin: (() -> Void)?
    var onDoubleClic: (() -> Void)?
    var main: Bool

    func makeNSView(context: Context) -> VueInteraction {
        let v = VueInteraction()
        appliquer(v)
        return v
    }
    func updateNSView(_ v: VueInteraction, context: Context) { appliquer(v) }

    private func appliquer(_ v: VueInteraction) {
        v.onPan = onPan; v.onZoom = onZoom; v.onRotation = onRotation
        v.onFin = onFin; v.onDoubleClic = onDoubleClic; v.main = main
        v.window?.invalidateCursorRects(for: v)
    }

    final class VueInteraction: NSView {
        var onPan: ((CGFloat, CGFloat) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        var onRotation: ((CGFloat) -> Void)?
        var onFin: (() -> Void)?
        var onDoubleClic: (() -> Void)?
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
        override func magnify(with e: NSEvent) {          // pincement trackpad
            onZoom?(e.magnification * 200)
        }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { onDoubleClic?(); dernier = nil; return }
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
            .police(120, .black)
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
