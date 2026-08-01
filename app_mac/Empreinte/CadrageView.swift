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
                      titre: "Ajuste le cadre autour de l'empreinte",
                      sousTitre: "Empreinte de \(moteur.personneEnCours) — " +
                                 "glisse pour déplacer, molette pour zoomer",
                      retour: { revenir() },
                      libelleRetour: moteur.recadrage ? "Commande" : "Scan")
            editeur
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20 * echelle).padding(.top, 16 * echelle)
            controles
            BarreStatut(moteur: moteur)
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
                RoundedRectangle(cornerRadius: 20 * echelle, style: .continuous)
                    .fill(MMD.noir)
                if let img = moteur.apercu {
                    Image(nsImage: img).resizable()
                        .frame(width: Dw, height: Dh)
                        .scaleEffect(zoom)
                        .offset(offset)
                }
                // assombrit l'extérieur de l'ovale
                Rectangle().fill(MMD.noir.opacity(0.55))
                    .overlay(Ellipse().frame(width: 2 * ovRx, height: 2 * ovRy)
                        .blendMode(.destinationOut))
                    .compositingGroup()
                Ellipse().stroke(Color.white, lineWidth: 2.5 * echelle)
                    .frame(width: 2 * ovRx, height: 2 * ovRy)
                Ellipse().stroke(MMD.rouge.opacity(0.9), lineWidth: 1 * echelle)
                    .frame(width: 2 * ovRx + 5 * echelle, height: 2 * ovRy + 5 * echelle)
                // capture souris (déplacer) + molette (zoomer)
                ZoneInteraction(
                    onPan: { dx, dy in offset.width += dx; offset.height += dy },
                    onZoom: { d in zoom = max(0.25, min(6, zoom * (1 + d * 0.006))) },
                    main: true)
            }
            .frame(width: V, height: V)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20 * echelle, style: .continuous))
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

    private var controles: some View {
        VStack(spacing: 12 * echelle) {
            HStack(spacing: 14 * echelle) {
                Toggle(isOn: $completer) {
                    VStack(alignment: .leading, spacing: 1 * echelle) {
                        Text("Compléter les trous")
                            .police(13, .bold, .rounded)
                            .foregroundColor(MMD.noir)
                        Text("prolonge les lignes jusqu'au bord de l'ovale")
                            .police(11).foregroundColor(MMD.gris)
                    }
                }
                .toggleStyle(.switch).tint(MMD.bleu)
                Spacer()
                Button {
                    offset = .zero; zoom = 1
                } label: {
                    HStack(spacing: 6 * echelle) {
                        Image(systemName: "arrow.counterclockwise")
                            .police(11, .bold)
                        Text("Recentrer").police(12.5, .bold, .rounded)
                    }
                }
                .buttonStyle(BoutonDiscret())
            }
            HStack(spacing: 12 * echelle) {
                Button { revenir() } label: {
                    HStack(spacing: 6 * echelle) {
                        Image(systemName: "chevron.left").police(11.5, .black)
                        Text(moteur.recadrage ? "Retour à la commande" : "Retour au scan")
                            .police(13, .bold, .rounded)
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
                        Image(systemName: "checkmark").police(13, .black)
                        Text("Valider l'empreinte")
                            .police(14.5, .black, .rounded)
                    }
                }
                .buttonStyle(BoutonPrincipal(actif: !moteur.occupe))
                .disabled(moteur.occupe)
            }
        }
        .padding(.horizontal, 22 * echelle).padding(.top, 14 * echelle).padding(.bottom, 14 * echelle)
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
