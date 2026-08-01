import SwiftUI
import AppKit

// =========================================================================
// Identité de marque « Maman m'a dit » : palette, logo, échelle, styles.
// Sobre : fond crème, noir dominant, touches bleu / rouge (drapeau français).
// =========================================================================

enum MMD {
    static let creme = Color(red: 0.988, green: 0.976, blue: 0.953)   // fond
    static let carte = Color.white                                    // cartes
    static let noir  = Color(red: 0.075, green: 0.075, blue: 0.086)
    static let bleu  = Color(red: 0.000, green: 0.137, blue: 0.584)   // #002395
    static let rouge = Color(red: 0.929, green: 0.161, blue: 0.224)   // #ED2939
    static let gris  = Color(red: 0.42,  green: 0.42,  blue: 0.45)
    static let trait = Color(red: 0.075, green: 0.075, blue: 0.086).opacity(0.13)

    /// Rayon d'arrondi standard des cartes.
    static let rayon: CGFloat = 18

    /// Taille de fenêtre pour laquelle les mesures du code sont écrites.
    /// Au-delà, tout grossit proportionnellement (voir `Echelle`).
    static let largeurRef: CGFloat = 1050
    static let hauteurRef: CGFloat = 720
    static let echelleMax: CGFloat = 1.8
}

// MARK: - Échelle globale (l'interface grandit avec la fenêtre)

/// Facteur d'agrandissement de toute l'interface. Vaut 1 à la taille de
/// référence, jusqu'à `MMD.echelleMax` en grand écran. Injecté une seule fois
/// à la racine (ContentView) et lu partout par `@Environment(\.echelle)`.
private struct CleEchelle: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var echelle: CGFloat {
        get { self[CleEchelle.self] }
        set { self[CleEchelle.self] = newValue }
    }
}

enum Echelle {
    /// Jamais plus petit que le dessin d'origine, jamais plus de 1,8×.
    /// C'est la dimension la plus JUSTE qui commande : une fenêtre très
    /// large mais basse ne doit pas tout grossir au point de manquer de haut.
    static func pour(_ taille: CGSize) -> CGFloat {
        let r = min(taille.width / MMD.largeurRef, taille.height / MMD.hauteurRef)
        return min(max(r, 1), MMD.echelleMax)
    }
}

/// Police à l'échelle : `.police(14, .black, .rounded)` remplace
/// `.font(.system(size: 14, weight: .black, design: .rounded))`.
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
                _ dessin: Font.Design = .default) -> some View {
        modifier(PoliceMMD(taille: taille, poids: poids, dessin: dessin))
    }
}

// MARK: - Logo

/// Le logo d'origine de la maison, en image. On cherche le PNG dans le
/// bundle de l'app (`logo_mmd.png`, copié par construire.sh) puis dans le
/// dossier de développement. S'il est introuvable, on retombe sur le dessin
/// vectoriel `LogoMMD` : l'app reste utilisable en attendant le fichier.
enum ImageMarque {
    /// Lue une seule fois au premier affichage.
    static let logo: NSImage? = charger()

    static var disponible: Bool { logo != nil }

    /// Emplacement canonique du fichier à fournir (utilisé par construire.sh).
    static let nomFichier = "logo_mmd.png"

    private static func charger() -> NSImage? {
        let fm = FileManager.default
        var candidats: [String] = []

        // 1) embarqué dans l'app
        if let u = Bundle.main.url(forResource: "logo_mmd", withExtension: "png") {
            candidats.append(u.path)
        }
        if let res = Bundle.main.resourcePath {
            candidats.append((res as NSString).appendingPathComponent(nomFichier))
        }

        // 2) dossiers de développement (l'app tourne à côté des sources)
        var racines = [Bundle.main.bundleURL.deletingLastPathComponent().path,
                       (NSHomeDirectory() as NSString)
                           .appendingPathComponent("Desktop/empreintescanner"),
                       fm.currentDirectoryPath]
        racines = racines.reduce(into: [String]()) { acc, r in
            if !acc.contains(r) { acc.append(r) }
        }
        for r in racines {
            candidats.append((r as NSString).appendingPathComponent(nomFichier))
            candidats.append((r as NSString)
                .appendingPathComponent("app_mac/Empreinte/\(nomFichier)"))
        }

        for c in candidats where fm.fileExists(atPath: c) {
            if let img = NSImage(contentsOfFile: c), img.size.width > 0 { return img }
        }

        // 3) filet de sécurité : un fichier « logo….png » déposé à la racine du
        //    projet sous un autre nom. On ne fouille QUE le dossier du projet
        //    (reconnu à la présence de moteur_live.py), jamais un dossier
        //    quelconque : sinon n'importe quelle image « logo… » traînant à
        //    côté de l'app serait prise pour le logo de la maison.
        for r in racines {
            guard fm.fileExists(atPath:
                    (r as NSString).appendingPathComponent("moteur_live.py")) else { continue }
            for sous in ["", "app_mac/Empreinte"] {
                let d = sous.isEmpty ? r : (r as NSString).appendingPathComponent(sous)
                guard let noms = try? fm.contentsOfDirectory(atPath: d) else { continue }
                let trouves = noms.filter { n in
                    let b = n.lowercased()
                    return b.hasPrefix("logo")
                        && (b.hasSuffix(".png") || b.hasSuffix(".jpg")
                            || b.hasSuffix(".jpeg"))
                }.sorted()
                for n in trouves {
                    let c = (d as NSString).appendingPathComponent(n)
                    if let img = NSImage(contentsOfFile: c), img.size.width > 0 {
                        return img
                    }
                }
            }
        }
        return nil
    }
}

