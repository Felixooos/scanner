import SwiftUI
import AppKit

// =========================================================================
// Identité de marque « Maman m'a dit » : palette, échelle, typographie,
// logo, boutons, cartes et petits composants partagés par tous les écrans.
//
// Esprit : encre presque noire sur papier crème chaud, beaucoup d'air, coins
// très arrondis, typographie arrondie (en écho aux traits ronds du logo),
// deux accents doux (rose poudré, bleu dragée) et un doré « bijou » discret.
// =========================================================================

enum MMD {
    // --- papier -----------------------------------------------------------
    static let creme   = Color(red: 0.984, green: 0.973, blue: 0.949)   // fond #FBF8F2
    static let papier  = Color(red: 0.998, green: 0.995, blue: 0.986)   // cartes
    static let blanc   = Color.white

    // --- encre ------------------------------------------------------------
    static let encre   = Color(red: 0.086, green: 0.082, blue: 0.090)   // #161517
    static let gris    = Color(red: 0.46,  green: 0.44,  blue: 0.43)    // texte secondaire
    static let grisClair = Color(red: 0.66, green: 0.64, blue: 0.62)
    static let trait   = Color(red: 0.086, green: 0.082, blue: 0.090).opacity(0.10)
    static let voile   = Color(red: 0.086, green: 0.082, blue: 0.090).opacity(0.045)

    // --- accents doux -----------------------------------------------------
    static let rose        = Color(red: 0.933, green: 0.757, blue: 0.769)  // rose poudré
    static let roseClair   = Color(red: 0.976, green: 0.906, blue: 0.910)
    static let roseFonce   = Color(red: 0.780, green: 0.455, blue: 0.498)  // texte / icône
    static let dragee      = Color(red: 0.757, green: 0.843, blue: 0.918)  // bleu dragée
    static let drageeClair = Color(red: 0.906, green: 0.941, blue: 0.973)
    static let drageeFonce = Color(red: 0.318, green: 0.498, blue: 0.710)
    static let dore        = Color(red: 0.792, green: 0.651, blue: 0.408)  // doré bijou
    static let doreClair   = Color(red: 0.953, green: 0.906, blue: 0.800)
    static let doreFonce   = Color(red: 0.608, green: 0.478, blue: 0.263)

    // --- états ------------------------------------------------------------
    static let vert    = Color(red: 0.333, green: 0.624, blue: 0.459)
    static let vertClair = Color(red: 0.886, green: 0.945, blue: 0.906)
    static let rouge   = Color(red: 0.816, green: 0.251, blue: 0.298)

    // --- clin d'œil drapeau (le logo garde ses couleurs vives) -------------
    static let bleuDrapeau  = Color(red: 0.02, green: 0.02, blue: 1.00)
    static let rougeDrapeau = Color(red: 1.00, green: 0.06, blue: 0.06)

    /// Rayon d'arrondi standard des cartes.
    static let rayon: CGFloat = 22

    /// Taille de fenêtre pour laquelle les mesures du code sont écrites.
    /// Au-delà, tout grossit proportionnellement (voir `Echelle`).
    static let largeurRef: CGFloat = 1080
    static let hauteurRef: CGFloat = 740
    static let echelleMax: CGFloat = 1.75
}

// MARK: - Environnement : échelle globale et mode « statique »

/// Facteur d'agrandissement de toute l'interface. Vaut 1 à la taille de
/// référence, jusqu'à `MMD.echelleMax` en plein écran. Injecté une seule
/// fois à la racine (ContentView) et lu partout par `@Environment(\.echelle)`.
private struct CleEchelle: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

/// Vrai pendant le rendu des captures (`--captures`) : les animations
/// d'apparition sont court-circuitées (sinon les cartes seraient invisibles
/// sur l'image) et les vues AppKit (champs, défilement) sont remplacées par
/// leur équivalent dessiné.
private struct CleStatique: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var echelle: CGFloat {
        get { self[CleEchelle.self] }
        set { self[CleEchelle.self] = newValue }
    }
    var statique: Bool {
        get { self[CleStatique.self] }
        set { self[CleStatique.self] = newValue }
    }
}

