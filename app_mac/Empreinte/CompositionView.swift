import SwiftUI
import AppKit

// =========================================================================
// ÉTAPE 2 — COMPOSITION. D'abord « chaque empreinte » : chaque doigt seul,
// dans le style choisi, avec la fiche pour comparer les quatre styles. Puis,
// en option, « assembler » : cœur, ovale coupé, tête-bêche, trèfle — avec le
// placement direct de chaque empreinte sur l'aperçu.
// =========================================================================

struct EtapeComposition: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(spacing: 0) {
            sousNavigation
            Group {
                if let i = moteur.detailEmpreinte, i < moteur.empreintes.count {
                    DetailEmpreinteVue(moteur: moteur, index: i)
                } else if moteur.vueComposition == .assembler && moteur.empreintes.count > 1 {
                    AssemblerVue(moteur: moteur)
                } else {
                    ChaqueEmpreinteVue(moteur: moteur)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14 * echelle)),
                                    removal: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: moteur.vueComposition)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: moteur.detailEmpreinte)
            PiedEtape {
                Button {
                    moteur.allerEtape(.empreintes)
                } label: {
                    HStack(spacing: 6 * echelle) {
                        Image(systemName: "arrow.left").police(12, .heavy)
                        Text("Empreintes")
                    }
                }
                .buttonStyle(BoutonDiscret())
            } droite: {
                boutonEnregistrer
                Button {
                    moteur.allerEtape(.envoi)
                } label: {
                    HStack(spacing: 8 * echelle) {
                        Text("Passer à l'envoi")
                        Image(systemName: "arrow.right").police(12.5, .heavy)
                    }
                }
                .buttonStyle(BoutonPrincipal(actif: moteur.forme != nil))
                .disabled(moteur.forme == nil)
            }
        }
        .onAppear { moteur.demanderRendusManquants() }
    }

    /// Les deux onglets de l'étape (ou un simple mot s'il n'y a qu'une empreinte).
    private var sousNavigation: some View {
        HStack(spacing: 8 * echelle) {
            OngletComposition(titre: "Chaque empreinte", symbole: "square.grid.2x2",
                              actif: moteur.vueComposition == .chaque && moteur.detailEmpreinte == nil) {
                moteur.montrerComposition(.chaque)
            }
            if moteur.empreintes.count > 1 {
                OngletComposition(titre: "Assembler", symbole: Libelle.symboleForme(moteur.formeAssemblee ? moteur.forme : "coeur"),
                                  actif: moteur.vueComposition == .assembler && moteur.detailEmpreinte == nil,
                                  detail: moteur.formeAssemblee ? Libelle.forme(moteur.forme, nb: moteur.empreintes.count) : "optionnel") {
                    moteur.montrerComposition(.assembler)
                }
            } else {
                Text("Une seule empreinte : médaille simple.")
                    .police(12, .medium).foregroundColor(MMD.gris)
                    .padding(.leading, 6 * echelle)
            }
            Spacer()
            if let s = Libelle.style(moteur.style) {
                Etiquette(texte: "Style : \(s)", symbole: "scribble.variable",
                          fond: MMD.blanc, couleur: MMD.encre)
            }
        }
        .padding(.horizontal, 24 * echelle).padding(.bottom, 12 * echelle)
    }

    private var pretAEnregistrer: Bool {
        moteur.forme != nil && !moteur.composeEnCours
            && (!moteur.formeAssemblee || moteur.apercuCompose != nil)
    }

    private var boutonEnregistrer: some View {
        Button {
            moteur.enregistrer()
        } label: {
            HStack(spacing: 7 * echelle) {
                if moteur.composeEnCours {
                    Logo(taille: 15, tourne: true, encre: MMD.encre, drapeau: false)
                } else {
                    Image(systemName: moteur.renduEnregistre ? "checkmark.seal.fill" : "square.and.arrow.down")
                        .police(12.5, .heavy)
                }
                Text(moteur.composeEnCours ? "Enregistrement…"
                     : (moteur.renduEnregistre ? "Rendu enregistré" : "Enregistrer le rendu"))
                Text("⌘S").police(10.5, .bold).opacity(0.5)
            }
        }
        .buttonStyle(BoutonSecondaire(couleur: moteur.renduEnregistre ? MMD.vert : MMD.encre))
        .disabled(!pretAEnregistrer)
        .help(moteur.cheminCompose.map { "Enregistré : \(($0 as NSString).lastPathComponent)" }
              ?? "Écrit le SVG et le PNG à graver dans le dossier de la commande")
    }
}

/// Un onglet de l'étape Composition.
struct OngletComposition: View {
    let titre: String
    let symbole: String
    let actif: Bool
    var detail: String? = nil
    let action: () -> Void
    @Environment(\.echelle) private var echelle
    @State private var survol = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: symbole).police(12, .heavy)
                Text(titre).police(13, .heavy)
                if let detail {
                    Text("· \(detail)").police(11.5, .semibold).opacity(0.6)
                }
            }
            .foregroundColor(actif ? .white : MMD.encre)
            .padding(.vertical, 8 * echelle).padding(.horizontal, 14 * echelle)
            .background(Capsule().fill(actif ? MMD.encre : (survol ? MMD.voile : MMD.blanc))
                .overlay(Capsule().strokeBorder(MMD.encre.opacity(actif ? 0 : 0.16), lineWidth: 1.2 * echelle)))
            .animation(.easeOut(duration: 0.15), value: survol)
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 }
    }
}

// =========================================================================
// CHAQUE EMPREINTE : le choix du style, puis une grande carte par empreinte
// =========================================================================

struct ChaqueEmpreinteVue: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    private var colonnes: [GridItem] {
        [GridItem(.adaptive(minimum: 270 * echelle, maximum: 380 * echelle),
                  spacing: 18 * echelle, alignment: .top)]
    }

    var body: some View {
        Defilement {
            VStack(alignment: .leading, spacing: 18 * echelle) {
                VStack(alignment: .leading, spacing: 10 * echelle) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Le style de gravure").police(17, .heavy).foregroundColor(MMD.encre)
                        Spacer()
                        if let aide = Moteur.styles.first(where: { $0.cle == moteur.style })?.aide {
                            Text(aide).police(11.5, .medium).foregroundColor(MMD.gris)
                        }
                    }
                    HStack(spacing: 10 * echelle) {
                        ForEach(Moteur.styles, id: \.cle) { s in
                            VignetteChoix(choisie: moteur.style == s.cle, titre: s.nom, hauteur: 58) {
                                StyleVignette(style: s.cle)
                                    .clipShape(RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous))
                                    .padding(6 * echelle)
                            } action: { moteur.choisirStyle(s.cle) }
                            .frame(maxWidth: 250 * echelle)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Chaque empreinte seule").police(17, .heavy).foregroundColor(MMD.encre)
                    Spacer()
                    Text("Clique sur une empreinte pour comparer les quatre styles")
                        .police(11.5, .medium).foregroundColor(MMD.gris)
                }
                .padding(.top, 4 * echelle)
                LazyVGrid(columns: colonnes, spacing: 18 * echelle) {
                    ForEach(moteur.empreintes) { e in
                        CarteRenduSeul(moteur: moteur, empreinte: e)
                            .apparition(e.index)
                    }
                }
            }
            .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle).padding(.bottom, 24 * echelle)
        }
    }
}

