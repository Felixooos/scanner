import SwiftUI
import AppKit

// =========================================================================
// ACCUEIL : l'identité de la maison en haut, la recherche, puis la grille
// des commandes déjà enregistrées. C'est le point de départ quand un
// client arrive.
// =========================================================================

struct AccueilView: View {
    @ObservedObject var moteur: Moteur

    @State private var demandeNom = false
    @State private var aSupprimer: ResumeCommande? = nil
    @State private var confirmeSuppression = false
    @State private var recherche = ""
    @State private var focusRecherche = 0
    @State private var reglages = false
    @Environment(\.echelle) private var echelle

    /// Les cartes grandissent avec la fenêtre (sinon on se retrouve avec des
    /// vignettes minuscules perdues dans un grand écran).
    private var colonnes: [GridItem] {
        [GridItem(.adaptive(minimum: 228 * echelle, maximum: 300 * echelle),
                  spacing: 20 * echelle, alignment: .top)]
    }

    private var filtrees: [ResumeCommande] {
        let q = recherche.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return moteur.commandes }
        return moteur.commandes.filter {
            $0.nom.localizedCaseInsensitiveContains(q)
                || $0.dateLisible.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            enTete
            Defilement {
                VStack(alignment: .leading, spacing: 18 * echelle) {
                    barreOutils
                    if moteur.chargementListe && moteur.commandes.isEmpty {
                        Chargement(texte: "Lecture du dossier…", taille: 50)
                            .frame(maxWidth: .infinity).padding(.vertical, 60 * echelle)
                    } else if moteur.commandes.isEmpty {
                        vide
                    } else if filtrees.isEmpty {
                        aucunResultat
                    } else {
                        LazyVGrid(columns: colonnes, spacing: 20 * echelle) {
                            ForEach(Array(filtrees.enumerated()), id: \.element.id) { i, c in
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
                .padding(.horizontal, 28 * echelle)
                .padding(.top, 6 * echelle).padding(.bottom, 34 * echelle)
            }
            PiedStatut(moteur: moteur)
        }
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
        .sheet(isPresented: $demandeNom) {
            FeuilleNom(titre: "Nouvelle commande",
                       explication: "À quel nom ? Le client, la famille, une référence…",
                       invite: "Nom du client",
                       libelleValider: "Créer la commande") { n in
                moteur.creerCommande(n.isEmpty ? "Commande" : n)
            }
            .environment(\.echelle, echelle)
        }
        .sheet(isPresented: $reglages) {
            FeuilleReglages(moteur: moteur).environment(\.echelle, echelle)
        }
        .onAppear { moteur.chargerCommandes() }
        // Raccourcis « invisibles » (boutons sans dessin).
        .background(
            Group {
                Button("") { focusRecherche += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { moteur.chargerCommandes() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { reglages = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        )
    }

    // MARK: en-tête de marque

    private var enTete: some View {
        HStack(alignment: .center, spacing: 20 * echelle) {
            Logo(taille: 78)
            VStack(alignment: .leading, spacing: 4 * echelle) {
                Text("Maman m'a dit")
                    .police(32, .black)
                    .foregroundColor(MMD.encre)
                Text("Empreintes gravées sur médaille")
                    .police(13, .medium)
                    .foregroundColor(MMD.gris)
                Tricolore().padding(.top, 5 * echelle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 12 * echelle) {
                HStack(spacing: 10 * echelle) {
                    PastilleConnexion(moteur: moteur)
                    BoutonReglages(ouvrir: { reglages = true })
                }
                Button {
                    demandeNom = true
                } label: {
                    HStack(spacing: 9 * echelle) {
                        Image(systemName: "plus").police(14, .black)
                        Text("Nouvelle commande")
                    }
                }
                .buttonStyle(BoutonPrincipal(grand: true))
                .keyboardShortcut("n", modifiers: .command)
                .help("Nouvelle commande (⌘N)")
            }
        }
        .padding(.horizontal, 28 * echelle)
        .padding(.top, 24 * echelle).padding(.bottom, 20 * echelle)
    }

    private var barreOutils: some View {
        HStack(spacing: 14 * echelle) {
            ChampTexte(invite: "Rechercher une commande…", texte: $recherche,
                       symbole: "magnifyingglass", demandeFocus: focusRecherche)
                .frame(maxWidth: 360 * echelle)
            Spacer()
            if !moteur.commandes.isEmpty {
                Text(recherche.isEmpty
                     ? Libelle.pluriel(moteur.commandes.count, "commande")
                     : "\(filtrees.count) sur \(moteur.commandes.count)")
                    .police(11.5, .bold)
                    .foregroundColor(MMD.gris)
            }
        }
        .padding(.top, 10 * echelle)
    }

    private var vide: some View {
        VStack(spacing: 14 * echelle) {
            Logo(taille: 84, encre: MMD.encre.opacity(0.22), drapeau: false)
                .padding(.bottom, 4 * echelle)
            Text("Aucune commande pour l'instant")
                .police(18, .heavy)
                .foregroundColor(MMD.encre)
            Text("Crée une commande au nom du client, scanne les empreintes,\n" +
                 "compose la forme à graver, puis envoie le dossier par mail.")
                .police(13, .medium).foregroundColor(MMD.gris)
                .multilineTextAlignment(.center)
            Button {
                demandeNom = true
            } label: {
                HStack(spacing: 8 * echelle) {
                    Image(systemName: "plus").police(13, .black)
                    Text("Créer la première commande")
                }
            }
            .buttonStyle(BoutonPrincipal())
            .padding(.top, 8 * echelle)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56 * echelle)
        .carte()
        .padding(.top, 8 * echelle)
    }

    private var aucunResultat: some View {
        VStack(spacing: 10 * echelle) {
            Image(systemName: "magnifyingglass")
                .police(28, .light).foregroundColor(MMD.grisClair)
            Text("Rien ne correspond à « \(recherche) »")
                .police(14.5, .bold).foregroundColor(MMD.encre)
            Button("Effacer la recherche") { recherche = "" }
                .buttonStyle(BoutonDiscret())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44 * echelle)
        .carte()
    }
}

/// La roue dentée, avec sa pastille discrète quand une mise à jour existe.
struct BoutonReglages: View {
    let ouvrir: () -> Void
    @ObservedObject var maj = MiseAJour.partagee
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: ouvrir) {
            Image(systemName: "gearshape.fill")
        }
        .buttonStyle(BoutonRond(taille: 34))
        // Pastille discrète : une mise à jour existe. Jamais de fenêtre qui
        // s'impose — maman clique quand elle veut.
        .overlay(alignment: .topTrailing) {
            if maj.disponible {
                Circle().fill(MMD.rouge)
                    .frame(width: 10 * echelle, height: 10 * echelle)
                    .overlay(Circle().strokeBorder(MMD.creme, lineWidth: 2 * echelle))
                    .offset(x: 1 * echelle, y: -1 * echelle)
            }
        }
        .help(maj.disponible ? "Réglages — une mise à jour est disponible (⌘,)" : "Réglages (⌘,)")
    }
}

// MARK: - une carte de commande

struct CarteCommande: View {
    let resume: ResumeCommande
    let ouvrir: () -> Void
    let supprimer: () -> Void

    @State private var survol = false
    @State private var image: NSImage? = nil
    @State private var menu = false
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            vignette
            VStack(alignment: .leading, spacing: 7 * echelle) {
                Text(resume.nom)
                    .police(15.5, .heavy)
                    .foregroundColor(MMD.encre).lineLimit(1)
                Text(resume.dateLisible)
                    .police(11.5, .medium).foregroundColor(MMD.gris)
                HStack(spacing: 6 * echelle) {
                    Etiquette(texte: Libelle.pluriel(resume.nb, "empreinte"),
                              symbole: "hand.point.up.left.fill")
                    if let f = Libelle.forme(resume.forme, nb: resume.nb), resume.nb > 0 {
                        Etiquette(texte: f, symbole: Libelle.symboleForme(resume.forme),
                                  fond: MMD.roseClair, couleur: MMD.roseFonce)
                    }
                }
                .padding(.top, 2 * echelle)
            }
            .padding(.horizontal, 15 * echelle).padding(.vertical, 13 * echelle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .carte(cerne: survol ? MMD.encre.opacity(0.45) : MMD.trait)
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(survol ? 0.10 : 0), radius: 18 * echelle, y: 8 * echelle)
        .scaleEffect(survol ? 1.012 : 1)
        .overlay(alignment: .topTrailing) {
            Button { menu.toggle() } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(BoutonRond(taille: 28, fond: MMD.blanc.opacity(0.95)))
            .padding(9 * echelle)
            .opacity(survol || menu ? 1 : 0)
            .popover(isPresented: $menu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4 * echelle) {
                    Button { menu = false; ouvrir() } label: {
                        Label("Ouvrir", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BoutonDiscret())
                    Button { menu = false; supprimer() } label: {
                        Label("Supprimer…", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BoutonDiscret(couleur: MMD.rouge))
                }
                .padding(10 * echelle).frame(width: 190 * echelle)
                .background(MMD.creme)
                .environment(\.echelle, echelle)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
        .onTapGesture { ouvrir() }
        .onHover { survol = $0 }
        .contextMenu {
            Button("Ouvrir") { ouvrir() }
            Divider()
            Button("Supprimer…", role: .destructive) { supprimer() }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: survol)
        .help("Ouvrir « \(resume.nom) »")
    }

    private var vignette: some View {
        // En capture, onAppear n'est pas garanti : on lit le fichier sur place.
        let img = image ?? (statique ? resume.vignette.flatMap(Moteur.imageFraiche) : nil)
        return ZStack {
            RoundedRectangle(cornerRadius: 0).fill(MMD.blanc)
            if let img {
                Image(nsImage: img).resizable().interpolation(.high)
                    .scaledToFit().padding(14 * echelle)
            } else {
                VStack(spacing: 8 * echelle) {
                    if resume.nb > 0 {
                        FormeIcone(forme: resume.forme ?? "simple", nb: resume.nb,
                                   encre: MMD.encre.opacity(0.22), epaisseur: 1.8 * echelle)
                            .frame(width: 60 * echelle, height: 60 * echelle)
                    } else {
                        Image(systemName: "touchid")
                            .police(36, .ultraLight)
                            .foregroundColor(MMD.encre.opacity(0.18))
                    }
                    Text(resume.nb > 0 ? "pas encore de rendu" : "commande vide")
                        .police(10, .semibold)
                        .foregroundColor(MMD.grisClair)
                }
            }
        }
        .frame(height: 150 * echelle)
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

// MARK: - réglages

/// La feuille des réglages : dossier de stockage, capteur, mise à jour.
struct FeuilleReglages: View {
    @ObservedObject var moteur: Moteur
    @ObservedObject var maj = MiseAJour.partagee
    @State private var panneauMAJ = false
    @Environment(\.dismiss) private var fermer
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * echelle) {
            HStack(spacing: 12 * echelle) {
                Logo(taille: 42)
                VStack(alignment: .leading, spacing: 2 * echelle) {
                    Text("Réglages").police(20, .heavy).foregroundColor(MMD.encre)
                    Text("Empreinte — version \(maj.versionInstallee)")
                        .police(12, .medium).foregroundColor(MMD.gris)
                }
                Spacer()
                Button { fermer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(BoutonRond(taille: 30))
                    .keyboardShortcut(.cancelAction)
            }

            section("Dossier de stockage", symbole: "folder") {
                Text(moteur.dossierStockage.isEmpty ? "Dossier par défaut" : moteur.dossierStockage)
                    .police(12, .semibold, .monospaced)
                    .foregroundColor(MMD.encre)
                    .lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Chaque commande y a son dossier (mosaïques, photos, rendus) ; " +
                     "les envois sont rangés dans « Exports », les suppressions dans la corbeille.")
                    .police(11.5).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8 * echelle) {
                    Button("Choisir un dossier…") { choisirDossier() }
                        .buttonStyle(BoutonSecondaire())
                    Button("Ouvrir dans le Finder") {
                        guard !moteur.dossierStockage.isEmpty else { return }
                        moteur.montrerDansFinder(moteur.dossierStockage)
                    }
                    .buttonStyle(BoutonDiscret())
                    .disabled(moteur.dossierStockage.isEmpty)
                }
            }

            section("Capteur", symbole: "sensor") {
                HStack(spacing: 8 * echelle) {
                    Circle().fill(moteur.capteurPret ? MMD.vert : (moteur.connecte ? MMD.dore : MMD.grisClair))
                        .frame(width: 9 * echelle, height: 9 * echelle)
                    Text(moteur.capteurPret ? "Capteur prêt"
                         : (moteur.connecte ? "Connecté (capteur non confirmé)" : "Aucun capteur détecté"))
                        .police(12.5, .bold).foregroundColor(MMD.encre)
                    if let p = moteur.portActif {
                        Text("· \(p)").police(11.5, .regular, .monospaced).foregroundColor(MMD.gris)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 8 * echelle) {
                    ForEach(moteur.ports) { p in
                        Puce(texte: p.nom, symbole: p.device == moteur.portActif ? "checkmark" : nil,
                             choisie: p.device == moteur.portActif) { moteur.choisirPort(p.device) }
                    }
                    Button("Rechercher") { moteur.rafraichirPorts() }
                        .buttonStyle(BoutonDiscret())
                }
            }

            section("Application", symbole: "sparkles") {
                HStack(spacing: 8 * echelle) {
                    Button {
                        panneauMAJ = true
                        maj.verifier()
                    } label: {
                        HStack(spacing: 7 * echelle) {
                            Image(systemName: maj.disponible ? "sparkles" : "arrow.triangle.2.circlepath")
                                .police(12, .heavy)
                            Text(maj.disponible
                                 ? "Installer la version \(maj.info?.version ?? "")…"
                                 : "Rechercher une mise à jour…")
                                .lineLimit(1).fixedSize()
                        }
                    }
                    .buttonStyle(BoutonPrincipal(couleur: maj.disponible ? MMD.doreFonce : MMD.encre))
                    if maj.retourPossible {
                        Button("Revenir à la version \(maj.versionSauvegardee ?? "")…") {
                            panneauMAJ = true
                        }
                        .buttonStyle(BoutonDiscret())
                    }
                    Spacer()
                }
                HStack(spacing: 8 * echelle) {
                    Button {
                        moteur.chargerCommandes()
                    } label: {
                        HStack(spacing: 6 * echelle) {
                            Image(systemName: "arrow.clockwise").police(11, .bold)
                            Text("Rafraîchir la liste des commandes")
                        }
                    }
                    .buttonStyle(BoutonDiscret())
                    .padding(.leading, -8 * echelle)
                    Spacer()
                }
            }
        }
        .padding(26 * echelle)
        .frame(width: 560 * echelle)
        .background(Papier())
        .sheet(isPresented: $panneauMAJ) {
            PanneauMiseAJour(moteur: moteur, maj: maj).environment(\.echelle, echelle)
        }
    }

    private func section<C: View>(_ titre: String, symbole: String,
                                  @ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10 * echelle) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: symbole).police(11, .bold).foregroundColor(MMD.gris)
                TitreSection(texte: titre)
            }
            contenu()
        }
        .padding(16 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: 18, ombre: false)
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