enum Echelle {
    /// Jamais plus petit que le dessin d'origine, jamais plus de 1,75×.
    /// C'est la dimension la plus JUSTE qui commande : une fenêtre très
    /// large mais basse ne doit pas tout grossir au point de manquer de haut.
    static func pour(_ taille: CGSize) -> CGFloat {
        let r = min(taille.width / MMD.largeurRef, taille.height / MMD.hauteurRef)
        return min(max(r, 1), MMD.echelleMax)
    }
}

// MARK: - Typographie

/// Police à l'échelle, arrondie par défaut : `.police(14, .bold)` remplace
/// `.font(.system(size: 14, weight: .bold, design: .rounded))`.
private struct PoliceMMD: ViewModifier {
    @Environment(\.echelle) private var echelle
    let taille: CGFloat
    let poids: Font.Weight
    let dessin: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: taille * echelle, weight: poids, design: dessin))
    }
}

extension View {
    func police(_ taille: CGFloat,
                _ poids: Font.Weight = .regular,
                _ dessin: Font.Design = .rounded) -> some View {
        modifier(PoliceMMD(taille: taille, poids: poids, dessin: dessin))
    }
}

// MARK: - Logo

/// Le logo de la maison à une taille donnée (en points de référence, mis à
/// l'échelle). `tourne` = l'anneau de texte tourne : c'est L'indicateur de
/// chargement de la maison.
struct Logo: View {
    var taille: CGFloat = 48
    var tourne: Bool = false
    var encre: Color = MMD.encre
    var drapeau: Bool = true
    @Environment(\.echelle) private var echelle

    var body: some View {
        LogoMMDVectoriel(encre: encre, tourne: tourne, drapeau: drapeau)
            .frame(width: taille * echelle, height: taille * echelle)
    }
}

/// Chargement avec un mot d'explication sous le logo qui tourne.
struct Chargement: View {
    var texte: String
    var taille: CGFloat = 54
    var encre: Color = MMD.encre
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(spacing: 14 * echelle) {
            Logo(taille: taille, tourne: true, encre: encre)
            Text(texte)
                .police(12.5, .semibold)
                .foregroundColor(encre.opacity(0.72))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Boutons

/// Bouton plein encre (l'action principale de l'écran).
struct BoutonPrincipal: ButtonStyle {
    var couleur: Color = MMD.encre
    var actif: Bool = true
    var grand: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, couleur: couleur, actif: actif, grand: grand)
    }

    private struct Corps: View {
        let configuration: Configuration
        let couleur: Color
        let actif: Bool
        let grand: Bool
        @Environment(\.echelle) private var echelle
        @State private var survol = false

        var body: some View {
            let r = (grand ? 18 : 14) * echelle
            configuration.label
                .police(grand ? 15.5 : 13.5, .bold)
                .foregroundColor(.white)
                .padding(.vertical, (grand ? 15 : 11) * echelle)
                .padding(.horizontal, (grand ? 26 : 20) * echelle)
                .background(
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(actif ? couleur : MMD.grisClair.opacity(0.55)))
                .compositingGroup()
                .shadow(color: couleur.opacity(actif && survol ? 0.28 : 0.0),
                        radius: 10 * echelle, y: 4 * echelle)
                .scaleEffect(configuration.isPressed ? 0.97 : (survol && actif ? 1.015 : 1))
                .animation(.spring(response: 0.28, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: survol)
                .onHover { survol = $0 }
        }
    }
}

/// Bouton papier cerné d'un trait encre (action secondaire).
struct BoutonSecondaire: ButtonStyle {
    var couleur: Color = MMD.encre
    var grand: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, couleur: couleur, grand: grand)
    }

    private struct Corps: View {
        let configuration: Configuration
        let couleur: Color
        let grand: Bool
        @Environment(\.echelle) private var echelle
        @State private var survol = false

        var body: some View {
            let r = (grand ? 18 : 14) * echelle
            configuration.label
                .police(grand ? 15 : 13, .bold)
                .foregroundColor(couleur)
                .padding(.vertical, (grand ? 14 : 10) * echelle)
                .padding(.horizontal, (grand ? 24 : 18) * echelle)
                .background(
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(survol ? MMD.voile : MMD.blanc)
                        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                            .strokeBorder(couleur.opacity(survol ? 0.9 : 0.55),
                                          lineWidth: 1.5 * echelle)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: survol)
                .onHover { survol = $0 }
        }
    }
}