/// Une empreinte seule, rendue dans le style courant, avec sa médaille 1 cm.
struct CarteRenduSeul: View {
    @ObservedObject var moteur: Moteur
    let empreinte: EmpreinteItem
    @State private var survol = false
    @State private var pointsParCm: CGFloat = 72 / 2.54
    @Environment(\.echelle) private var echelle

    var body: some View {
        let t = TeinteEmpreinte.pour(empreinte.index)
        let image = moteur.renduSeul(empreinte.index)
        Button {
            moteur.ouvrirDetail(empreinte.index)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    MMD.blanc
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .scaledToFit().padding(18 * echelle)
                    } else if let photo = moteur.apercusEmpreintes[empreinte.index] {
                        Image(nsImage: photo).resizable().interpolation(.high)
                            .scaledToFit().padding(18 * echelle).opacity(0.25)
                        Chargement(texte: "tracé en cours…", taille: 40, encre: MMD.gris)
                    } else {
                        Chargement(texte: "tracé en cours…", taille: 40, encre: MMD.gris)
                    }
                }
                .frame(height: 230 * echelle)
                .clipShape(CoinsHaut(rayon: MMD.rayon * echelle))
                .overlay(alignment: .topLeading) {
                    EtiquetteEmpreinte(index: empreinte.index, nom: empreinte.nom)
                        .padding(10 * echelle)
                }
                .overlay(alignment: .topTrailing) {
                    if let s = Libelle.style(moteur.style) {
                        Etiquette(texte: s, fond: MMD.creme, couleur: MMD.gris).padding(10 * echelle)
                    }
                }
                .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)

                HStack(spacing: 12 * echelle) {
                    MedailleRendu(image: image, largeurForme: moteur.largeurFormeEmpreinte[empreinte.index],
                                  diametre: pointsParCm)
                    VStack(alignment: .leading, spacing: 2 * echelle) {
                        Text("Taille réelle").police(11.5, .heavy).foregroundColor(MMD.encre)
                        Text("médaille d'1 cm").police(10.5, .medium).foregroundColor(MMD.gris)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5 * echelle) {
                        Text("Comparer les styles").police(12, .heavy)
                        Image(systemName: "arrow.right").police(11, .heavy)
                    }
                    .foregroundColor(t.fonce)
                }
                .padding(.horizontal, 14 * echelle).padding(.vertical, 12 * echelle)
            }
            .contentShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
        }
        .buttonStyle(.plain)
        .carte(cerne: survol ? t.fonce.opacity(0.7) : MMD.trait)
        .scaleEffect(survol ? 1.01 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: survol)
        .onHover { survol = $0 }
        .onAppear { pointsParCm = TailleReelle.pointsParCm() }
        .help("Comparer les quatre styles de « \(empreinte.nom) »")
    }
}

/// La médaille dorée avec un rendu à sa vraie taille : la forme gravée
/// (sa largeur = `largeur_forme` × la largeur du PNG, sa hauteur déduite des
/// zones ou, à défaut, des mêmes marges) remplit la médaille sans dépasser.
/// Sans `largeur_forme` (moteur ancien), le rendu est simplement ajusté.
struct MedailleRendu: View {
    let image: NSImage?
    let largeurForme: Double?
    var hauteurForme: Double? = nil
    let diametre: CGFloat
    /// Part du diamètre occupée par la gravure (un petit bord reste autour).
    private let part: CGFloat = 0.84

    var body: some View {
        Medaille(diametre: diametre) {
            if let image {
                if let l = largeurForme, l > 0.05, image.size.width > 0 {
                    let a = image.size.height / image.size.width
                    let h = hauteurForme ?? max(0.05, 1 - (1 - l) / a)   // mêmes marges en px
                    let w = part * diametre / max(CGFloat(l), CGFloat(h) * a)
                    Image(nsImage: image).resizable().interpolation(.high)
                        .scaledToFit()
                        .frame(width: w)
                } else {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .scaledToFit()
                        .frame(width: diametre * part, height: diametre * part)
                }
            }
        }
    }
}

// =========================================================================
// FICHE D'UNE EMPREINTE : les quatre styles côte à côte
// =========================================================================

struct DetailEmpreinteVue: View {
    @ObservedObject var moteur: Moteur
    let index: Int
    @State private var pointsParCm: CGFloat = 72 / 2.54
    @Environment(\.echelle) private var echelle

    private var empreinte: EmpreinteItem? { index < moteur.empreintes.count ? moteur.empreintes[index] : nil }

