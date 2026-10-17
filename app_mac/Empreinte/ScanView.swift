import SwiftUI
import AppKit

// =========================================================================
// SCAN : on pose le doigt sur le capteur, il déclenche tout seul. Le bouton
// n'est qu'un secours. La mosaïque grandit pose après pose, et la bande de
// droite garde la trace de chaque pose.
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
                        ? "Pose le doigt sur le capteur : le scan démarre tout seul"
                        : "\(Libelle.pluriel(moteur.poses, "pose")) assemblée\(moteur.poses > 1 ? "s" : "") — repose le doigt pour compléter",
                      retour: { moteur.annulerEmpreinte() },
                      libelleRetour: "Commande")
            HStack(alignment: .top, spacing: 18 * echelle) {
                zone
                colonne.frame(width: 250 * echelle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle)
            controles
            PiedStatut(moteur: moteur)
        }
    }

    // MARK: la grande zone centrale

    private var zone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous).fill(MMD.blanc)
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
                    if zoom != 1 || glisse != .zero {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { zoom = 1; glisse = .zero }
                            } label: {
                                HStack(spacing: 5 * echelle) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").police(10.5, .bold)
                                    Text("Vue d'ensemble")
                                }
                            }
                            .buttonStyle(BoutonSecondaire())
                        }
                    }
                }
                .padding(14 * echelle)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
            .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.05), radius: 14 * echelle, y: 5 * echelle)
        .animation(.easeInOut(duration: 0.3), value: moteur.apercu)
        .animation(.easeInOut(duration: 0.2), value: moteur.phase)
    }

    private var mosaique: some View {
        ZStack {
            if let img = moteur.apercu {
                Image(nsImage: img).resizable().interpolation(.high)
                    .scaledToFit().padding(26 * echelle)
                    .scaleEffect(zoom).offset(glisse)
            }
            ZoneInteraction(
                onPan: { dx, dy in glisse.width += dx; glisse.height += dy },
                onZoom: { d in zoom = max(0.5, min(6, zoom * (1 + d * 0.005))) },
                onDoubleClic: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    zoom = 1; glisse = .zero } },
                main: true)
        }
    }

    private var badgePoses: some View {
        HStack(spacing: 6 * echelle) {
            Image(systemName: "square.stack.3d.up.fill").police(10, .black)
            Text(Libelle.pluriel(moteur.poses, "pose")).police(12, .heavy)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12 * echelle).padding(.vertical, 7 * echelle)
        .background(Capsule().fill(MMD.encre))
    }

    /// Rappel discret : le capteur reste actif, on peut reposer le doigt.
    private var rappelDoigt: some View {
        HStack(spacing: 8 * echelle) {
            DoigtAnime(couleur: MMD.drageeFonce, taille: 15)
            Text("Repose ton doigt, un peu décalé").police(12, .bold)
                .foregroundColor(MMD.encre)
        }
        .padding(.horizontal, 12 * echelle).padding(.vertical, 7 * echelle)
        .background(Capsule().fill(MMD.drageeClair)
            .overlay(Capsule().strokeBorder(MMD.dragee, lineWidth: 1.2 * echelle)))
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
                        .police(17, .heavy)
                        .foregroundColor(.white)
                    Text("Lecture en cours…").police(12.5, .semibold).foregroundColor(.white.opacity(0.75))
                }
            }
        case .travail:
            ZStack {
                MMD.blanc.opacity(0.92)
                Chargement(texte: moteur.statut, taille: 64)
            }
        default:
            EmptyView()
        }
    }

    private func voile<C: View>(@ViewBuilder _ contenu: () -> C) -> some View {
        ZStack { MMD.encre.opacity(0.62); contenu() }.transition(.opacity)
    }

    // MARK: colonne de droite : poses faites + explication

    private var colonne: some View {
        VStack(alignment: .leading, spacing: 14 * echelle) {
            VStack(alignment: .leading, spacing: 10 * echelle) {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "square.stack.3d.up").police(11, .bold).foregroundColor(MMD.gris)
                    TitreSection(texte: "Les poses")
                    Spacer()
                    if moteur.poses > 0 {
                        Etiquette(texte: "\(moteur.poses)", fond: MMD.encre, couleur: .white)
                    }
                }
                if moteur.historiquePoses.isEmpty {
                    HStack(spacing: 10 * echelle) {
                        placeholderPose(numero: 1, prochaine: true)
                        Text("La première pose apparaîtra ici.")
                            .police(11.5, .medium).foregroundColor(MMD.gris)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56 * echelle, maximum: 70 * echelle),
                                                 spacing: 8 * echelle)], spacing: 8 * echelle) {
                        ForEach(Array(moteur.historiquePoses.enumerated()), id: \.offset) { i, img in
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: img).resizable().interpolation(.medium).scaledToFit()
                                    .padding(4 * echelle)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .background(RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous).fill(MMD.blanc))
                                    .overlay(RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous)
                                        .strokeBorder(i == moteur.historiquePoses.count - 1 ? MMD.encre.opacity(0.5) : MMD.trait,
                                                      lineWidth: 1.2 * echelle))
                                Text("\(i + 1)").police(9.5, .heavy).foregroundColor(.white)
                                    .frame(width: 17 * echelle, height: 17 * echelle)
                                    .background(Circle().fill(MMD.encre))
                                    .offset(x: 4 * echelle, y: 4 * echelle)
                            }
                            .apparition(i)
                        }
                        if !moteur.occupe { placeholderPose(numero: moteur.historiquePoses.count + 1, prochaine: true) }
                    }
                }
            }
            .padding(14 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, ombre: false)

            VStack(alignment: .leading, spacing: 8 * echelle) {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "lightbulb").police(11, .bold).foregroundColor(MMD.doreFonce)
                    TitreSection(texte: "Comment ça marche")
                }
                Text("Chaque pose complète la précédente : l'empreinte s'assemble comme un puzzle. " +
                     "S'il reste une tache ou un trou, repose le doigt dessus, à peine décalé. " +
                     "Trois à cinq poses suffisent en général.")
                    .police(11.5, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, fond: MMD.doreClair.opacity(0.35), cerne: MMD.dore.opacity(0.3), ombre: false)

            etatCapteur
            Spacer(minLength: 0)
        }
    }

    private func placeholderPose(numero: Int, prochaine: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous)
                .strokeBorder(MMD.encre.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.2 * echelle, dash: [4 * echelle, 3 * echelle]))
            Image(systemName: "hand.point.up.left").police(16, .light).foregroundColor(MMD.grisClair)
        }
        .frame(width: 56 * echelle, height: 56 * echelle)
    }

    private var etatCapteur: some View {
        HStack(spacing: 9 * echelle) {
            Circle().fill(moteur.connecte ? (moteur.occupe ? MMD.dore : MMD.vert) : MMD.grisClair)
                .frame(width: 9 * echelle, height: 9 * echelle)
            Text(!moteur.connecte ? "Capteur non connecté"
                 : (moteur.occupe ? "Lecture en cours…" : "Capteur à l'écoute"))
                .police(12, .bold).foregroundColor(MMD.encre)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14 * echelle).padding(.vertical, 10 * echelle)
        .carte(rayon: 14, ombre: false)
    }

    // MARK: boutons du bas

    private var controles: some View {
        HStack(spacing: 8 * echelle) {
            Button { moteur.annulerEmpreinte() } label: {
                Text("Annuler")
            }
            .buttonStyle(BoutonDiscret())
            .disabled(moteur.occupe)

            Button { moteur.recommencer() } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "arrow.counterclockwise").police(11.5, .bold)
                    Text("Repartir de zéro")
                }
            }
            .buttonStyle(BoutonDiscret())
            .disabled(moteur.poses == 0 || moteur.occupe)

            Button { moteur.nouveauScan() } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "touchid").police(12.5, .bold)
                    Text("Scanner manuellement")
                    Etiquette(texte: "espace", fond: MMD.voile, couleur: MMD.gris)
                }
            }
            .buttonStyle(BoutonSecondaire())
            .disabled(!moteur.connecte || moteur.occupe)
            .keyboardShortcut(.space, modifiers: [])
            .help("Si le capteur ne déclenche pas tout seul (espace)")

            Spacer()

            Button { moteur.ouvrirCadrage() } label: {
                HStack(spacing: 8 * echelle) {
                    Image(systemName: "checkmark").police(12.5, .heavy)
                    Text("C'est bon, ajuster le cadre")
                    Image(systemName: "arrow.right").police(12.5, .heavy)
                }
            }
            .buttonStyle(BoutonPrincipal(actif: moteur.poses > 0 && !moteur.occupe, grand: true))
            .disabled(moteur.poses == 0 || moteur.occupe)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24 * echelle).padding(.vertical, 14 * echelle)
    }
}