/// Bouton teinté tout doux (rose, dragée, doré…) : action d'appoint.
struct BoutonDoux: ButtonStyle {
    var fond: Color = MMD.roseClair
    var texte: Color = MMD.roseFonce

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, fond: fond, texte: texte)
    }

    private struct Corps: View {
        let configuration: Configuration
        let fond: Color
        let texte: Color
        @Environment(\.echelle) private var echelle
        @State private var survol = false

        var body: some View {
            configuration.label
                .police(13, .bold)
                .foregroundColor(texte)
                .padding(.vertical, 10 * echelle).padding(.horizontal, 13 * echelle)
                .background(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous)
                    .fill(fond.opacity(survol ? 1 : 0.85)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: survol)
                .onHover { survol = $0 }
        }
    }
}

/// Petit bouton discret (texte court ou icône + texte), sans cadre.
struct BoutonDiscret: ButtonStyle {
    var couleur: Color = MMD.encre

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, couleur: couleur)
    }

    private struct Corps: View {
        let configuration: Configuration
        let couleur: Color
        @Environment(\.echelle) private var echelle
        @State private var survol = false

        var body: some View {
            configuration.label
                .police(12.5, .bold)
                .foregroundColor(couleur.opacity(configuration.isPressed ? 0.5 : 0.85))
                .padding(.vertical, 7 * echelle).padding(.horizontal, 10 * echelle)
                .background(RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous)
                    .fill(couleur.opacity(configuration.isPressed ? 0.10 : (survol ? 0.06 : 0))))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: survol)
                .onHover { survol = $0 }
        }
    }
}

/// Bouton rond à icône (fermer, zoom, réglages…).
struct BoutonRond: ButtonStyle {
    var taille: CGFloat = 32
    var fond: Color = MMD.blanc
    var couleur: Color = MMD.encre
    var cerne: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, taille: taille, fond: fond,
              couleur: couleur, cerne: cerne)
    }

    private struct Corps: View {
        let configuration: Configuration
        let taille: CGFloat
        let fond: Color
        let couleur: Color
        let cerne: Bool
        @Environment(\.echelle) private var echelle
        @State private var survol = false

        var body: some View {
            configuration.label
                .police(taille * 0.4, .bold)
                .foregroundColor(couleur)
                .frame(width: taille * echelle, height: taille * echelle)
                .background(Circle().fill(survol ? MMD.voile : fond)
                    .overlay(Circle().strokeBorder(couleur.opacity(cerne ? 0.18 : 0),
                                                   lineWidth: 1.2 * echelle)))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65),
                           value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: survol)
                .onHover { survol = $0 }
        }
    }
}

// MARK: - Cartes

/// Carte papier, coins très arrondis, trait fin et ombre très douce.
private struct CarteMMD: ViewModifier {
    let rayon: CGFloat
    let fond: Color
    let cerne: Color
    let ombre: Bool
    @Environment(\.echelle) private var echelle

    func body(content: Content) -> some View {
        let r = rayon * echelle
        return content
            .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(fond))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(cerne, lineWidth: 1.2 * echelle))
            .compositingGroup()
            .shadow(color: MMD.encre.opacity(ombre ? 0.05 : 0),
                    radius: 14 * echelle, y: 5 * echelle)
    }
}

extension View {
    func carte(rayon: CGFloat = MMD.rayon, fond: Color = MMD.papier,
               cerne: Color = MMD.trait, ombre: Bool = true) -> some View {
        modifier(CarteMMD(rayon: rayon, fond: fond, cerne: cerne, ombre: ombre))
    }
}

// MARK: - Petits composants