    var body: some View {
        let t = TeinteEmpreinte.pour(index)
        VStack(spacing: 0) {
            HStack(spacing: 10 * echelle) {
                Button {
                    moteur.ouvrirDetail(nil)
                } label: {
                    HStack(spacing: 5 * echelle) {
                        Image(systemName: "chevron.left").police(11.5, .heavy)
                        Text("Toutes les empreintes")
                    }
                }
                .buttonStyle(BoutonDiscret())
                .keyboardShortcut(.escape, modifiers: [])
                NumeroEmpreinte(index: index, taille: 30)
                Text(empreinte?.nom ?? "").police(22, .black).foregroundColor(MMD.encre).lineLimit(1)
                Text("Compare les quatre styles, puis clique sur celui que tu préfères.")
                    .police(12, .medium).foregroundColor(MMD.gris)
                Spacer()
                if moteur.empreintes.count > 1 {
                    Button { moteur.ouvrirDetail((index - 1 + moteur.empreintes.count) % moteur.empreintes.count) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(BoutonRond(taille: 30))
                    .help("Empreinte précédente")
                    Button { moteur.ouvrirDetail((index + 1) % moteur.empreintes.count) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(BoutonRond(taille: 30))
                    .help("Empreinte suivante")
                }
            }
            .padding(.horizontal, 24 * echelle).padding(.bottom, 12 * echelle)

            Defilement {
                VStack(alignment: .leading, spacing: 16 * echelle) {
                    HStack(alignment: .top, spacing: 12 * echelle) {
                        ForEach(Moteur.styles, id: \.cle) { s in
                            CarteStyleDetail(nom: s.nom, aide: s.aide,
                                             image: moteur.renduSeul(index, style: s.cle),
                                             choisi: moteur.style == s.cle, teinte: t) {
                                moteur.choisirStyle(s.cle)
                            }
                        }
                    }
                    HStack(spacing: 16 * echelle) {
                        ForEach([1.0, 1.5], id: \.self) { cm in
                            VStack(spacing: 5 * echelle) {
                                MedailleRendu(image: moteur.renduSeul(index),
                                              largeurForme: moteur.largeurFormeEmpreinte[index],
                                              diametre: pointsParCm * cm)
                                Text(cm == 1 ? "1 cm" : "1,5 cm").police(10.5, .bold).foregroundColor(MMD.gris)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3 * echelle) {
                            Text("Taille réelle sur une médaille").police(13, .heavy).foregroundColor(MMD.encre)
                            Text("Dans le style « \(Libelle.style(moteur.style) ?? moteur.style) », " +
                                 "telle qu'elle apparaîtra une fois gravée.")
                                .police(11.5, .medium).foregroundColor(MMD.gris)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(16 * echelle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: 18, fond: MMD.doreClair.opacity(0.35), cerne: MMD.dore.opacity(0.35), ombre: false)
                }
                .padding(.horizontal, 24 * echelle).padding(.top, 2 * echelle).padding(.bottom, 24 * echelle)
            }
        }
        .onAppear {
            pointsParCm = TailleReelle.pointsParCm()
            moteur.ouvrirDetail(index)        // demande les rendus manquants
        }
    }
}

/// Un style, en grand, avec le rendu de l'empreinte dedans.
struct CarteStyleDetail: View {
    let nom: String
    let aide: String
    let image: NSImage?
    let choisi: Bool
    let teinte: TeinteEmpreinte
    let action: () -> Void
    @State private var survol = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10 * echelle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous).fill(MMD.blanc)
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .scaledToFit().padding(12 * echelle)
                    } else {
                        Chargement(texte: "tracé en cours…", taille: 36, encre: MMD.gris)
                    }
                }
                .frame(height: 250 * echelle)
                .clipShape(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous))
                HStack(spacing: 8 * echelle) {
                    Text(nom).police(14.5, .heavy).foregroundColor(MMD.encre)
                    Spacer()
                    if choisi {
                        Etiquette(texte: "choisi", symbole: "checkmark", fond: MMD.encre, couleur: .white)
                    } else {
                        Text("Choisir").police(11.5, .heavy).foregroundColor(MMD.encre.opacity(survol ? 0.9 : 0.5))
                    }
                }
                Text(aide).police(11.5, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12 * echelle)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20 * echelle, style: .continuous)
                .fill(choisi ? MMD.roseClair : (survol ? MMD.voile : MMD.papier)))
            .overlay(RoundedRectangle(cornerRadius: 20 * echelle, style: .continuous)
                .strokeBorder(choisi ? MMD.encre : MMD.encre.opacity(survol ? 0.35 : 0.12),
                              lineWidth: choisi ? 2 * echelle : 1.2 * echelle))
            .contentShape(RoundedRectangle(cornerRadius: 20 * echelle, style: .continuous))
            .scaleEffect(survol && !choisi ? 1.01 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: survol)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: choisi)
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 }
    }
}

// =========================================================================
// ASSEMBLER : la forme, le style, et le placement direct sur l'aperçu
// =========================================================================

struct AssemblerVue: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(alignment: .top, spacing: 18 * echelle) {
            ApercuAssemble(moteur: moteur)
            panneau.frame(width: 300 * echelle)
        }
        .padding(.horizontal, 24 * echelle).padding(.top, 2 * echelle).padding(.bottom, 16 * echelle)
    }

    private var panneau: some View {
        Defilement {
            VStack(alignment: .leading, spacing: 14 * echelle) {
                bloc("Forme", symbole: "heart") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8 * echelle), GridItem(.flexible())],
                              spacing: 8 * echelle) {
                        ForEach(moteur.formesDisponibles, id: \.0) { cle, nom in
                            VignetteChoix(choisie: moteur.forme == cle, titre: nom, hauteur: 58) {
                                FormeIcone(forme: cle, nb: moteur.empreintes.count,
                                           encre: MMD.encre, epaisseur: 1.8 * echelle)
                                    .padding(8 * echelle)
                            } action: { moteur.choisirForme(cle) }
                        }
                    }
                    if let aide = Moteur.aideFormes[moteur.forme ?? "separees"] {
                        Text(aide).police(11, .medium).foregroundColor(MMD.gris)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                bloc("Style", symbole: "scribble.variable") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6 * echelle), GridItem(.flexible())],
                              alignment: .leading, spacing: 6 * echelle) {
                        ForEach(Moteur.styles, id: \.cle) { s in
                            Puce(texte: s.nom, choisie: moteur.style == s.cle) { moteur.choisirStyle(s.cle) }
                                .fixedSize()
                        }
                    }
                    Text("Le style se choisit aussi dans « Chaque empreinte », où l'on compare les quatre.")
                        .police(10.5, .medium).foregroundColor(MMD.grisClair)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if moteur.ajustementPossible {
                    bloc("Placer les empreintes", symbole: "hand.draw") {
                        VStack(alignment: .leading, spacing: 6 * echelle) {
                            ForEach(moteur.empreintes) { e in
                                Button {
                                    moteur.placement = moteur.placement == e.index ? nil : e.index
                                } label: {
                                    HStack(spacing: 8 * echelle) {
                                        EtiquetteEmpreinte(index: e.index, nom: e.nom)
                                        Spacer()
                                        if moteur.placement == e.index {
                                            Image(systemName: "checkmark").police(11, .heavy)
                                                .foregroundColor(TeinteEmpreinte.pour(e.index).fonce)
                                        } else if !e.ajust.neutre {
                                            Text("placée").police(10.5, .semibold).foregroundColor(MMD.grisClair)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(moteur.lobes.isEmpty
                             ? "Choisis une empreinte, puis glisse sur l'aperçu pour la déplacer ; ⌥ + molette pour la tourner."
                             : "Survole une empreinte sur l'aperçu, clique pour la sélectionner : glisse pour la déplacer, " +
                               "tourne avec la poignée du coin (⇧ pour une rotation libre), double-clic pour la recentrer.")
                            .police(11, .medium).foregroundColor(MMD.gris)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 4 * echelle)
        }
    }

    private func bloc<C: View>(_ titre: String, symbole: String,
                               @ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10 * echelle) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: symbole).police(11, .bold).foregroundColor(MMD.gris)
                TitreSection(texte: titre)
            }
            contenu()
        }
        .padding(14 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: 18, ombre: false)
    }
}