// MARK: - l'invitation à poser le doigt

/// Grande zone douce qui respire : c'est le capteur qui déclenche le scan.
struct InvitationDoigt: View {
    let prenom: String
    let actif: Bool
    @State private var pulse = false
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique

    var body: some View {
        VStack(spacing: 22 * echelle) {
            ZStack {
                Circle().fill(MMD.dragee.opacity(0.18))
                    .frame(width: 230 * echelle, height: 230 * echelle)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                Circle().fill(MMD.rose.opacity(0.16))
                    .frame(width: 176 * echelle, height: 176 * echelle)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                Circle().strokeBorder(MMD.encre.opacity(0.14), lineWidth: 2 * echelle)
                    .frame(width: 150 * echelle, height: 150 * echelle)
                    .scaleEffect(pulse ? 1.03 : 0.97)
                Image(systemName: "touchid")
                    .police(84, .ultraLight)
                    .foregroundColor(actif ? MMD.encre : MMD.grisClair)
                    .scaleEffect(pulse ? 1.03 : 0.97)
                    .offset(y: pulse ? -2 * echelle : 2 * echelle)
            }
            VStack(spacing: 7 * echelle) {
                Text(actif ? "Pose ton doigt sur le capteur"
                           : "Branche le capteur pour commencer")
                    .police(22, .heavy)
                    .foregroundColor(MMD.encre)
                Text(prenom.isEmpty
                     ? "Le scan démarre tout seul."
                     : "Empreinte de \(prenom) — le scan démarre tout seul, bien à plat.")
                    .police(13, .medium)
                    .foregroundColor(MMD.gris)
                Text("Puis décale un peu le doigt à chaque pose : l'empreinte s'agrandit.")
                    .police(12, .medium)
                    .foregroundColor(MMD.gris.opacity(0.8))
                    .padding(.top, 2 * echelle)
            }
            .multilineTextAlignment(.center)
        }
        .onAppear {
            guard !statique else { pulse = true; return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