/// Puce de sélection (forme, style, prénom à placer…).
struct Puce: View {
    let texte: String
    var symbole: String? = nil
    let choisie: Bool
    var accent: Color = MMD.encre
    var fondChoisi: Color? = nil      // nil = plein `accent`
    let action: () -> Void
    @Environment(\.echelle) private var echelle
    @State private var survol = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * echelle) {
                if let symbole { Image(systemName: symbole).police(11, .bold) }
                Text(texte).police(12.5, .bold)
            }
            .foregroundColor(choisie ? (fondChoisi == nil ? .white : accent) : MMD.encre)
            .padding(.vertical, 7 * echelle).padding(.horizontal, 13 * echelle)
            .background(
                Capsule().fill(choisie ? (fondChoisi ?? accent) : (survol ? MMD.voile : MMD.blanc))
                    .overlay(Capsule().strokeBorder(
                        choisie ? accent.opacity(fondChoisi == nil ? 1 : 0.5)
                                : MMD.encre.opacity(0.18),
                        lineWidth: 1.3 * echelle)))
            .animation(.easeOut(duration: 0.15), value: survol)
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 }
    }
}

/// Petite étiquette d'information (« 2 empreintes », « Cœur »…).
struct Etiquette: View {
    let texte: String
    var symbole: String? = nil
    var fond: Color = MMD.voile
    var couleur: Color = MMD.gris
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 4 * echelle) {
            if let symbole { Image(systemName: symbole).police(9.5, .bold) }
            Text(texte).police(10.5, .bold)
        }
        .foregroundColor(couleur)
        .padding(.vertical, 4 * echelle).padding(.horizontal, 8 * echelle)
        .background(Capsule().fill(fond))
    }
}

/// Titre de section, petit et espacé.
struct TitreSection: View {
    let texte: String
    @Environment(\.echelle) private var echelle
    var body: some View {
        Text(texte.uppercased())
            .tracking(1.6 * echelle)
            .police(10.5, .heavy)
            .foregroundColor(MMD.gris)
    }
}

/// La couleur fixe de chaque empreinte, partout dans l'app (1 rose poudré,
/// 2 bleu dragée, 3 vert sauge, 4 doré) : on sait toujours qui est qui.
struct TeinteEmpreinte {
    let fonce: Color      // texte, contours
    let moyen: Color      // traits, poignées
    let clair: Color      // fonds
    let nom: String

    static func pour(_ index: Int) -> TeinteEmpreinte {
        switch ((index % 4) + 4) % 4 {
        case 0:  return TeinteEmpreinte(fonce: MMD.roseFonce, moyen: MMD.rose, clair: MMD.roseClair, nom: "rose")
        case 1:  return TeinteEmpreinte(fonce: MMD.drageeFonce, moyen: MMD.dragee, clair: MMD.drageeClair, nom: "dragée")
        case 2:  return TeinteEmpreinte(fonce: MMD.vert, moyen: MMD.vert.opacity(0.55), clair: MMD.vertClair, nom: "sauge")
        default: return TeinteEmpreinte(fonce: MMD.doreFonce, moyen: MMD.dore, clair: MMD.doreClair, nom: "doré")
        }
    }
}

/// Pastille ronde numérotée, de la couleur de l'empreinte.
struct NumeroEmpreinte: View {
    let index: Int
    var taille: CGFloat = 24
    @Environment(\.echelle) private var echelle
    var body: some View {
        let t = TeinteEmpreinte.pour(index)
        Text("\(index + 1)")
            .police(taille * 0.48, .heavy).foregroundColor(.white)
            .frame(width: taille * echelle, height: taille * echelle)
            .background(Circle().fill(t.fonce))
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.2 * echelle))
    }
}

/// Étiquette « 1 · Louis » aux couleurs de l'empreinte.
struct EtiquetteEmpreinte: View {
    let index: Int
    let nom: String
    var pleine: Bool = false       // fond foncé (sur l'aperçu) ou clair (dans une carte)
    @Environment(\.echelle) private var echelle
    var body: some View {
        let t = TeinteEmpreinte.pour(index)
        HStack(spacing: 5 * echelle) {
            Text("\(index + 1)").police(10.5, .heavy)
                .frame(width: 17 * echelle, height: 17 * echelle)
                .background(Circle().fill(pleine ? .white.opacity(0.25) : t.fonce))
                .foregroundColor(.white)
            Text(nom).police(11.5, .heavy).foregroundColor(pleine ? .white : t.fonce).lineLimit(1)
        }
        .padding(.leading, 3 * echelle).padding(.trailing, 9 * echelle).padding(.vertical, 3 * echelle)
        .background(Capsule().fill(pleine ? t.fonce : t.clair)
            .overlay(Capsule().strokeBorder(t.fonce.opacity(pleine ? 0 : 0.35), lineWidth: 1 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(pleine ? 0.18 : 0), radius: 4 * echelle, y: 2 * echelle)
    }
}

/// Fin trait tricolore : le clin d'œil au drapeau, à utiliser avec parcimonie.
struct Tricolore: View {
    var largeur: CGFloat = 54
    var hauteur: CGFloat = 3
    @Environment(\.echelle) private var echelle
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(MMD.bleuDrapeau.opacity(0.85))
            Rectangle().fill(MMD.encre.opacity(0.08))
            Rectangle().fill(MMD.rougeDrapeau.opacity(0.85))
        }
        .frame(width: largeur * echelle, height: hauteur * echelle)
        .clipShape(Capsule())
    }
}