/// Vignette cliquable (forme ou style) : un dessin, un titre, un cadre qui
/// s'allume quand elle est choisie.
struct VignetteChoix<Dessin: View>: View {
    let choisie: Bool
    let titre: String
    var hauteur: CGFloat = 52
    @ViewBuilder var dessin: () -> Dessin
    let action: () -> Void
    @State private var survol = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6 * echelle) {
                dessin()
                    .frame(maxWidth: .infinity)
                    .frame(height: hauteur * echelle)
                    .background(RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous)
                        .fill(choisie ? MMD.blanc : MMD.blanc.opacity(0.7)))
                Text(titre).police(11.5, .heavy)
                    .foregroundColor(choisie ? MMD.encre : MMD.encre.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(6 * echelle)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 15 * echelle, style: .continuous)
                .fill(choisie ? MMD.roseClair : (survol ? MMD.voile : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 15 * echelle, style: .continuous)
                .strokeBorder(choisie ? MMD.encre : MMD.encre.opacity(survol ? 0.3 : 0.12),
                              lineWidth: choisie ? 1.8 * echelle : 1.2 * echelle))
            .contentShape(RoundedRectangle(cornerRadius: 15 * echelle, style: .continuous))
            .scaleEffect(survol && !choisie ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: survol)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: choisie)
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 }
    }
}

// =========================================================================
// L'APERÇU ASSEMBLÉ, interactif
// =========================================================================

/// Où l'image d'aperçu est dessinée dans la zone (points), pour convertir
/// les fractions du moteur en positions à l'écran.
struct GeometrieApercu {
    let cadre: CGRect