/// Le logo de la maison : l'image d'origine si elle est là, sinon le dessin
/// vectoriel. `couleur` = nil garde l'image telle quelle (couleurs d'origine) ;
/// une couleur explicite passe en silhouette teintée (petits indicateurs sur
/// fond sombre, filigrane…).
struct LogoMarque: View {
    var taille: CGFloat = 120
    var couleur: Color? = nil

    var body: some View {
        if let img = ImageMarque.logo {
            image(img)
                .frame(width: taille, height: taille)
                .accessibilityLabel("Maman m'a dit")
        } else {
            LogoMMD(taille: taille, couleur: couleur ?? MMD.noir)
        }
    }

    @ViewBuilder private func image(_ img: NSImage) -> some View {
        if let couleur {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable().interpolation(.high).scaledToFit()
                .foregroundColor(couleur)
        } else {
            Image(nsImage: img)
                .resizable().interpolation(.high).scaledToFit()
        }
    }
}

// MARK: - Logo vectoriel (repli quand le PNG d'origine n'est pas fourni)

/// Le logo « Maman m'a dit » redessiné en vectoriel : deux cercles épais,
/// le nom en capitales disposées le long de l'arc (légèrement irrégulier,
/// façon tampon fait main), trois points en bas et un petit drapeau français.
struct LogoMMD: View {
    var taille: CGFloat = 120
    var couleur: Color = MMD.noir
    /// Le dessin est pensé sur une grille de 100 × 100, puis mis à l'échelle.
    private let mot = Array("MAMAN M'A DIT")

    var body: some View {
        let u = taille / 100
        // En dessous de 46 pt les lettres deviennent illisibles : on ne garde
        // que les cercles, les points et le drapeau (repère qui tourne bien).
        let lisible = taille >= 46
        ZStack {
            Circle().strokeBorder(couleur, lineWidth: (lisible ? 5.5 : 8) * u)
            Circle().strokeBorder(couleur, lineWidth: (lisible ? 3.4 : 5) * u)
                .frame(width: 55 * u, height: 55 * u)
            if lisible {
                ForEach(Array(mot.enumerated()), id: \.offset) { i, c in
                    lettre(c, i: i, u: u)
                }
            }
            points(u, gros: !lisible)
            drapeau(u, gros: !lisible)
        }
        .frame(width: taille, height: taille)
        .accessibilityLabel("Maman m'a dit")
    }

    /// Une lettre posée sur l'arc, pivotée pour suivre le cercle.
    private func lettre(_ c: Character, i: Int, u: CGFloat) -> some View {
        let pas = 21.5                                  // degrés entre 2 lettres
        let base = (Double(i) - Double(mot.count - 1) / 2) * pas
        let b = Self.bruit(i)                           // -1…1, stable
        let angle = base + b * 2.2                      // léger côté fait main
        let rayon = (36.0 + b * 0.7) * Double(u)
        let rad = angle * .pi / 180
        return Text(String(c))
            .font(.system(size: (11.8 + b * 0.5) * u, weight: .black, design: .rounded))
            .foregroundColor(couleur)
            .rotationEffect(.degrees(angle))
            .offset(x: CGFloat(sin(rad) * rayon), y: CGFloat(-cos(rad) * rayon))
    }

    /// Les trois points, dans l'espace laissé en bas par le texte.
    private func points(_ u: CGFloat, gros: Bool) -> some View {
        let d = (gros ? 4.2 : 3.4) * u
        return HStack(spacing: (gros ? 3.4 : 2.6) * u) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(couleur).frame(width: d, height: d)
            }
        }
        .offset(y: (gros ? 30.5 : 31.5) * u)
    }

    /// Le petit drapeau français, sous les points.
    private func drapeau(_ u: CGFloat, gros: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(MMD.bleu)
            Rectangle().fill(Color.white)
            Rectangle().fill(MMD.rouge)
        }
        .frame(width: (gros ? 16 : 15) * u, height: (gros ? 8 : 9) * u)
        .overlay(Rectangle().strokeBorder(couleur, lineWidth: (gros ? 1.6 : 1.1) * u))
        .offset(y: (gros ? 37.5 : 38.5) * u)
    }

    /// Pseudo-hasard stable (même lettre = même décalage à chaque rendu).
    private static func bruit(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + 4.1414) * 43758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }
}