/// Interrupteur dessiné à la main (rend partout, y compris en capture).
struct Interrupteur: View {
    @Binding var actif: Bool
    var teinte: Color = MMD.drageeFonce
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { actif.toggle() }
        } label: {
            ZStack(alignment: actif ? .trailing : .leading) {
                Capsule().fill(actif ? teinte : MMD.encre.opacity(0.16))
                Circle().fill(MMD.blanc)
                    .compositingGroup()
                    .shadow(color: MMD.encre.opacity(0.18), radius: 2 * echelle, y: 1 * echelle)
                    .padding(2.5 * echelle)
            }
            .frame(width: 40 * echelle, height: 24 * echelle)
        }
        .buttonStyle(.plain)
    }
}

/// Champ de saisie habillé. En mode capture, un simple texte le remplace
/// (les champs AppKit ne se dessinent pas dans ImageRenderer).
struct ChampTexte: View {
    let invite: String
    @Binding var texte: String
    var symbole: String? = nil
    var grand: Bool = false
    var auFocus: Bool = false
    /// Compteur : chaque incrément redonne le focus au champ (⌘F…).
    var demandeFocus: Int = 0
    var onSubmit: () -> Void = {}
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 9 * echelle) {
            if let symbole {
                Image(systemName: symbole).police(grand ? 15 : 12.5, .bold)
                    .foregroundColor(MMD.gris)
            }
            if statique {
                Text(texte.isEmpty ? invite : texte)
                    .police(grand ? 18 : 13.5, grand ? .bold : .semibold)
                    .foregroundColor(texte.isEmpty ? MMD.grisClair : MMD.encre)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(invite, text: $texte)
                    .textFieldStyle(.plain)
                    .police(grand ? 18 : 13.5, grand ? .bold : .semibold)
                    .foregroundColor(MMD.encre)
                    .focused($focus)
                    .onSubmit(onSubmit)
            }
        }
        .padding(.vertical, (grand ? 13 : 9) * echelle)
        .padding(.horizontal, (grand ? 16 : 13) * echelle)
        .background(RoundedRectangle(cornerRadius: (grand ? 16 : 13) * echelle, style: .continuous)
            .fill(MMD.blanc)
            .overlay(RoundedRectangle(cornerRadius: (grand ? 16 : 13) * echelle, style: .continuous)
                .strokeBorder(focus ? MMD.encre.opacity(0.6) : MMD.encre.opacity(0.16),
                              lineWidth: 1.4 * echelle)))
        .animation(.easeOut(duration: 0.15), value: focus)
        .onAppear { if auFocus { DispatchQueue.main.async { focus = true } } }
        .onChange(of: demandeFocus) { _ in focus = true }
    }
}

/// Défilement vertical ; en capture, le contenu est posé tel quel.
struct Defilement<Contenu: View>: View {
    @ViewBuilder var contenu: () -> Contenu
    @Environment(\.statique) private var statique

    var body: some View {
        if statique {
            // Comme un ScrollView : la hauteur du contenu n'influence pas la
            // mise en page du parent, ce qui dépasse est simplement coupé.
            GeometryReader { _ in
                contenu().frame(maxWidth: .infinity, alignment: .top)
            }
            .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: true) { contenu() }
        }
    }
}

// MARK: - Animations

