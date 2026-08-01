import SwiftUI
import AppKit

// =========================================================================
// SCAN : on pose le doigt sur le capteur, il déclenche tout seul. Le bouton
// n'est qu'un secours. La mosaïque grandit pose après pose.
// =========================================================================

struct ScanView: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    @State private var zoom: CGFloat = 1
    @State private var glisse: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            BarreHaut(moteur: moteur,
                      titre: "Empreinte de \(moteur.personneEnCours)",
                      sousTitre: moteur.poses == 0
                        ? "Pose le doigt sur le capteur pour démarrer"
                        : "\(moteur.poses) pose\(moteur.poses > 1 ? "s" : "") assemblée\(moteur.poses > 1 ? "s" : "")",
                      retour: { moteur.annulerEmpreinte() },
                      libelleRetour: "Commande")
            zone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20 * echelle)
            controles
            BarreStatut(moteur: moteur)
        }
    }

    // MARK: la grande zone centrale

    private var zone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22 * echelle, style: .continuous).fill(Color.white)
            if moteur.apercu != nil {
                mosaique
            } else {
                InvitationDoigt(prenom: moteur.personneEnCours,
                                actif: moteur.connecte && !moteur.occupe)
            }
            surcouche
            if moteur.poses > 0 {
                VStack {
                    HStack {
                        badgePoses
                        Spacer()
                        if moteur.apercu != nil && !moteur.occupe { rappelDoigt }
                    }
                    Spacer()
                }
                .padding(16 * echelle)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22 * echelle, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22 * echelle, style: .continuous)
            .strokeBorder(MMD.trait, lineWidth: 1.4 * echelle))
        .animation(.easeInOut(duration: 0.3), value: moteur.apercu)
        .animation(.easeInOut(duration: 0.2), value: moteur.phase)
    }

    private var mosaique: some View {
        ZStack {
            if let img = moteur.apercu {
                Image(nsImage: img).resizable().interpolation(.high)
                    .scaledToFit().padding(24 * echelle)
                    .scaleEffect(zoom).offset(glisse)
            }
            ZoneInteraction(
                onPan: { dx, dy in glisse.width += dx; glisse.height += dy },
                onZoom: { d in zoom = max(0.5, min(6, zoom * (1 + d * 0.005))) },
                main: true)
        }
    }

    private var badgePoses: some View {
        HStack(spacing: 6 * echelle) {
            Image(systemName: "square.stack.3d.up.fill").police(10, .black)
            Text("\(moteur.poses) pose\(moteur.poses > 1 ? "s" : "")")
                .police(12, .black, .rounded)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12 * echelle).padding(.vertical, 7 * echelle)
        .background(Capsule().fill(MMD.noir))
    }

    /// Rappel discret : le capteur reste actif, on peut reposer le doigt.
    private var rappelDoigt: some View {
        HStack(spacing: 8 * echelle) {
            DoigtAnime(couleur: MMD.bleu, taille: 15)
            Text("Repose ton doigt, un peu décalé")
                .police(12, .bold, .rounded)
                .foregroundColor(MMD.noir)
        }
        .padding(.horizontal, 12 * echelle).padding(.vertical, 7 * echelle)
        .background(Capsule().fill(Color.white)
            .overlay(Capsule().strokeBorder(MMD.noir.opacity(0.18), lineWidth: 1.2 * echelle)))
    }

    @ViewBuilder private var surcouche: some View {
        switch moteur.phase {
        case .compteRebours:
            voile { PulseNombre(valeur: moteur.compte) }
        case .scan:
            voile {
                VStack(spacing: 16 * echelle) {
                    DoigtAnime()
                    Text("Garde le doigt bien appuyé")
                        .police(15, .black, .rounded)
                        .foregroundColor(.white)
                }
            }
        case .travail:
            ZStack {
                Color.white.opacity(0.9)
                Chargement(texte: moteur.statut, taille: 60)
            }
        default:
            EmptyView()
        }
    }

    private func voile<C: View>(@ViewBuilder _ contenu: () -> C) -> some View {
        ZStack { MMD.noir.opacity(0.55); contenu() }.transition(.opacity)
    }

    // MARK: boutons du bas

    private var controles: some View {
        HStack(spacing: 10 * echelle) {
            Button { moteur.annulerEmpreinte() } label: {
                Text("Annuler").police(13, .bold, .rounded)
            }
            .buttonStyle(BoutonDiscret())
            .disabled(moteur.occupe)

            Button { moteur.recommencer() } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "arrow.counterclockwise").police(11.5, .bold)
                    Text("Repartir de zéro").police(12.5, .bold, .rounded)
                }
            }
            .buttonStyle(BoutonDiscret())
            .disabled(moteur.poses == 0 || moteur.occupe)

            Button { moteur.nouveauScan() } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "touchid").police(12.5, .bold)
                    Text("Scanner manuellement")
                        .police(12.5, .bold, .rounded)
                }
            }
            .buttonStyle(BoutonSecondaire())
            .disabled(!moteur.connecte || moteur.occupe)
            .keyboardShortcut(.space, modifiers: [])
            .help("Si le capteur ne déclenche pas tout seul")

            Spacer()

            Button { moteur.ouvrirCadrage() } label: {
                HStack(spacing: 8 * echelle) {
                    Text("Terminer → ajuster le cadre")
                        .police(14, .black, .rounded)
                    Image(systemName: "arrow.right").police(12.5, .black)
                }
            }
            .buttonStyle(BoutonPrincipal(actif: moteur.poses > 0 && !moteur.occupe))
            .disabled(moteur.poses == 0 || moteur.occupe)
        }
        .padding(.horizontal, 22 * echelle).padding(.bottom, 14 * echelle)
    }
}

// MARK: - l'invitation à poser le doigt

/// Grande zone douce qui respire : c'est le capteur qui déclenche le scan.
struct InvitationDoigt: View {
    let prenom: String
    let actif: Bool
    @State private var pulse = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(spacing: 20 * echelle) {
            ZStack {
                Circle().fill(MMD.bleu.opacity(0.07))
                    .frame(width: 210 * echelle, height: 210 * echelle)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                Circle().strokeBorder(MMD.noir.opacity(0.12), lineWidth: 2 * echelle)
                    .frame(width: 168 * echelle, height: 168 * echelle)
                    .scaleEffect(pulse ? 1.04 : 0.96)
                Image(systemName: "touchid")
                    .police(86, .ultraLight)
                    .foregroundColor(actif ? MMD.noir : MMD.gris.opacity(0.5))
                    .scaleEffect(pulse ? 1.03 : 0.97)
            }
            VStack(spacing: 6 * echelle) {
                Text(actif ? "Pose ton doigt sur le capteur"
                           : "Branche le capteur pour commencer")
                    .police(20, .black, .rounded)
                    .foregroundColor(MMD.noir)
                Text(prenom.isEmpty
                     ? "Le scan démarre tout seul."
                     : "Empreinte de \(prenom) — le scan démarre tout seul.")
                    .police(13, .medium)
                    .foregroundColor(MMD.gris)
                Text("Décale un peu le doigt à chaque pose : l'empreinte s'agrandit.")
                    .police(12)
                    .foregroundColor(MMD.gris.opacity(0.8))
                    .padding(.top, 2 * echelle)
            }
            .multilineTextAlignment(.center)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