    static func pour(zone: CGSize, image: CGSize, marge: CGFloat, zoom: CGFloat, glisse: CGSize) -> GeometrieApercu {
        let boite = CGSize(width: max(1, zone.width - 2 * marge), height: max(1, zone.height - 2 * marge))
        let k = (image.width > 0 && image.height > 0)
            ? min(boite.width / image.width, boite.height / image.height) : 1
        let w = image.width * k * zoom, h = image.height * k * zoom
        let c = CGPoint(x: zone.width / 2 + glisse.width, y: zone.height / 2 + glisse.height)
        return GeometrieApercu(cadre: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    func point(_ fx: Double, _ fy: Double) -> CGPoint {
        CGPoint(x: cadre.minX + CGFloat(fx) * cadre.width, y: cadre.minY + CGFloat(fy) * cadre.height)
    }
}

/// Un lobe tel qu'on le dessine, en points : le centre ACTUEL de
/// l'empreinte (écart local compris), la zone visible (fixe : elle ne suit
/// pas l'ajust), et le cadre dessiné pour le survol et la sélection.
/// Pour les formes coupées (ovale coupé, tête-bêche) le cadre suit la zone
/// visible, tourné seulement de l'angle d'ajust ; pour le cœur et le trèfle
/// c'est le lobe lui-même, avec sa rotation de forme.
struct LobeEcran {
    let index: Int
    let centre: CGPoint
    let rayonX: CGFloat, rayonY: CGFloat     // unité de dx / dy à l'écran
    let zone: CGRect
    let cadreCentre: CGPoint
    let cadreHW: CGFloat, cadreHH: CGFloat
    let cadreAngle: Double

    /// Demi-hauteur du cadre une fois tourné (pour poser la barre au-dessus).
    var demiHauteurTournee: CGFloat {
        let rad = cadreAngle * .pi / 180
        return abs(cadreHH * CGFloat(cos(rad))) + abs(cadreHW * CGFloat(sin(rad)))
    }

    /// Un coin du cadre (sx, sy = ±1), éventuellement écarté vers l'extérieur.
    func coin(_ sx: CGFloat, _ sy: CGFloat, marge: CGFloat = 0, ecartement: CGFloat = 0) -> CGPoint {
        let rad = cadreAngle * .pi / 180
        let x = sx * (cadreHW + marge + ecartement), y = sy * (cadreHH + marge + ecartement)
        return CGPoint(x: cadreCentre.x + x * CGFloat(cos(rad)) - y * CGFloat(sin(rad)),
                       y: cadreCentre.y + x * CGFloat(sin(rad)) + y * CGFloat(cos(rad)))
    }
}

/// Ramène un angle dans ]−180, 180].
func angleNormalise(_ a: Double) -> Double {
    var r = a
    while r > 180 { r -= 360 }
    while r <= -180 { r += 360 }
    return r
}

/// Ramène un point à l'intérieur d'une zone, avec une marge.
func dansZone(_ p: CGPoint, _ zone: CGSize, marge: CGFloat) -> CGPoint {
    CGPoint(x: min(max(marge, p.x), zone.width - marge),
            y: min(max(marge, p.y), zone.height - marge))
}

struct ApercuAssemble: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique

    @State private var zoom: CGFloat = 1
    @State private var glisse: CGSize = .zero
    @State private var survol: Int? = nil
    @State private var pointsParCm: CGFloat = 72 / 2.54
    // gestes en cours
    @State private var departDeplacement: Ajustement? = nil
    @State private var departRotation: (theta: Double, angle: Double)? = nil

    private var marge: CGFloat { 18 * echelle }
    private var selection: Int? { moteur.placement }

    var body: some View {
        GeometryReader { geo in
            let geom = GeometrieApercu.pour(zone: geo.size, image: moteur.apercuCompose?.size ?? .zero,
                                            marge: marge, zoom: zoom, glisse: glisse)
            let lobes = lobesEcran(geom)
            let positions = positionsEtiquettes(lobes, geom: geom, zone: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous).fill(MMD.blanc)

                if let img = moteur.apercuCompose, moteur.formeAssemblee || !moteur.lobes.isEmpty || moteur.forme == "separees" {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: geom.cadre.width, height: geom.cadre.height)
                        .position(x: geom.cadre.midX, y: geom.cadre.midY)
                        .opacity(moteur.formeAssemblee ? 1 : 0.9)
                    ForEach(lobes, id: \.index) { l in
                        fantome(l, image: img, geom: geom)
                    }
                } else if !moteur.apercuEnCours {
                    messageVide
                }

                // couche AppKit : promener / zoomer la vue, ⌥ + molette = tourner
                ZoneInteraction(
                    onPan: { dx, dy in deplacerVue(dx, dy, geom: geom) },
                    onZoom: { d in zoom = max(0.05, min(6, zoom * (1 + d * 0.005))) },
                    onRotation: { d in
                        if let i = selection, moteur.ajustementPossible {
                            moteur.tournerPlacement(i, delta: Double(d) * 0.25)
                        }
                    },
                    onDoubleClic: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { zoom = 1; glisse = .zero } },
                    main: true)

                // les étiquettes « 1 · Louis » dès que le moteur dit où est chacune
                // (planche « séparées » comprise) ; le placement, seulement
                // pour les formes assemblées
                if moteur.ajustementPossible && moteur.apercuCompose != nil {
                    ForEach(lobes, id: \.index) { l in
                        zoneLobe(l)
                    }
                }
                // les étiquettes « 1 · Louis » (celle de l'empreinte sélectionnée
                // s'efface : sa pastille est dans la barre, sur son cadre)
                if moteur.apercuCompose != nil {
                    ForEach(lobes, id: \.index) { l in
                        etiquette(l, position: positions[l.index] ?? CGPoint(x: l.zone.midX, y: l.zone.maxY))
                            .opacity(selection == l.index ? 0 : 1)
                    }
                }
                if moteur.ajustementPossible && moteur.apercuCompose != nil {
                    if let i = selection, let l = lobes.first(where: { $0.index == i }) {
                        let autres = obstaclesFixes(geo.size)
                            + positions.filter { $0.key != i }.map { rectEtiquette($0.key, $0.value) }
                        let pBarre = positionBarre(l, obstacles: autres, dansZone: geo.size)
                        let cote: CGFloat = pBarre.y < l.cadreCentre.y ? 1 : -1
                        cadreSelection(l, cote: cote, obstacles: autres, dansZone: geo.size)
                        barreSelection(l, position: pBarre)
                    }
                }

                if moteur.apercuEnCours {
                    ZStack {
                        MMD.blanc.opacity(moteur.apercuCompose == nil ? 1 : 0.55)
                        Chargement(texte: "Composition en cours…")
                    }
                    .allowsHitTesting(false)
                }

                // surcouche : étiquette, outils, taille réelle
                VStack {
                    HStack(alignment: .top) {
                        if let f = Libelle.forme(moteur.forme, nb: moteur.empreintes.count) {
                            Etiquette(texte: "\(f) · \(Libelle.style(moteur.style) ?? "")",
                                      symbole: Libelle.symboleForme(moteur.forme),
                                      fond: MMD.creme, couleur: MMD.encre)
                        }
                        Spacer()
                        if moteur.formeAssemblee && selection == nil && !moteur.lobes.isEmpty {
                            Etiquette(texte: "survole une empreinte pour la placer", symbole: "hand.draw",
                                      fond: MMD.creme, couleur: MMD.gris)
                        }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        if moteur.tailleReelle, moteur.formeAssemblee { carteTailleReelle }
                        Spacer()
                        barreOutils
                    }
                }
                .padding(12 * echelle)
            }
            .coordinateSpace(name: "apercu")
            .clipShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
            .compositingGroup()
            .shadow(color: MMD.encre.opacity(0.05), radius: 14 * echelle, y: 5 * echelle)
        }
        .animation(.easeInOut(duration: 0.2), value: moteur.apercuEnCours)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: moteur.tailleReelle)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: moteur.placement)
        .onAppear { pointsParCm = TailleReelle.pointsParCm() }
        .onChange(of: moteur.empreintes.count) { _ in zoom = 1; glisse = .zero }
        // raccourcis : flèches = déplacer la sélection, Échap = désélectionner
        .background(
            Group {
                Button("") { bouger(-1, 0) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { bouger(1, 0) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { bouger(0, -1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { bouger(0, 1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { bouger(-5, 0) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { bouger(5, 0) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { bouger(0, -5) }.keyboardShortcut(.upArrow, modifiers: .shift)
                Button("") { bouger(0, 5) }.keyboardShortcut(.downArrow, modifiers: .shift)
                Button("") { moteur.placement = nil }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0)
        )
    }

    // MARK: géométrie

    /// Les lobes du moteur convertis en points, écart local (geste en cours
    /// ou nouvel aperçu pas encore arrivé) compris. Le cadre dessiné est la
    /// zone VISIBLE de l'empreinte, DROITE et fixe : c'est une fenêtre dans
    /// la forme, seule l'empreinte tourne dedans (poignées, barre, fantôme).
    private func lobesEcran(_ geom: GeometrieApercu) -> [LobeEcran] {
        guard moteur.apercuCompose != nil else { return [] }
        return moteur.lobes.compactMap { l in
            guard l.index < moteur.empreintes.count else { return nil }
            let rayonX = max(8, CGFloat(l.rx) * geom.cadre.width)
            let rayonY = max(8, CGFloat(l.ry) * geom.cadre.height)
            let ecart = moteur.ecartPlacement(l.index)
            let decal = CGSize(width: CGFloat(ecart.dx) * rayonX, height: CGFloat(ecart.dy) * rayonY)
            let c0 = geom.point(l.cx, l.cy)
            let centre = CGPoint(x: c0.x + decal.width, y: c0.y + decal.height)
            let p0 = geom.point(l.zone[0], l.zone[1]), p1 = geom.point(l.zone[2], l.zone[3])
            let zone = CGRect(x: p0.x, y: p0.y, width: max(1, p1.x - p0.x), height: max(1, p1.y - p0.y))
            return LobeEcran(index: l.index, centre: centre, rayonX: rayonX, rayonY: rayonY,
                             zone: zone,
                             cadreCentre: CGPoint(x: zone.midX, y: zone.midY),
                             cadreHW: zone.width / 2, cadreHH: zone.height / 2,
                             cadreAngle: 0)
        }
    }

    /// Repli sans `lobes` (moteur plus ancien) : rayon de lobe estimé.
    private func rayonLobeRepli(_ geom: GeometrieApercu) -> CGFloat {
        let fraction: Double
        if let l = moteur.largeurForme, l > 0 { fraction = l * 0.44 }
        else {
            switch (moteur.forme, moteur.empreintes.count) {
            case ("coeur", _):  fraction = 430.0 / 980.0
            case ("trefle", 4): fraction = 430.0 / 1857.0
            case ("trefle", _): fraction = 430.0 / 1797.0
            default:            fraction = 0.44
            }
        }
        return max(20, CGFloat(fraction) * geom.cadre.width)
    }

    // MARK: couches

    /// Pendant un geste (ou en attendant le nouvel aperçu), la partie visible
    /// de l'empreinte est redessinée à sa nouvelle place, par-dessus.
    @ViewBuilder
    private func fantome(_ l: LobeEcran, image: NSImage, geom: GeometrieApercu) -> some View {
        let ecart = moteur.ecartPlacement(l.index)
        if !ecart.neutre, let lobe = moteur.lobe(l.index) {
            let zoneOrigine = l.zone
            // on estompe l'ancienne position…
            Rectangle().fill(MMD.blanc.opacity(0.75))
                .frame(width: zoneOrigine.width, height: zoneOrigine.height)
                .position(x: zoneOrigine.midX, y: zoneOrigine.midY)
            // … et on montre la nouvelle
            Image(nsImage: image).resizable().interpolation(.medium)
                .frame(width: geom.cadre.width, height: geom.cadre.height)
                .mask(Rectangle().frame(width: zoneOrigine.width, height: zoneOrigine.height)
                    .position(x: zoneOrigine.midX - geom.cadre.minX, y: zoneOrigine.midY - geom.cadre.minY))
                .rotationEffect(.degrees(ecart.angle), anchor: UnitPoint(x: lobe.cx, y: lobe.cy))
                .offset(x: CGFloat(ecart.dx) * l.rayonX, y: CGFloat(ecart.dy) * l.rayonY)
                .position(x: geom.cadre.midX, y: geom.cadre.midY)
                .opacity(0.92)
                .allowsHitTesting(false)
        }
    }

    /// La zone sensible d'un lobe = sa partie VISIBLE (`zone`) : clic =
    /// sélection, glisser = déplacer, double-clic = recentrer. Au survol, le
    /// cadre (orienté) s'allume de la couleur de l'empreinte.
    private func zoneLobe(_ l: LobeEcran) -> some View {
        let t = TeinteEmpreinte.pour(l.index)
        let choisi = selection == l.index
        let actif = survol == l.index && !choisi
        return ZStack {
            RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous)
                .fill(t.moyen.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous)
                    .strokeBorder(t.fonce, style: StrokeStyle(lineWidth: 2 * echelle, dash: [6 * echelle, 4 * echelle])))
                .frame(width: 2 * l.cadreHW, height: 2 * l.cadreHH)
                .rotationEffect(.degrees(l.cadreAngle))
                .position(l.cadreCentre)
                .opacity(actif ? 1 : 0)
                .allowsHitTesting(false)
            Rectangle().fill(Color.white.opacity(0.0001))
                .frame(width: l.zone.width, height: l.zone.height)
                .position(x: l.zone.midX, y: l.zone.midY)
                .contentShape(Rectangle())
                .onHover { survol = $0 ? l.index : (survol == l.index ? nil : survol) }
                .onTapGesture(count: 2) { moteur.reinitialiserAjustement(l.index) }
                .onTapGesture { moteur.placement = choisi ? nil : l.index }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("apercu"))
                    .onChanged { v in
                        if moteur.placement != l.index { moteur.placement = l.index }
                        if departDeplacement == nil { departDeplacement = moteur.empreintes[l.index].ajust }
                        guard let d = departDeplacement else { return }
                        moteur.ajuster(l.index,
                                       dx: d.dx + Double(v.translation.width / l.rayonX),
                                       dy: d.dy + Double(v.translation.height / l.rayonY),
                                       angle: d.angle)
                    }
                    .onEnded { _ in departDeplacement = nil })
        }
        .animation(.easeOut(duration: 0.15), value: survol)
    }

    /// Où vont les deux poignées de rotation : aux coins du cadre, du côté
    /// (`cote` = −1 haut, +1 bas) opposé à la barre, dans l'aperçu et hors
    /// des étiquettes et outils ; si ça coince, elles se rapprochent du coin.
    private func poignees(_ l: LobeEcran, cote: CGFloat, obstacles: [CGRect],
                          dansZone zone: CGSize) -> [CGPoint] {
        let pad = 5 * echelle
        let limite = CGRect(x: 14 * echelle, y: 14 * echelle,
                            width: zone.width - 28 * echelle, height: zone.height - 28 * echelle)
        return [-1, 1].map { sx -> CGPoint in
            for ecart in [22.0, 10.0, 0.0] {
                let p = l.coin(CGFloat(sx), cote, marge: pad, ecartement: CGFloat(ecart) * echelle)
                let r = CGRect(x: p.x - 10 * echelle, y: p.y - 10 * echelle,
                               width: 20 * echelle, height: 20 * echelle)
                if limite.contains(p) && !obstacles.contains(where: { $0.intersects(r) }) { return p }
            }
            return dansZone(l.coin(CGFloat(sx), cote, marge: pad), zone, marge: 14 * echelle)
        }
    }

    /// Le cadre de sélection (droit, fixe : la fenêtre visible de
    /// l'empreinte), poignées de rotation aux deux coins du côté `cote`.
    private func cadreSelection(_ l: LobeEcran, cote: CGFloat, obstacles: [CGRect],
                                dansZone zone: CGSize) -> some View {
        let t = TeinteEmpreinte.pour(l.index)
        let pad = 5 * echelle
        let points = poignees(l, cote: cote, obstacles: obstacles, dansZone: zone)
        return ZStack {
            RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous)
                .strokeBorder(t.fonce, lineWidth: 2 * echelle)
                .frame(width: 2 * (l.cadreHW + pad), height: 2 * (l.cadreHH + pad))
                .rotationEffect(.degrees(l.cadreAngle))
                .position(l.cadreCentre)
                .allowsHitTesting(false)
            // petits carrés aux quatre coins
            ForEach([(-1, -1), (1, -1), (-1, 1), (1, 1)], id: \.0.description) { sx, sy in
                RoundedRectangle(cornerRadius: 2 * echelle).fill(MMD.blanc)
                    .overlay(RoundedRectangle(cornerRadius: 2 * echelle).strokeBorder(t.fonce, lineWidth: 1.5 * echelle))
                    .frame(width: 8 * echelle, height: 8 * echelle)
                    .rotationEffect(.degrees(l.cadreAngle))
                    .position(l.coin(CGFloat(sx), CGFloat(sy), marge: pad))
                    .allowsHitTesting(false)
            }
            // poignées de rotation, reliées au coin par une petite tige
            ForEach([-1, 1], id: \.self) { sx in
                let base = l.coin(CGFloat(sx), cote, marge: pad)
                let p = points[sx < 0 ? 0 : 1]
                Path { path in path.move(to: base); path.addLine(to: p) }
                    .stroke(t.fonce.opacity(0.6), style: StrokeStyle(lineWidth: 1.5 * echelle, lineCap: .round))
                    .allowsHitTesting(false)
                ZStack {
                    Circle().fill(MMD.blanc)
                    Circle().strokeBorder(t.fonce, lineWidth: 2 * echelle)
                    Image(systemName: "arrow.triangle.2.circlepath").police(8, .heavy).foregroundColor(t.fonce)
                }
                .frame(width: 20 * echelle, height: 20 * echelle)
                .compositingGroup()
                .shadow(color: MMD.encre.opacity(0.2), radius: 3 * echelle, y: 1 * echelle)
                .position(p)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("apercu"))
                    .onChanged { v in
                        let c = l.centre          // centre de rotation de l'empreinte
                        let theta = Double(atan2(v.location.y - c.y, v.location.x - c.x)) * 180 / .pi
                        if departRotation == nil {
                            departRotation = (theta, moteur.empreintes[l.index].ajust.angle)
                        }
                        guard let d = departRotation else { return }
                        var angle = d.angle + (theta - d.theta)
                        // aimant tous les 15°, ⇧ pour une rotation libre
                        if !NSEvent.modifierFlags.contains(.shift) {
                            angle = (angle / 15).rounded() * 15
                        }
                        moteur.fixerAngle(l.index, angleNormalise(angle))
                    }
                    .onEnded { _ in departRotation = nil })
                .help("Tourner (⇧ : rotation libre)")
            }
        }
    }

    /// Ce qui est posé à demeure sur l'aperçu : l'étiquette forme · style
    /// (haut gauche), la barre d'outils (bas droite), la carte taille réelle
    /// (bas gauche, quand elle est ouverte). Étiquettes et barre de
    /// sélection les évitent.
    private func obstaclesFixes(_ zone: CGSize) -> [CGRect] {
        let e = echelle
        var r = [CGRect(x: 12 * e, y: 12 * e, width: 230 * e, height: 26 * e),
                 CGRect(x: zone.width - 12 * e - 242 * e, y: zone.height - 12 * e - 40 * e,
                        width: 242 * e, height: 40 * e)]
        if moteur.tailleReelle && moteur.formeAssemblee {
            r.append(CGRect(x: 12 * e, y: zone.height - 12 * e - 156 * e, width: 218 * e, height: 156 * e))
        }
        if moteur.formeAssemblee && selection == nil && !moteur.lobes.isEmpty {
            r.append(CGRect(x: zone.width - 12 * e - 236 * e, y: 12 * e, width: 236 * e, height: 26 * e))
        }
        return r
    }

    /// Le premier centre candidat où un rectangle de `taille` tient dans
    /// l'aperçu sans toucher d'obstacle ; sinon le premier candidat ramené
    /// dans l'aperçu.
    private func caser(_ taille: CGSize, candidats: [CGPoint], obstacles: [CGRect],
                       zone: CGSize, marge: CGFloat) -> CGPoint {
        func rect(_ c: CGPoint) -> CGRect {
            CGRect(x: c.x - taille.width / 2, y: c.y - taille.height / 2,
                   width: taille.width, height: taille.height)
        }
        let limite = CGRect(x: marge, y: marge, width: zone.width - 2 * marge, height: zone.height - 2 * marge)
        for c in candidats {
            let r = rect(c)
            if limite.contains(r) && !obstacles.contains(where: { $0.intersects(r) }) { return c }
        }
        let c = candidats.first ?? CGPoint(x: zone.width / 2, y: zone.height / 2)
        return CGPoint(x: min(max(limite.minX + taille.width / 2, c.x), limite.maxX - taille.width / 2),
                       y: min(max(limite.minY + taille.height / 2, c.y), limite.maxY - taille.height / 2))
    }

    private func tailleEtiquette(_ index: Int) -> CGSize {
        CGSize(width: (36 + 7.4 * CGFloat(moteur.empreintes[index].nom.count)) * echelle, height: 24 * echelle)
    }

    /// Où va chaque étiquette « 1 · Louis » : juste à l'extérieur de sa zone
    /// visible, côté bord extérieur de la forme — en dessous en général,
    /// au-dessus pour une zone située dans la moitié haute (haut du
    /// tête-bêche, feuille du haut du trèfle). Si un obstacle gêne, elle
    /// glisse le long du bord (en restant sous sa zone), sinon change de côté.
    private func positionsEtiquettes(_ lobes: [LobeEcran], geom: GeometrieApercu,
                                     zone: CGSize) -> [Int: CGPoint] {
        let obstacles = obstaclesFixes(zone)
        var out: [Int: CGPoint] = [:]
        var poses: [CGRect] = []
        for l in lobes {
            let t = tailleEtiquette(l.index)
            let dessus = l.zone.midY < geom.cadre.midY - 0.04 * geom.cadre.height
            let yA = dessus ? l.zone.minY - 13 * echelle : l.zone.maxY + 13 * echelle
            let yB = dessus ? l.zone.maxY + 13 * echelle : l.zone.minY - 13 * echelle
            // décalages possibles le long du bord : juste à côté d'un obstacle
            var xs: [CGFloat] = [l.zone.midX]
            for o in obstacles {
                xs.append(o.minX - t.width / 2 - 6 * echelle)
                xs.append(o.maxX + t.width / 2 + 6 * echelle)
            }
            xs = xs.filter { $0 >= l.zone.minX + t.width / 2 - 2 && $0 <= l.zone.maxX - t.width / 2 + 2 }
            var candidats: [CGPoint] = []
            for y in [yA, yB] { for x in xs { candidats.append(CGPoint(x: x, y: y)) } }
            let p = caser(t, candidats: candidats, obstacles: obstacles + poses, zone: zone, marge: 6 * echelle)
            out[l.index] = p
            poses.append(CGRect(x: p.x - t.width / 2, y: p.y - t.height / 2, width: t.width, height: t.height))
        }
        return out
    }

    private func rectEtiquette(_ index: Int, _ p: CGPoint) -> CGRect {
        let t = tailleEtiquette(index)
        return CGRect(x: p.x - t.width / 2, y: p.y - t.height / 2, width: t.width, height: t.height)
    }

    private func etiquette(_ l: LobeEcran, position: CGPoint) -> some View {
        EtiquetteEmpreinte(index: l.index, nom: moteur.empreintes[l.index].nom, pleine: true)
            .position(position)
            .allowsHitTesting(false)
    }

    /// Taille de la barre ±5° pour l'empreinte i.
    private func tailleBarre(_ index: Int) -> CGSize {
        CGSize(width: (240 + 7.4 * CGFloat(moteur.empreintes[index].nom.count)) * echelle,
               height: 38 * echelle)
    }

    /// Où va la barre ±5° : au-dessus du cadre, sinon en dessous, décalée
    /// au besoin le long du bord, sans toucher étiquettes, outils ni carte
    /// taille réelle. Les poignées, elles, iront du côté opposé.
    private func positionBarre(_ l: LobeEcran, obstacles: [CGRect], dansZone zone: CGSize) -> CGPoint {
        let taille = tailleBarre(l.index)
        let ys = [l.cadreCentre.y - l.cadreHH - 30 * echelle,
                  l.cadreCentre.y + l.cadreHH + 30 * echelle]
        var xs: [CGFloat] = [l.cadreCentre.x]
        for o in obstacles {
            xs.append(o.minX - taille.width / 2 - 8 * echelle)
            xs.append(o.maxX + taille.width / 2 + 8 * echelle)
        }
        var candidats: [CGPoint] = []
        for y in ys { for x in xs { candidats.append(CGPoint(x: x, y: y)) } }
        return caser(taille, candidats: candidats, obstacles: obstacles, zone: zone, marge: 10 * echelle)
    }

    /// Petite barre près de la sélection : ↺ 5°, ↻ 5°, recentrer, fermer.
    private func barreSelection(_ l: LobeEcran, position: CGPoint) -> some View {
        let t = TeinteEmpreinte.pour(l.index)
        let nom = moteur.empreintes[l.index].nom
        let angle = l.index < moteur.empreintes.count ? moteur.empreintes[l.index].ajust.angle : 0
        return HStack(spacing: 4 * echelle) {
            EtiquetteEmpreinte(index: l.index, nom: nom, pleine: true)
                .padding(.trailing, 2 * echelle)
            Button { moteur.tournerPlacement(l.index, delta: -5) } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(BoutonRond(taille: 28, couleur: t.fonce, cerne: false)).help("Tourner de 5° vers la gauche")
            Text("\(Int(angle.rounded()))°").police(11, .heavy, .monospaced)
                .foregroundColor(MMD.encre).frame(width: 36 * echelle)
            Button { moteur.tournerPlacement(l.index, delta: 5) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(BoutonRond(taille: 28, couleur: t.fonce, cerne: false)).help("Tourner de 5° vers la droite")
            Divider().frame(height: 16 * echelle)
            Button { moteur.reinitialiserAjustement(l.index) } label: {
                HStack(spacing: 4 * echelle) {
                    Image(systemName: "scope").police(10.5, .heavy)
                    Text("Recentrer")
                }
            }
            .buttonStyle(BoutonDiscret(couleur: t.fonce))
            .disabled(moteur.empreintes[l.index].ajust.neutre)
            Button { moteur.placement = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(BoutonRond(taille: 24, couleur: MMD.gris, cerne: false)).help("Désélectionner (Échap)")
        }
        .padding(.leading, 5 * echelle).padding(.trailing, 6 * echelle).padding(.vertical, 5 * echelle)
        .background(Capsule().fill(MMD.blanc)
            .overlay(Capsule().strokeBorder(t.fonce.opacity(0.35), lineWidth: 1.2 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.12), radius: 10 * echelle, y: 4 * echelle)
        .position(position)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var messageVide: some View {
        VStack(spacing: 10 * echelle) {
            FormeIcone(forme: moteur.forme ?? "separees", nb: max(1, moteur.empreintes.count),
                       encre: MMD.encre.opacity(0.2), epaisseur: 2 * echelle)
                .frame(width: 70 * echelle, height: 70 * echelle)
            Text(moteur.formeAssemblee
                 ? "L'aperçu se compose dès que tu choisis une forme."
                 : "Médailles séparées : chaque empreinte est gravée seule.\nChoisis une forme à droite pour les assembler.")
                .police(12.5, .medium).foregroundColor(MMD.gris)
                .multilineTextAlignment(.center)
        }
    }

    /// La barre d'outils flottante de l'aperçu.
    private var barreOutils: some View {
        HStack(spacing: 4 * echelle) {
            Button { zoomer(1 / 1.25) } label: { Image(systemName: "minus") }
                .buttonStyle(BoutonRond(taille: 28, cerne: false)).help("Dézoomer")
            Text("\(Int((zoom * 100).rounded())) %")
                .police(11, .bold, .monospaced).foregroundColor(MMD.encre)
                .frame(width: 46 * echelle)
            Button { zoomer(1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(BoutonRond(taille: 28, cerne: false)).help("Zoomer")
            Divider().frame(height: 16 * echelle)
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { zoom = 1; glisse = .zero }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(BoutonRond(taille: 28, cerne: false)).help("Vue d'ensemble (double-clic)")
            Button {
                moteur.tailleReelle.toggle()
            } label: { Image(systemName: "ruler") }
                .buttonStyle(BoutonRond(taille: 28, fond: moteur.tailleReelle ? MMD.doreClair : MMD.blanc,
                                        couleur: moteur.tailleReelle ? MMD.doreFonce : MMD.encre, cerne: false))
                .help("Taille réelle sur une médaille d'1 cm")
                .disabled(!moteur.formeAssemblee)
            Button {
                moteur.demanderApercu()
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BoutonRond(taille: 28, cerne: false)).help("Actualiser l'aperçu")
                .disabled(moteur.apercuEnCours || moteur.forme == nil)
        }
        .padding(.horizontal, 8 * echelle).padding(.vertical, 5 * echelle)
        .background(Capsule().fill(MMD.blanc)
            .overlay(Capsule().strokeBorder(MMD.encre.opacity(0.14), lineWidth: 1.2 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.08), radius: 10 * echelle, y: 4 * echelle)
    }

    /// La médaille à l'échelle 1 : ce que verra vraiment le client.
    private var carteTailleReelle: some View {
        VStack(alignment: .leading, spacing: 8 * echelle) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: "ruler").police(11, .bold).foregroundColor(MMD.doreFonce)
                Text("Taille réelle").police(12, .heavy).foregroundColor(MMD.encre)
            }
            HStack(alignment: .bottom, spacing: 14 * echelle) {
                ForEach([1.0, 1.5], id: \.self) { cm in
                    VStack(spacing: 5 * echelle) {
                        MedailleRendu(image: moteur.apercuCompose, largeurForme: moteur.largeurForme,
                                      hauteurForme: hauteurFormeApercu, diametre: pointsParCm * cm)
                        Text(cm == 1 ? "1 cm" : "1,5 cm").police(10, .bold).foregroundColor(MMD.gris)
                    }
                }
            }
            Text("Gravure d'un centimètre, telle qu'elle apparaîtra sur la médaille.")
                .police(10, .medium).foregroundColor(MMD.gris)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 190 * echelle, alignment: .leading)
        }
        .padding(12 * echelle)
        .background(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous).fill(MMD.creme)
            .overlay(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous)
                .strokeBorder(MMD.dore.opacity(0.5), lineWidth: 1.2 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.08), radius: 10 * echelle, y: 4 * echelle)
        .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
    }

    /// Hauteur de la forme assemblée (fraction du PNG) : l'union des zones.
    private var hauteurFormeApercu: Double? {
        guard !moteur.lobes.isEmpty else { return nil }
        let y0 = moteur.lobes.map { $0.zone[1] }.min() ?? 0
        let y1 = moteur.lobes.map { $0.zone[3] }.max() ?? 1
        return y1 > y0 ? y1 - y0 : nil
    }

    // MARK: actions

    private func zoomer(_ k: CGFloat) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            zoom = max(0.05, min(6, zoom * k))
        }
    }

    /// Glisser sur le fond : promène la vue. Sans `lobes` (moteur ancien),
    /// c'est l'empreinte sélectionnée qui bouge, comme avant.
    private func deplacerVue(_ dx: CGFloat, _ dy: CGFloat, geom: GeometrieApercu) {
        if moteur.lobes.isEmpty, let i = selection, moteur.ajustementPossible {
            let r = rayonLobeRepli(geom)
            moteur.deplacerPlacement(i, ddx: Double(dx / r), ddy: Double(dy / r))
        } else {
            glisse.width += dx; glisse.height += dy
        }
    }

    /// Flèches du clavier : un petit pas (× 5 avec ⇧).
    private func bouger(_ sx: Int, _ sy: Int) {
        guard let i = selection, moteur.ajustementPossible else { return }
        moteur.deplacerPlacement(i, ddx: Double(sx) * 0.02, ddy: Double(sy) * 0.02)
    }
}