/// Apparition douce des cartes (léger ressort, décalée selon le rang).
struct Apparition: ViewModifier {
    let rang: Int
    @State private var visible = false
    @Environment(\.statique) private var statique
    func body(content: Content) -> some View {
        content
            .opacity(visible || statique ? 1 : 0)
            .scaleEffect(visible || statique ? 1 : 0.965)
            .offset(y: visible || statique ? 0 : 10)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)
                    .delay(Double(min(rang, 14)) * 0.04)) { visible = true }
            }
    }
}

extension View {
    func apparition(_ rang: Int) -> some View { modifier(Apparition(rang: rang)) }
}

// MARK: - Dessins de la maison : formes, styles, médaille

/// Icône d'une forme de composition (ovale(s) côte à côte, cœur, trèfle).
struct FormeIcone: View {
    let forme: String         // "simple", "coeur", "trefle"
    var nb: Int = 1
    var encre: Color = MMD.encre
    var epaisseur: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, taille in
            let c = CGPoint(x: taille.width / 2, y: taille.height / 2)
            let u = min(taille.width, taille.height)
            let style = StrokeStyle(lineWidth: epaisseur, lineCap: .round, lineJoin: .round)
            switch forme {
            case "coeur":
                ctx.stroke(Self.coeur(centre: c, taille: u * 0.88), with: .color(encre), style: style)
                // fin espace vertical entre les deux moitiés
                var fente = Path()
                fente.move(to: CGPoint(x: c.x, y: c.y - u * 0.17))
                fente.addLine(to: CGPoint(x: c.x, y: c.y + u * 0.40))
                ctx.stroke(fente, with: .color(encre.opacity(0.35)),
                           style: StrokeStyle(lineWidth: epaisseur * 0.8, lineCap: .round, dash: [2, 3]))
            case "trefle":
                let n = max(3, min(4, nb))
                let r = u * (n == 3 ? 0.21 : 0.20)
                let d = u * (n == 3 ? 0.235 : 0.245)
                for i in 0..<n {
                    let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(n)
                    let p = CGPoint(x: c.x + d * cos(a), y: c.y + d * sin(a))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(encre), style: style)
                }
            case "ovale_lr":
                // un ovale coupé en deux moitiés gauche / droite
                let ry = u * 0.44, rx = ry * 0.8
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)),
                           with: .color(encre), style: style)
                var fente = Path()
                fente.move(to: CGPoint(x: c.x, y: c.y - ry * 0.92))
                fente.addLine(to: CGPoint(x: c.x, y: c.y + ry * 0.92))
                ctx.stroke(fente, with: .color(encre.opacity(0.45)),
                           style: StrokeStyle(lineWidth: epaisseur * 0.8, lineCap: .round, dash: [2, 3]))
            case "tete_beche":
                // moitié haute et moitié basse (celle du bas retournée)
                let ry = u * 0.44, rx = ry * 0.8
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)),
                           with: .color(encre), style: style)
                var fente = Path()
                fente.move(to: CGPoint(x: c.x - rx * 0.92, y: c.y))
                fente.addLine(to: CGPoint(x: c.x + rx * 0.92, y: c.y))
                ctx.stroke(fente, with: .color(encre.opacity(0.45)),
                           style: StrokeStyle(lineWidth: epaisseur * 0.8, lineCap: .round, dash: [2, 3]))
                // deux petites flèches opposées : l'une monte, l'autre descend
                for (sy, y) in [(CGFloat(-1), c.y - ry * 0.5), (CGFloat(1), c.y + ry * 0.5)] {
                    var f = Path()
                    f.move(to: CGPoint(x: c.x - u * 0.05, y: y + sy * u * 0.05))
                    f.addLine(to: CGPoint(x: c.x, y: y - sy * u * 0.03))
                    f.addLine(to: CGPoint(x: c.x + u * 0.05, y: y + sy * u * 0.05))
                    ctx.stroke(f, with: .color(encre.opacity(0.6)), style: style)
                }
            default:
                // « séparées » : une médaille ronde par empreinte
                let n = max(1, min(4, nb))
                let r = u * (n == 1 ? 0.40 : (n == 2 ? 0.22 : 0.17))
                let pas = r * 2.35
                let colonnes = n <= 2 ? n : 2
                let lignes = n <= 2 ? 1 : 2
                for i in 0..<n {
                    let col = CGFloat(i % colonnes), lig = CGFloat(i / colonnes)
                    let x = c.x - pas * CGFloat(colonnes - 1) / 2 + pas * col
                    let y = c.y - pas * CGFloat(lignes - 1) / 2 + pas * lig
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                               with: .color(encre), style: style)
                    let ri = r * 0.55
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - ri * 0.8, y: y - ri, width: 2 * ri * 0.8, height: 2 * ri)),
                               with: .color(encre.opacity(0.45)),
                               style: StrokeStyle(lineWidth: epaisseur * 0.7, dash: [1.5, 2]))
                }
            }
        }
    }

    /// Un cœur classique (deux arcs et une pointe), centré.
    static func coeur(centre c: CGPoint, taille t: CGFloat) -> Path {
        var p = Path()
        let w = t, h = t * 0.92
        let top = c.y - h * 0.38
        let bas = c.y + h * 0.56
        p.move(to: CGPoint(x: c.x, y: top + h * 0.22))
        p.addCurve(to: CGPoint(x: c.x - w * 0.5, y: top + h * 0.22),
                   control1: CGPoint(x: c.x - w * 0.02, y: top - h * 0.14),
                   control2: CGPoint(x: c.x - w * 0.52, y: top - h * 0.12))
        p.addCurve(to: CGPoint(x: c.x, y: bas),
                   control1: CGPoint(x: c.x - w * 0.48, y: top + h * 0.58),
                   control2: CGPoint(x: c.x - w * 0.14, y: bas - h * 0.18))
        p.addCurve(to: CGPoint(x: c.x + w * 0.5, y: top + h * 0.22),
                   control1: CGPoint(x: c.x + w * 0.14, y: bas - h * 0.18),
                   control2: CGPoint(x: c.x + w * 0.48, y: top + h * 0.58))
        p.addCurve(to: CGPoint(x: c.x, y: top + h * 0.22),
                   control1: CGPoint(x: c.x + w * 0.52, y: top - h * 0.12),
                   control2: CGPoint(x: c.x + w * 0.02, y: top - h * 0.14))
        p.closeSubpath()
        return p
    }
}