/// Indicateur de chargement de la maison : le logo tourne sur lui-même.
struct LogoQuiTourne: View {
    var taille: CGFloat = 46
    var couleur: Color? = nil
    @Environment(\.echelle) private var echelle
    @State private var angle: Double = 0

    var body: some View {
        LogoMarque(taille: taille * echelle, couleur: couleur)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// Chargement avec un mot d'explication sous le logo qui tourne.
struct Chargement: View {
    var texte: String
    var taille: CGFloat = 52
    var couleur: Color? = nil
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(spacing: 14 * echelle) {
            LogoQuiTourne(taille: taille, couleur: couleur)
            Text(texte)
                .police(12.5, .semibold)
                .foregroundColor((couleur ?? MMD.noir).opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Styles de boutons

/// Bouton plein noir (action principale).
struct BoutonPrincipal: ButtonStyle {
    var couleur: Color = MMD.noir
    var actif: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, couleur: couleur, actif: actif)
    }

    private struct Corps: View {
        let configuration: Configuration
        let couleur: Color
        let actif: Bool
        @Environment(\.echelle) private var echelle

        var body: some View {
            configuration.label
                .foregroundColor(.white)
                .padding(.vertical, 11 * echelle).padding(.horizontal, 20 * echelle)
                .background(
                    RoundedRectangle(cornerRadius: 13 * echelle, style: .continuous)
                        .fill(actif ? couleur : MMD.gris.opacity(0.35)))
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
        }
    }
}

/// Bouton blanc cerné de noir (action secondaire).
struct BoutonSecondaire: ButtonStyle {
    var couleur: Color = MMD.noir

    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration, couleur: couleur)
    }

    private struct Corps: View {
        let configuration: Configuration
        let couleur: Color
        @Environment(\.echelle) private var echelle

        var body: some View {
            let r = 13 * echelle
            configuration.label
                .foregroundColor(couleur)
                .padding(.vertical, 10 * echelle).padding(.horizontal, 17 * echelle)
                .background(
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                            .strokeBorder(couleur.opacity(0.85), lineWidth: 1.6 * echelle)))
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
        }
    }
}

/// Petit bouton discret (icône seule ou texte court).
struct BoutonDiscret: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Corps(configuration: configuration)
    }

    private struct Corps: View {
        let configuration: Configuration
        @Environment(\.echelle) private var echelle

        var body: some View {
            configuration.label
                .foregroundColor(MMD.noir.opacity(configuration.isPressed ? 0.5 : 0.8))
                .padding(.vertical, 6 * echelle).padding(.horizontal, 9 * echelle)
                .background(RoundedRectangle(cornerRadius: 9 * echelle, style: .continuous)
                    .fill(MMD.noir.opacity(configuration.isPressed ? 0.08 : 0.0)))
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Habillage des cartes

/// Carte blanche cernée d'un trait fin, comme le logo.
private struct CarteMMD: ViewModifier {
    let rayon: CGFloat
    let epaisseur: CGFloat
    let couleur: Color
    @Environment(\.echelle) private var echelle

    func body(content: Content) -> some View {
        let r = rayon * echelle
        return content
            .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(MMD.carte))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(couleur, lineWidth: epaisseur * echelle))
    }
}

extension View {
    func carteMMD(rayon: CGFloat = MMD.rayon, epaisseur: CGFloat = 1.4,
                  couleur: Color = MMD.trait) -> some View {
        modifier(CarteMMD(rayon: rayon, epaisseur: epaisseur, couleur: couleur))
    }
}

/// Puce de sélection (forme, style, prénom à ajuster).
struct Puce: View {
    let texte: String
    var symbole: String? = nil
    let choisie: Bool
    var accent: Color = MMD.noir
    let action: () -> Void
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * echelle) {
                if let symbole { Image(systemName: symbole).police(11, .bold) }
                Text(texte).police(12.5, .bold, .rounded)
            }
            .foregroundColor(choisie ? .white : MMD.noir)
            .padding(.vertical, 7 * echelle).padding(.horizontal, 13 * echelle)
            .background(
                Capsule().fill(choisie ? accent : Color.white)
                    .overlay(Capsule().strokeBorder(
                        choisie ? accent : MMD.noir.opacity(0.25), lineWidth: 1.4 * echelle)))
        }
        .buttonStyle(.plain)
    }
}

/// Titre de section, petit et espacé.
struct TitreSection: View {
    let texte: String
    @Environment(\.echelle) private var echelle
    var body: some View {
        Text(texte.uppercased())
            .tracking(1.4 * echelle)
            .police(11, .black, .rounded)
            .foregroundColor(MMD.gris)
    }
}
