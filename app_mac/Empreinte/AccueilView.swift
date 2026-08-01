import SwiftUI
import AppKit

// =========================================================================
// ACCUEIL : l'identité de la maison en haut, puis la grille des commandes
// déjà enregistrées. C'est le point de départ quand un client arrive.
// =========================================================================

struct AccueilView: View {
    @ObservedObject var moteur: Moteur

    @State private var demandeNom = false
    @State private var nouveauNom = ""
    @State private var aSupprimer: ResumeCommande? = nil
    @State private var confirmeSuppression = false
    @Environment(\.echelle) private var echelle

    /// Les cartes grandissent avec la fenêtre (sinon on se retrouve avec des
    /// vignettes minuscules perdues dans un grand écran).
    private var colonnes: [GridItem] {
        [GridItem(.adaptive(minimum: 210 * echelle, maximum: 280 * echelle),
                  spacing: 18 * echelle, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            enTete
            ScrollView {
                VStack(alignment: .leading, spacing: 16 * echelle) {
                    HStack(alignment: .firstTextBaseline) {
                        TitreSection(texte: "Commandes enregistrées")
                        Spacer()
                        if !moteur.commandes.isEmpty {
                            Text("\(moteur.commandes.count)")
                                .police(11, .black, .rounded)
                                .foregroundColor(MMD.gris)
                        }
                    }
                    if moteur.chargementListe && moteur.commandes.isEmpty {
                        Chargement(texte: "Lecture du dossier…", taille: 46)
                            .frame(maxWidth: .infinity).padding(.vertical, 50 * echelle)
                    } else if moteur.commandes.isEmpty {
                        vide
                    } else {
                        LazyVGrid(columns: colonnes, spacing: 18 * echelle) {
                            ForEach(Array(moteur.commandes.enumerated()), id: \.element.id) { i, c in
                                CarteCommande(resume: c,
                                              ouvrir: { moteur.ouvrirCommande(c.id) },
                                              supprimer: {
                                                  aSupprimer = c
                                                  confirmeSuppression = true
                                              })
                                    .apparition(i)
                            }
                        }
                    }
                }
                .padding(.horizontal, 26 * echelle)
                .padding(.top, 18 * echelle).padding(.bottom, 30 * echelle)
                .alert("Supprimer cette commande ?", isPresented: $confirmeSuppression) {
                    Button("Supprimer", role: .destructive) {
                        if let c = aSupprimer { moteur.supprimerCommande(c.id) }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text(aSupprimer.map {
                        "« \($0.nom) » ira à la corbeille du dossier de stockage. " +
                        "Rien n'est effacé définitivement."
                    } ?? "")
                }
            }
            BarreStatut(moteur: moteur)
        }
        .alert("Nouvelle commande", isPresented: $demandeNom) {
            TextField("Nom du client", text: $nouveauNom)
            Button("Créer") {
                let n = Moteur.nettoyer(nouveauNom)
                moteur.creerCommande(n.isEmpty ? "Commande" : n)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("À quel nom ? (le client, la référence…)")
        }
        .onAppear { moteur.chargerCommandes() }
    }

    // MARK: en-tête de marque

    private var enTete: some View {
        HStack(alignment: .center, spacing: 18 * echelle) {
            LogoMarque(taille: 88 * echelle)
            VStack(alignment: .leading, spacing: 3 * echelle) {
                Text("Maman m'a dit")
                    .police(30, .black, .rounded)
                    .foregroundColor(MMD.noir)
                Text("Empreintes gravées sur médaille")
                    .police(13, .medium)
                    .foregroundColor(MMD.gris)
                HStack(spacing: 0) {
                    Rectangle().fill(MMD.bleu)
                    Rectangle().fill(MMD.noir.opacity(0.08))
                    Rectangle().fill(MMD.rouge)
                }
                .frame(width: 78 * echelle, height: 4 * echelle).clipShape(Capsule())
                .padding(.top, 4 * echelle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10 * echelle) {
                HStack(spacing: 10 * echelle) {
                    PastilleConnexion(moteur: moteur)
                    MenuReglages(moteur: moteur)
                }
                Button {
                    nouveauNom = ""
                    demandeNom = true
                } label: {
                    HStack(spacing: 8 * echelle) {
                        Image(systemName: "plus").police(13, .black)
                        Text("Nouvelle commande")
                            .police(14.5, .black, .rounded)
                    }
                }
                .buttonStyle(BoutonPrincipal())
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.horizontal, 26 * echelle)
        .padding(.top, 22 * echelle).padding(.bottom, 18 * echelle)
        .background(MMD.creme)
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)
    }

    private var vide: some View {
        VStack(spacing: 12 * echelle) {
            LogoMarque(taille: 64 * echelle, couleur: MMD.noir.opacity(0.18))
            Text("Aucune commande pour l'instant")
                .police(15, .bold, .rounded)
                .foregroundColor(MMD.noir)
            Text("Crée une commande, scanne les empreintes,\npuis choisis la forme à graver.")
                .police(12.5).foregroundColor(MMD.gris)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 46 * echelle)
        .carteMMD()
    }
}

// MARK: - une carte de commande

struct CarteCommande: View {
    let resume: ResumeCommande
    let ouvrir: () -> Void
    let supprimer: () -> Void

    @State private var survol = false
    @State private var image: NSImage? = nil
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            vignette
            VStack(alignment: .leading, spacing: 4 * echelle) {
                Text(resume.nom)
                    .police(15, .black, .rounded)
                    .foregroundColor(MMD.noir).lineLimit(1)
                HStack(spacing: 6 * echelle) {
                    Text("\(resume.nb) empreinte\(resume.nb > 1 ? "s" : "")")
                    if let f = LibelleForme.texte(resume.forme) {
                        Text("·")
                        Text(f)
                    }
                }
                .police(11.5, .semibold).foregroundColor(MMD.gris)
                Text(resume.dateLisible)
                    .police(11).foregroundColor(MMD.gris.opacity(0.75))
            }
            .padding(.horizontal, 13 * echelle).padding(.vertical, 11 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .carteMMD(epaisseur: survol ? 2 : 1.4,
                  couleur: survol ? MMD.noir.opacity(0.85) : MMD.trait)
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Ouvrir") { ouvrir() }
                Divider()
                Button("Supprimer", role: .destructive) { supprimer() }
            } label: {
                Image(systemName: "ellipsis")
                    .police(13, .black)
                    .foregroundColor(MMD.noir)
                    .frame(width: 26 * echelle, height: 22 * echelle)
                    .background(Capsule().fill(Color.white.opacity(0.92))
                        .overlay(Capsule().strokeBorder(MMD.noir.opacity(0.18), lineWidth: 1)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(8 * echelle)
            .opacity(survol ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { ouvrir() }
        .onHover { survol = $0 }
        .contextMenu {
            Button("Ouvrir") { ouvrir() }
            Divider()
            Button("Supprimer", role: .destructive) { supprimer() }
        }
        .animation(.easeOut(duration: 0.15), value: survol)
    }

    private var vignette: some View {
        ZStack {
            Rectangle().fill(MMD.noir.opacity(0.035))
            if let img = image {
                Image(nsImage: img).resizable().interpolation(.high)
                    .scaledToFit().padding(10 * echelle)
            } else {
                VStack(spacing: 6 * echelle) {
                    Image(systemName: "touchid")
                        .police(34, .light)
                        .foregroundColor(MMD.noir.opacity(0.22))
                    Text("pas encore de rendu")
                        .police(10, .medium)
                        .foregroundColor(MMD.gris.opacity(0.7))
                }
            }
        }
        .frame(height: 132 * echelle)
        .clipShape(CoinsHaut(rayon: MMD.rayon * echelle))
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)
        .onAppear { chargerVignette() }
    }

    /// La vignette est lue une seule fois (pas à chaque rendu de la vue).
    private func chargerVignette() {
        guard image == nil, let chemin = resume.vignette else { return }
        image = Moteur.imageFraiche(chemin)
    }
}

/// Arrondit seulement les deux coins du haut (pour la vignette d'une carte).
struct CoinsHaut: Shape {
    var rayon: CGFloat
    func path(in r: CGRect) -> Path {
        let k = min(rayon, min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
        p.addQuadCurve(to: CGPoint(x: r.minX + k, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + k),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

enum LibelleForme {
    static func texte(_ cle: String?) -> String? {
        switch cle {
        case "coeur":  return "Cœur"
        case "trefle": return "Trèfle"
        case "simple": return "Simple"
        default:       return nil
        }
    }
}

// MARK: - réglages

struct MenuReglages: View {
    @ObservedObject var moteur: Moteur
    @ObservedObject var maj = MiseAJour.partagee
    @State private var panneauMAJ = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Menu {
            Text("Dossier de stockage")
            Text(moteur.dossierStockage.isEmpty
                 ? "Dossier par défaut" : moteur.dossierStockage)
            Button("Choisir un dossier…") { choisirDossier() }
            Button("Ouvrir dans le Finder") {
                guard !moteur.dossierStockage.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: moteur.dossierStockage)])
            }
            .disabled(moteur.dossierStockage.isEmpty)
            Divider()
            Text("Capteur")
            Text(moteur.capteurPret ? "Capteur prêt"
                 : (moteur.connecte ? "Connecté (capteur non confirmé)"
                    : "Aucun capteur détecté"))
            if let p = moteur.portActif { Text("Port : \(p)") }
            Button("Rechercher les capteurs") { moteur.rafraichirPorts() }
            Divider()
            Button("Rafraîchir la liste des commandes") { moteur.chargerCommandes() }
            Divider()
            Text("Application — version \(maj.versionInstallee)")
            Button(maj.disponible
                   ? "Mise à jour disponible (\(maj.info?.version ?? ""))…"
                   : "Rechercher une mise à jour…") {
                panneauMAJ = true
                maj.verifier()
            }
            if maj.retourPossible {
                Button("Revenir à la version \(maj.versionSauvegardee ?? "")…") {
                    panneauMAJ = true
                }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .police(13, .bold)
                .foregroundColor(MMD.noir)
                .frame(width: 30 * echelle, height: 28 * echelle)
                .background(Capsule().fill(Color.white)
                    .overlay(Capsule().strokeBorder(MMD.noir.opacity(0.2),
                                                    lineWidth: 1.3 * echelle)))
                // Pastille discrète : une mise à jour existe. Jamais de
                // fenêtre qui s'impose — maman clique quand elle veut.
                .overlay(alignment: .topTrailing) {
                    if maj.disponible {
                        Circle().fill(MMD.rouge)
                            .frame(width: 9 * echelle, height: 9 * echelle)
                            .overlay(Circle().strokeBorder(MMD.creme,
                                                           lineWidth: 1.5 * echelle))
                            .offset(x: 2 * echelle, y: -2 * echelle)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(maj.disponible ? "Réglages — une mise à jour est disponible" : "Réglages")
        .sheet(isPresented: $panneauMAJ) {
            PanneauMiseAJour(moteur: moteur, maj: maj)
        }
    }

    private func choisirDossier() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.prompt = "Choisir"
        p.message = "Où ranger les commandes (dossiers, rendus, exports) ?"
        if !moteur.dossierStockage.isEmpty {
            p.directoryURL = URL(fileURLWithPath: moteur.dossierStockage)
        }
        if p.runModal() == .OK, let url = p.url {
            moteur.changerDossier(url.path)
        }
    }
}