/// Petit échantillon dessiné d'un style de rendu (gabor, traits, traits
/// soudés, photo) : des crêtes en boucle, comme une empreinte.
struct StyleVignette: View {
    let style: String
    var encre: Color = MMD.encre

    var body: some View {
        Canvas { ctx, taille in
            let w = taille.width, h = taille.height
            let c = CGPoint(x: w * 0.5, y: h * 0.62)
            if style == "photo" {
                // fond gris doux, crêtes en dégradé : « la vraie photo »
                let fond = Path(roundedRect: CGRect(origin: .zero, size: taille), cornerRadius: 0)
                ctx.fill(fond, with: .color(Color(white: 0.86)))
            }
            let epais: CGFloat = style == "gabor" ? 3.4 : 1.5
            let pas: CGFloat = style == "gabor" ? 7.0 : 5.2
            let n = Int(max(w, h) / pas) + 2
            for i in 1...n {
                let r = CGFloat(i) * pas
                // boucle : demi-ellipse en haut, flancs qui descendent
                let rx = r * 0.78, ry = r
                var p = Path()
                p.move(to: CGPoint(x: c.x - rx, y: h + 4))
                p.addLine(to: CGPoint(x: c.x - rx, y: c.y))
                p.addCurve(to: CGPoint(x: c.x + rx, y: c.y),
                           control1: CGPoint(x: c.x - rx, y: c.y - ry * 1.33),
                           control2: CGPoint(x: c.x + rx, y: c.y - ry * 1.33))
                p.addLine(to: CGPoint(x: c.x + rx, y: h + 4))
                var dash: [CGFloat] = []
                if style == "sans" { dash = [max(6, r * 0.9), 2.2] }
                let couleur: Color = style == "photo" ? Color(white: 0.22) : encre
                ctx.stroke(p, with: .color(couleur),
                           style: StrokeStyle(lineWidth: epais, lineCap: .round, dash: dash))
                // bifurcations soudées : quelques ponts entre crêtes voisines
                if style == "contact", i % 3 == 0, i > 2 {
                    var pont = Path()
                    let y = c.y + r * 0.35
                    pont.move(to: CGPoint(x: c.x + rx, y: y))
                    pont.addQuadCurve(to: CGPoint(x: c.x + rx - pas, y: y + pas * 1.6),
                                      control: CGPoint(x: c.x + rx - pas * 0.3, y: y + pas * 0.9))
                    ctx.stroke(pont, with: .color(couleur),
                               style: StrokeStyle(lineWidth: epais, lineCap: .round))
                }
            }
        }
    }
}

