import SwiftUI
import AppKit

// =========================================================================
// ENVOI : la feuille qui prépare le dossier du client (arborescence
// produite, barre de progression), puis propose d'envoyer par mail, de
// montrer dans le Finder ou de copier le récapitulatif.
// =========================================================================

struct FeuilleExport: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.dismiss) private var fermer
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique
    @State private var avant: Export? = nil
    @State private var lance = false

    /// L'export de CETTE feuille est terminé (pas un ancien).
    private var resultat: Export? {
        guard let e = moteur.dernierExport, !moteur.exportEnCours else { return nil }
        if let avant, avant.horodatage == e.horodatage, !statique { return nil }
        return e
    }
    private var echec: Bool { lance && !moteur.exportEnCours && resultat == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * echelle) {
            HStack(spacing: 12 * echelle) {
                Logo(taille: 42, tourne: moteur.exportEnCours)
                VStack(alignment: .leading, spacing: 2 * echelle) {
                    Text(resultat == nil ? "Préparation de l'envoi" : "Dossier prêt à envoyer")
                        .police(20, .heavy).foregroundColor(MMD.encre)
                    Text("Commande « \(moteur.nomCommande) »")
                        .police(12.5, .medium).foregroundColor(MMD.gris)
                }
                Spacer()
                if !moteur.exportEnCours {
                    Button { fermer() } label: { Image(systemName: "xmark") }
                        .buttonStyle(BoutonRond(taille: 30))
                        .keyboardShortcut(.cancelAction)
                }
            }

            VStack(alignment: .leading, spacing: 10 * echelle) {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "folder").police(11, .bold).foregroundColor(MMD.gris)
                    TitreSection(texte: "Arborescence")
                    Spacer()
                    if let r = resultat {
                        Etiquette(texte: Libelle.pluriel(r.fichiers.count, "fichier"), symbole: "doc")
                    }
                }
                ArbreFichiers(lignes: resultat?.relatifs ?? Export.arborescencePrevue(moteur),
                              racine: resultat?.nomExport ?? moteur.nomCommande,
                              enCours: moteur.exportEnCours,
                              empreintes: moteur.empreintes.map { ($0.index, $0.nom) })
            }
            .padding(16 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: 18, ombre: false)

            progression

            if let r = resultat, r.styleDefaut {
                Text("Aucun style n'était choisi : les tracés sont en « Traits soudés », le style par défaut.")
                    .police(11.5, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = resultat, !r.avertissements.isEmpty {
                ForEach(r.avertissements, id: \.self) { a in
                    HStack(alignment: .top, spacing: 8 * echelle) {
                        Image(systemName: "exclamationmark.triangle.fill").police(12, .bold).foregroundColor(MMD.roseFonce)
                        Text(a).police(12, .semibold).foregroundColor(MMD.encre.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12 * echelle).frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: 14, fond: MMD.roseClair, cerne: MMD.rose, ombre: false)
                }
            }

            HStack(spacing: 10 * echelle) {
                if let r = resultat {
                    ActionsEnvoi(moteur: moteur, export: r)
                    Spacer()
                } else if echec {
                    Text("La préparation n'a pas abouti — regarde le message en bas de la fenêtre.")
                        .police(12, .semibold).foregroundColor(MMD.roseFonce)
                    Spacer()
                    Button("Réessayer") { demarrer() }.buttonStyle(BoutonPrincipal())
                } else {
                    Text("Ne ferme pas l'app pendant la préparation.")
                        .police(12, .medium).foregroundColor(MMD.gris)
                    Spacer()
                }
            }
        }
        .padding(26 * echelle)
        .frame(width: 680 * echelle)
        .background(Papier())
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: moteur.exportEnCours)
        .onAppear {
            avant = moteur.dernierExport
            if !statique { demarrer() }
        }
    }

    private func demarrer() {
        lance = true
        moteur.exporter()
    }

    private var progression: some View {
        VStack(alignment: .leading, spacing: 8 * echelle) {
            HStack(spacing: 8 * echelle) {
                if moteur.exportEnCours {
                    Text(moteur.exportProgres?.texte.isEmpty == false
                         ? moteur.exportProgres!.texte : moteur.statut)
                        .police(12.5, .bold).foregroundColor(MMD.encre).lineLimit(1)
                    Spacer()
                    if let p = moteur.exportProgres {
                        Text("\(p.etape) / \(p.total)").police(11.5, .bold, .monospaced).foregroundColor(MMD.gris)
                    }
                } else if resultat != nil {
                    Image(systemName: "checkmark.circle.fill").police(13, .bold).foregroundColor(MMD.vert)
                    Text("Tout est prêt.").police(12.5, .bold).foregroundColor(MMD.encre)
                    Spacer()
                } else {
                    Text(echec ? "Interrompu." : "En attente…").police(12.5, .bold).foregroundColor(MMD.gris)
                    Spacer()
                }
            }
            BarreProgression(fraction: moteur.exportEnCours
                             ? (moteur.exportProgres?.fraction ?? 0.08)
                             : (resultat != nil ? 1 : 0),
                             indeterminee: moteur.exportEnCours && moteur.exportProgres == nil,
                             couleur: resultat != nil ? MMD.vert : MMD.encre)
        }
    }
}

