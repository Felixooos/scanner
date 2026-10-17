import SwiftUI
import AppKit

// =========================================================================
// CADRAGE : l'ovale ne bouge pas, on déplace et on zoome l'empreinte
// dessous jusqu'à ce qu'elle soit bien placée.
// =========================================================================

struct CadrageView: View {
    @ObservedObject var moteur: Moteur

    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var completer = true
    @State private var geoSize: CGSize = .zero
    @State private var presetFait = false
    @Environment(\.echelle) private var echelle

    private var aspect: CGFloat {
        guard let s = moteur.apercu?.size, s.height > 0 else { return 0.85 }
        return s.width / s.height
    }
    private let ratioOvale: CGFloat = 0.80          // largeur/hauteur de l'ovale

    var body: some View {
        VStack(spacing: 0) {
            BarreHaut(moteur: moteur,
                      titre: "Ajuste le cadre",
                      sousTitre: "Empreinte de \(moteur.personneEnCours) — " +
                                 "glisse pour déplacer, molette pour zoomer",
                      retour: { revenir() },
                      libelleRetour: moteur.recadrage ? "Commande" : "Scan")
            HStack(alignment: .top, spacing: 18 * echelle) {
                editeur
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                colonne.frame(width: 250 * echelle)
            }
            .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle)
            controles
            PiedStatut(moteur: moteur)
        }
    }

    private var editeur: some View {
        GeometryReader { geo in
            let V = min(geo.size.width, geo.size.height)
            let Dw = aspect >= 1 ? V : V * aspect
            let Dh = aspect >= 1 ? V / aspect : V
            let ovRy = 0.46 * V
            let ovRx = ovRy * ratioOvale
            ZStack {
                RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                    .fill(MMD.encre)
                if let img = moteur.apercu {
                    Image(nsImage: img).resizable()
                        .frame(width: Dw, height: Dh)
                        .scaleEffect(zoom)
                        .offset(offset)
                }
                // assombrit l'extérieur de l'ovale
                Rectangle().fill(MMD.encre.opacity(0.6))
                    .overlay(Ellipse().frame(width: 2 * ovRx, height: 2 * ovRy)
                        .blendMode(.destinationOut))
                    .compositingGroup()
                Ellipse().stroke(Color.white, lineWidth: 2.5 * echelle)
                    .frame(width: 2 * ovRx, height: 2 * ovRy)
                Ellipse().stroke(MMD.rose.opacity(0.95), lineWidth: 1.2 * echelle)
                    .frame(width: 2 * ovRx + 6 * echelle, height: 2 * ovRy + 6 * echelle)
                // repères du centre (discrets)
                Group {
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: 14 * echelle, height: 1.2 * echelle)
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: 1.2 * echelle, height: 14 * echelle)
                }
                // capture souris (déplacer) + molette (zoomer) + double-clic (recentrer)
                ZoneInteraction(
                    onPan: { dx, dy in offset.width += dx; offset.height += dy },
                    onZoom: { d in zoom = max(0.25, min(6, zoom * (1 + d * 0.006))) },
                    onDoubleClic: { recentrer() },
                    main: true)
            }
            .frame(width: V, height: V)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
            .onAppear {
                geoSize = geo.size
                preparer(geo.size)
            }
            .onChange(of: geo.size) { taille in
                // La fenêtre change de taille : l'aperçu est redessiné à la
                // nouvelle taille V, mais `offset` est en points d'écran. On le
                // rapporte à la nouvelle taille pour que le cadrage visible —
                // et donc le crop calculé — reste EXACTEMENT le même.
                let ancien = min(geoSize.width, geoSize.height)
                let nouveau = min(taille.width, taille.height)
                geoSize = taille
                if presetFait, ancien > 1, nouveau > 1 {
                    let k = nouveau / ancien
                    offset = CGSize(width: offset.width * k, height: offset.height * k)
                }
                preparer(taille)
            }
        }
    }

    /// Pré-cadrage (re-cadrage) : place l'empreinte selon le crop existant.
    private func preparer(_ taille: CGSize) {
        guard !presetFait else { return }
        completer = moteur.completerInitial
        guard let c = moteur.cropInitial, c.count == 4 else {
            presetFait = true; return
        }
        let V = min(taille.width, taille.height)
        guard V > 0 else { return }
        let Dw = aspect >= 1 ? V : V * aspect
        let Dh = aspect >= 1 ? V / aspect : V
        let ovRy = 0.46 * V, ovRx = ovRy * ratioOvale
        let z = ovRx / (Dw * CGFloat(c[2]))         // depuis hw
        zoom = max(0.25, min(6, z))
        offset = CGSize(width: (0.5 - CGFloat(c[0])) * Dw * zoom,
                        height: (0.5 - CGFloat(c[1])) * Dh * zoom)
        presetFait = true
    }

    private func recentrer() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { offset = .zero; zoom = 1 }
    }

    private func zoomer(_ k: CGFloat) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            zoom = max(0.25, min(6, zoom * k))
        }
    }

    // MARK: colonne de droite

    private var colonne: some View {
        VStack(alignment: .leading, spacing: 14 * echelle) {
            VStack(alignment: .leading, spacing: 8 * echelle) {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "lightbulb").police(11, .bold).foregroundColor(MMD.doreFonce)
                    TitreSection(texte: "Le bon cadrage")
                }
                Text("L'ovale, c'est ce qui sera gravé. Déplace l'empreinte pour que le cœur du " +
                     "motif soit au centre, et zoome jusqu'à ce qu'elle remplisse l'ovale sans " +
                     "laisser de bord vide.")
                    .police(11.5, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, fond: MMD.doreClair.opacity(0.35), cerne: MMD.dore.opacity(0.3), ombre: false)

            VStack(alignment: .leading, spacing: 10 * echelle) {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "plus.magnifyingglass").police(11, .bold).foregroundColor(MMD.gris)
                    TitreSection(texte: "Zoom")
                }
                HStack(spacing: 6 * echelle) {
                    Button { zoomer(1 / 1.2) } label: { Image(systemName: "minus") }
                        .buttonStyle(BoutonRond(taille: 30))
                    Text("\(Int((zoom * 100).rounded())) %")
                        .police(11.5, .bold, .monospaced).foregroundColor(MMD.encre)
                        .frame(width: 50 * echelle)
                    Button { zoomer(1.2) } label: { Image(systemName: "plus") }
                        .buttonStyle(BoutonRond(taille: 30))
                    Spacer()
                }
                Button { recentrer() } label: {
                    HStack(spacing: 5 * echelle) {
                        Image(systemName: "arrow.counterclockwise").police(10.5, .bold)
                        Text("Recentrer l'empreinte").lineLimit(1)
                    }
                }
                .buttonStyle(BoutonDiscret())
                .padding(.leading, -8 * echelle)
                Text("Molette ou pincement pour zoomer, double-clic pour recentrer.")
                    .police(10.5, .medium).foregroundColor(MMD.grisClair)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, ombre: false)

            HStack(alignment: .top, spacing: 12 * echelle) {
                Interrupteur(actif: $completer)
                VStack(alignment: .leading, spacing: 3 * echelle) {
                    Text("Compléter les trous").police(13, .heavy).foregroundColor(MMD.encre)
                    Text("Prolonge les lignes jusqu'au bord de l'ovale là où le scan n'a rien vu.")
                        .police(11, .medium).foregroundColor(MMD.gris)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, ombre: false)

            Spacer(minLength: 0)
        }
    }

    private var controles: some View {
        HStack(spacing: 12 * echelle) {
            Button { revenir() } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "chevron.left").police(11.5, .heavy)
                    Text(moteur.recadrage ? "Retour à la commande" : "Retour au scan")
                }
            }
            .buttonStyle(BoutonSecondaire())
            Spacer()
            Button {
                let c = calculerCrop()
                moteur.validerCadrage(cx: c.0, cy: c.1, hw: c.2, hh: c.3,
                                      completer: completer)
            } label: {
                HStack(spacing: 8 * echelle) {
                    Image(systemName: "checkmark").police(13, .heavy)
                    Text("Valider l'empreinte")
                }
            }
            .buttonStyle(BoutonPrincipal(actif: !moteur.occupe, grand: true))
            .disabled(moteur.occupe)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24 * echelle).padding(.vertical, 14 * echelle)
    }

    /// Bouton « Retour ». Après un RECADRER, le moteur attend un VALIDER pour
    /// CETTE empreinte : repasser par l'écran de scan ferait perdre le nouveau
    /// scan et écraserait quand même le cadrage de l'empreinte re-cadrée. On
    /// revient donc à la commande.
    private func revenir() {
        if moteur.recadrage { moteur.annulerEmpreinte() } else { moteur.retourScan() }
    }

    /// Convertit le cadrage à l'écran en crop normalisé (fractions de la mosaïque).
    private func calculerCrop() -> (Double, Double, Double, Double) {
        let V = min(geoSize.width, geoSize.height)
        guard V > 0 else { return (0.5, 0.5, 0.5, 0.5) }
        let Dw = aspect >= 1 ? V : V * aspect
        let Dh = aspect >= 1 ? V / aspect : V
        let ovRy = 0.46 * V
        let ovRx = ovRy * ratioOvale
        let sx = Dw * zoom
        let sy = Dh * zoom
        let cx = 0.5 - Double(offset.width / sx)
        let cy = 0.5 - Double(offset.height / sy)
        let hw = Double(ovRx / sx)
        let hh = Double(ovRy / sy)
        return (cx, cy, hw, hh)
    }
}