/// Une médaille dorée (pour juger la taille réelle d'une gravure d'1 cm).
struct Medaille<Contenu: View>: View {
    var diametre: CGFloat
    @ViewBuilder var contenu: () -> Contenu

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [MMD.doreClair, MMD.dore, MMD.doreFonce,
                                               MMD.dore, MMD.doreClair, MMD.dore, MMD.doreClair],
                                      center: .center))
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.45), Color.clear,
                                              MMD.doreFonce.opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(MMD.doreFonce.opacity(0.35), lineWidth: max(0.8, diametre * 0.012))
                .padding(diametre * 0.045)
            contenu()
                .frame(width: diametre * 0.88, height: diametre * 0.88)
                .clipShape(Circle())
        }
        .frame(width: diametre, height: diametre)
        .compositingGroup()
        .shadow(color: MMD.doreFonce.opacity(0.25), radius: diametre * 0.08, y: diametre * 0.04)
    }
}

/// Taille réelle à l'écran : points SwiftUI par centimètre, mesurés sur
/// l'écran principal (dimensions physiques connues du système). Repli :
/// 72 points par pouce.
enum TailleReelle {
    static func pointsParCm() -> CGFloat {
        guard let ecran = NSScreen.main,
              let num = ecran.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 72 / 2.54 }
        let id = CGDirectDisplayID(num.uint32Value)
        let mm = CGDisplayScreenSize(id)
        let px = CGFloat(CGDisplayPixelsWide(id))
        guard mm.width > 0, px > 0 else { return 72 / 2.54 }
        let pxParMm = px / mm.width
        return pxParMm * 10 / ecran.backingScaleFactor
    }
}

/// Libellés lisibles des formes et styles.
enum Libelle {
    /// Les formes qu'on peut assembler (clé moteur). « simple » (ancien) = séparées.
    static let formesAssemblees: Set<String> = ["coeur", "ovale_lr", "tete_beche", "trefle"]

    static func forme(_ cle: String?, nb: Int = 0) -> String? {
        switch cle {
        case "coeur":                return "Cœur"
        case "ovale_lr":             return "Ovale coupé"
        case "tete_beche":           return "Tête-bêche"
        case "trefle":               return nb >= 3 ? "Trèfle \(min(nb, 4))" : "Trèfle"
        case "separees", "simple":   return nb > 1 ? "Séparées" : "Simple"
        default:                     return nil
        }
    }
    static func style(_ cle: String?) -> String? {
        Moteur.styles.first { $0.cle == cle }?.nom
    }
    /// Le libellé de forme tel que le moteur nomme les fichiers exportés
    /// (PROTOCOLE_V2 : `Simple`, `Cœur`, `Trèfle 3`, `Trèfle 4`…).
    static func formeFichier(_ cle: String?, nb: Int) -> String? {
        switch cle {
        case "coeur":      return "Cœur"
        case "ovale_lr":   return "Ovale coupé"
        case "tete_beche": return "Tête-bêche"
        case "trefle":     return "Trèfle \(max(3, min(nb, 4)))"
        default:           return nil          // séparées : pas de rendu assemblé
        }
    }
    static func symboleForme(_ cle: String?) -> String {
        switch cle {
        case "coeur":      return "heart"
        case "trefle":     return "leaf"
        case "ovale_lr":   return "rectangle.split.2x1"
        case "tete_beche": return "rectangle.split.1x2"
        default:           return "circle.grid.2x2"
        }
    }
    static func pluriel(_ n: Int, _ mot: String) -> String {
        "\(n) \(mot)\(n > 1 ? "s" : "")"
    }
}