/// Barre de progression dessinée à la main (capsule qui se remplit).
struct BarreProgression: View {
    var fraction: Double
    var indeterminee: Bool = false
    var couleur: Color = MMD.encre
    @Environment(\.echelle) private var echelle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MMD.encre.opacity(0.08))
                if indeterminee {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let x = (sin(t * 1.6) + 1) / 2
                        Capsule().fill(couleur.opacity(0.55))
                            .frame(width: geo.size.width * 0.28)
                            .offset(x: x * geo.size.width * 0.72)
                    }
                } else {
                    Capsule().fill(couleur)
                        .frame(width: max(8 * echelle, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
                }
            }
        }
        .frame(height: 8 * echelle)
    }
}

// MARK: - l'arbre des fichiers

/// Dessine une arborescence à partir de chemins relatifs (« Louis/Louis –
/// photo.png »), avec le dossier racine au-dessus.
struct ArbreFichiers: View {
    let lignes: [String]
    let racine: String
    var enCours: Bool = false
    /// (index, prénom) des empreintes : leur dossier prend leur couleur.
    var empreintes: [(Int, String)] = []
    @Environment(\.echelle) private var echelle

    /// L'empreinte dont `nom` est le dossier (« Louis », « Louis (2) »…).
    private func empreinte(pourDossier nom: String) -> Int? {
        let n = nom.lowercased()
        return empreintes.first { n == $0.1.lowercased() || n.hasPrefix($0.1.lowercased() + " (") }?.0
    }

    var body: some View {
        let arbre = Noeud.construire(lignes)
        VStack(alignment: .leading, spacing: 5 * echelle) {
            ligne(nom: racine.isEmpty ? "Commande" : racine, dossier: true, profondeur: 0, racine: true)
            ForEach(arbre.aplatir(), id: \.id) { (n: Noeud.Plat) in
                ligne(nom: n.nom, dossier: n.dossier, profondeur: n.profondeur, racine: false)
            }
            if lignes.isEmpty {
                Text("rien à envoyer pour l'instant")
                    .police(11, .medium).foregroundColor(MMD.grisClair)
                    .padding(.leading, 22 * echelle)
            }
        }
    }

    private func ligne(nom: String, dossier: Bool, profondeur: Int, racine: Bool) -> some View {
        HStack(spacing: 7 * echelle) {
            if profondeur > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<profondeur, id: \.self) { _ in
                        Rectangle().fill(MMD.encre.opacity(0.12))
                            .frame(width: 1 * echelle)
                            .padding(.horizontal, 8 * echelle)
                    }
                }
                .frame(height: 16 * echelle)
            }
            let e = (dossier && !racine && profondeur == 1) ? empreinte(pourDossier: nom) : nil
            if let e {
                NumeroEmpreinte(index: e, taille: 16)
            } else {
                Image(systemName: symbole(nom, dossier: dossier))
                    .police(12, dossier ? .bold : .medium)
                    .foregroundColor(dossier ? MMD.doreFonce : teinte(nom))
                    .frame(width: 16 * echelle)
            }
            Text(nom).police(racine ? 12.5 : 12, racine || dossier ? .heavy : .medium)
                .foregroundColor(e.map { TeinteEmpreinte.pour($0).fonce } ?? MMD.encre)
                .lineLimit(1).truncationMode(.middle)
            if racine && enCours {
                Logo(taille: 12, tourne: true, encre: MMD.gris, drapeau: false)
            }
        }
    }

    private func symbole(_ nom: String, dossier: Bool) -> String {
        if dossier { return "folder.fill" }
        let ext = (nom as NSString).pathExtension.lowercased()
        switch ext {
        case "svg":         return "scribble.variable"
        case "png", "jpg":  return "photo"
        case "txt":         return "doc.text"
        case "zip":         return "shippingbox"
        default:            return "doc"
        }
    }

    private func teinte(_ nom: String) -> Color {
        switch (nom as NSString).pathExtension.lowercased() {
        case "svg": return MMD.roseFonce
        case "png", "jpg": return MMD.drageeFonce
        default: return MMD.gris
        }
    }

    /// Nœud d'arborescence construit depuis des chemins relatifs.
    final class Noeud {
        let nom: String
        var enfants: [Noeud] = []
        var dossier: Bool
        init(nom: String, dossier: Bool) { self.nom = nom; self.dossier = dossier }

        struct Plat { let id: String; let nom: String; let dossier: Bool; let profondeur: Int }

        static func construire(_ lignes: [String]) -> Noeud {
            let racine = Noeud(nom: "", dossier: true)
            for l in lignes {
                let parts = l.split(separator: "/").map(String.init)
                var courant = racine
                for (i, p) in parts.enumerated() {
                    let dernier = i == parts.count - 1
                    if let e = courant.enfants.first(where: { $0.nom == p }) {
                        courant = e
                    } else {
                        let n = Noeud(nom: p, dossier: !dernier)
                        courant.enfants.append(n)
                        courant = n
                    }
                }
            }
            return racine
        }

        /// Fichiers avant dossiers, par ordre alphabétique, puis en profondeur.
        func aplatir(profondeur: Int = 1, prefixe: String = "") -> [Plat] {
            var out: [Plat] = []
            let tries = enfants.sorted {
                if $0.dossier != $1.dossier { return !$0.dossier }
                return $0.nom.localizedStandardCompare($1.nom) == .orderedAscending
            }
            for e in tries {
                let id = prefixe + "/" + e.nom
                out.append(Plat(id: id, nom: e.nom, dossier: e.dossier, profondeur: profondeur))
                if e.dossier { out += e.aplatir(profondeur: profondeur + 1, prefixe: id) }
            }
            return out
        }
    }
}

extension Export {
    /// L'arborescence qu'on s'attend à produire, d'après l'état courant
    /// (avant l'export, le moteur n'a encore rien écrit). Reflète le contrat
    /// de magasin_commandes.exporter ; une fois exporté, la vraie liste de
    /// fichiers la remplace.
    @MainActor
    static func arborescencePrevue(_ m: Moteur) -> [String] {
        var out = ["Récapitulatif.txt"]
        let style = Libelle.style(m.style) ?? m.style
        let styleFichier = style.lowercased() == "photo" ? "Photo découpée" : style
        let nom = m.nomCommande.isEmpty ? "Commande" : m.nomCommande
        if let f = Libelle.formeFichier(m.forme, nb: m.empreintes.count),
           m.formesDisponibles.contains(where: { $0.0 == m.forme }) {
            out.append("\(nom) – \(f) \(style).svg")
            out.append("\(nom) – \(f) \(style).png")
        }
        var vus: [String: Int] = [:]
        for e in m.empreintes {
            var p = e.nom.isEmpty ? "Empreinte \(e.index + 1)" : e.nom
            let n = (vus[p.lowercased()] ?? 0) + 1
            vus[p.lowercased()] = n
            if n > 1 { p += " (\(n))" }
            out.append("\(p)/\(p) – photo.png")
            out.append("\(p)/\(p) – \(styleFichier).svg")
            out.append("\(p)/\(p) – \(styleFichier).png")
        }
        return out
    }
}
