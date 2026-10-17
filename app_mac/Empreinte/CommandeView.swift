import SwiftUI
import AppKit

// =========================================================================
// COMMANDE : la fiche d'un client, en trois étapes toujours visibles et
// toujours accessibles — 1 Empreintes → 2 Composition → 3 Envoi.
// =========================================================================

struct CommandeView: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    // renommage de la commande
    @State private var editionNom = false
    @State private var texteNom = ""

    // ajout / suppression / refaire une empreinte
    @State private var demandePrenom = false
    @State private var aSupprimer: Int? = nil
    @State private var confirmeSuppression = false
    @State private var aRefaire: Int? = nil
    @State private var confirmeRefaire = false

    // envoi
    @State private var feuilleExport = false

    var body: some View {
        VStack(spacing: 0) {
            enTete
            BarreEtapes(moteur: moteur)
                .padding(.horizontal, 24 * echelle)
                .padding(.bottom, 14 * echelle)
            Group {
                switch moteur.etape {
                case .empreintes:
                    EtapeEmpreintes(moteur: moteur,
                                    ajouter: { demandePrenom = true },
                                    supprimer: { aSupprimer = $0; confirmeSuppression = true },
                                    refaire: { aRefaire = $0; confirmeRefaire = true })
                case .composition:
                    EtapeComposition(moteur: moteur)
                case .envoi:
                    EtapeEnvoi(moteur: moteur, preparer: { feuilleExport = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 18 * echelle)),
                removal: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: moteur.etape)
            PiedStatut(moteur: moteur)
        }
        .sheet(isPresented: $demandePrenom) {
            FeuilleNom(titre: "Nouvelle empreinte",
                       explication: "À qui appartient cette empreinte ? Un prénom suffit.",
                       invite: "Prénom",
                       libelleValider: "Scanner", symbole: "touchid") { n in
                moteur.ajouterEmpreinte(n.isEmpty
                    ? "Empreinte \(moteur.empreintes.count + 1)" : n)
            }
            .environment(\.echelle, echelle)
        }
        .sheet(isPresented: $feuilleExport) {
            FeuilleExport(moteur: moteur).environment(\.echelle, echelle)
        }
        .alert("Supprimer cette empreinte ?", isPresented: $confirmeSuppression) {
            Button("Supprimer", role: .destructive) {
                if let i = aSupprimer { moteur.supprimerEmpreinte(i) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(nomEmpreinte(aSupprimer).map {
                "L'empreinte de « \($0) » sera retirée de la commande."
            } ?? "")
        }
        .alert("Refaire cette empreinte ?", isPresented: $confirmeRefaire) {
            Button("Refaire") {
                if let i = aRefaire { moteur.refaireEmpreinte(i) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(nomEmpreinte(aRefaire).map {
                "On rescanne le doigt de « \($0) » ; l'ancienne empreinte est remplacée."
            } ?? "")
        }
        // Raccourcis « invisibles ».
        .background(
            Group {
                Button("") { moteur.allerEtape(.empreintes) }.keyboardShortcut("1", modifiers: .command)
                Button("") { moteur.allerEtape(.composition) }.keyboardShortcut("2", modifiers: .command)
                Button("") { moteur.allerEtape(.envoi) }.keyboardShortcut("3", modifiers: .command)
                Button("") { moteur.allerEtape(.envoi); feuilleExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                Button("") { if moteur.empreintes.count < Moteur.nbMax { demandePrenom = true } }
                    .keyboardShortcut("n", modifiers: .command)
                Button("") { if moteur.etape == .composition { moteur.enregistrer() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        )
    }

    private func nomEmpreinte(_ i: Int?) -> String? {
        guard let i, i < moteur.empreintes.count else { return nil }
        return moteur.empreintes[i].nom
    }

    // MARK: en-tête (nom de la commande modifiable sur place)

    private var enTete: some View {
        HStack(spacing: 14 * echelle) {
            Button {
                moteur.retourAccueil()
            } label: {
                HStack(spacing: 5 * echelle) {
                    Image(systemName: "chevron.left").police(12, .heavy)
                    Text("Commandes")
                }
            }
            .buttonStyle(BoutonDiscret())
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Retour aux commandes (⌘←)")

            Logo(taille: 36)

            if editionNom {
                ChampTexte(invite: "Nom de la commande", texte: $texteNom, auFocus: true) {
                    validerNom()
                }
                .frame(maxWidth: 340 * echelle)
                Button("OK") { validerNom() }.buttonStyle(BoutonDiscret())
            } else {
                Button {
                    texteNom = moteur.nomCommande
                    editionNom = true
                } label: {
                    HStack(spacing: 8 * echelle) {
                        Text(moteur.nomCommande.isEmpty ? "Commande" : moteur.nomCommande)
                            .police(20, .heavy)
                            .foregroundColor(MMD.encre).lineLimit(1)
                        Image(systemName: "pencil").police(12, .bold)
                            .foregroundColor(MMD.gris)
                    }
                }
                .buttonStyle(BoutonDiscret())
                .help("Renommer la commande")
            }

            Spacer(minLength: 8 * echelle)
            PastilleConnexion(moteur: moteur)
        }
        .padding(.horizontal, 24 * echelle).padding(.top, 16 * echelle).padding(.bottom, 12 * echelle)
    }

    private func validerNom() {
        editionNom = false
        moteur.renommerCommande(texteNom)
    }
}

// MARK: - la barre des trois étapes

struct BarreEtapes: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EtapeCommande.allCases, id: \.rawValue) { e in
                BoutonEtape(etape: e, courante: moteur.etape == e, faite: faite(e),
                            detail: detail(e), possible: possible(e)) {
                    moteur.allerEtape(e)
                }
                if e != .envoi {
                    Image(systemName: "chevron.right")
                        .police(11, .heavy).foregroundColor(MMD.encre.opacity(0.18))
                        .padding(.horizontal, 10 * echelle)
                }
            }
            Spacer()
        }
    }

    private func faite(_ e: EtapeCommande) -> Bool {
        switch e {
        case .empreintes:  return !moteur.empreintes.isEmpty
        case .composition: return moteur.renduEnregistre
        case .envoi:       return moteur.dernierExport != nil
        }
    }

    private func possible(_ e: EtapeCommande) -> Bool {
        e == .empreintes || !moteur.empreintes.isEmpty
    }

    private func detail(_ e: EtapeCommande) -> String {
        switch e {
        case .empreintes:
            let n = moteur.empreintes.count
            return n == 0 ? "à scanner" : Libelle.pluriel(n, "empreinte")
        case .composition:
            guard moteur.forme != nil else { return "forme et style" }
            let f = Libelle.forme(moteur.forme, nb: moteur.empreintes.count) ?? ""
            let s = Libelle.style(moteur.style) ?? ""
            return moteur.renduEnregistre ? "\(f) · \(s) · enregistré" : "\(f) · \(s)"
        case .envoi:
            return moteur.dernierExport != nil ? "dossier prêt" : "zip + mail"
        }
    }
}

struct BoutonEtape: View {
    let etape: EtapeCommande
    let courante: Bool
    let faite: Bool
    let detail: String
    let possible: Bool
    let action: () -> Void
    @Environment(\.echelle) private var echelle
    @State private var survol = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * echelle) {
                ZStack {
                    Circle().fill(courante ? MMD.encre : (faite ? MMD.vertClair : MMD.blanc))
                        .overlay(Circle().strokeBorder(
                            courante ? MMD.encre : (faite ? MMD.vert.opacity(0.5) : MMD.encre.opacity(0.18)),
                            lineWidth: 1.4 * echelle))
                    if faite && !courante {
                        Image(systemName: "checkmark").police(11, .heavy).foregroundColor(MMD.vert)
                    } else {
                        Text("\(etape.rawValue)").police(12.5, .heavy)
                            .foregroundColor(courante ? .white : MMD.encre.opacity(possible ? 0.7 : 0.35))
                    }
                }
                .frame(width: 27 * echelle, height: 27 * echelle)
                VStack(alignment: .leading, spacing: 1 * echelle) {
                    Text(etape.titre).police(13.5, .heavy)
                        .foregroundColor(courante ? MMD.encre : MMD.encre.opacity(possible ? 0.75 : 0.4))
                    Text(detail).police(10.5, .semibold)
                        .foregroundColor(MMD.gris.opacity(possible ? 1 : 0.6)).lineLimit(1)
                }
            }
            .padding(.vertical, 7 * echelle).padding(.leading, 7 * echelle).padding(.trailing, 14 * echelle)
            .background(Capsule().fill(courante ? MMD.blanc : (survol && possible ? MMD.voile : Color.clear))
                .overlay(Capsule().strokeBorder(courante ? MMD.encre.opacity(0.22) : Color.clear,
                                                lineWidth: 1.2 * echelle)))
            .compositingGroup()
            .shadow(color: MMD.encre.opacity(courante ? 0.06 : 0), radius: 10 * echelle, y: 4 * echelle)
            .animation(.easeOut(duration: 0.18), value: survol)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: courante)
        }
        .buttonStyle(.plain)
        .disabled(!possible)
        .onHover { survol = $0 }
        .help(possible ? "\(etape.titre) (⌘\(etape.rawValue))" : "Ajoute d'abord une empreinte")
    }
}

// MARK: - pied d'étape (navigation suivant / précédent)

struct PiedEtape<Gauche: View, Droite: View>: View {
    @ViewBuilder var gauche: () -> Gauche
    @ViewBuilder var droite: () -> Droite
    @Environment(\.echelle) private var echelle

    var body: some View {
        HStack(spacing: 10 * echelle) {
            gauche()
            Spacer()
            droite()
        }
        .padding(.horizontal, 24 * echelle).padding(.vertical, 12 * echelle)
        .background(MMD.creme.opacity(0.85))
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .top)
    }
}

// =========================================================================
// ÉTAPE 1 — les empreintes
// =========================================================================

struct EtapeEmpreintes: View {
    @ObservedObject var moteur: Moteur
    let ajouter: () -> Void
    let supprimer: (Int) -> Void
    let refaire: (Int) -> Void
    @Environment(\.echelle) private var echelle

    private var colonnes: [GridItem] {
        [GridItem(.adaptive(minimum: 296 * echelle, maximum: 380 * echelle),
                  spacing: 18 * echelle, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            Defilement {
                VStack(alignment: .leading, spacing: 16 * echelle) {
                    HStack(alignment: .firstTextBaseline, spacing: 10 * echelle) {
                        Text("Les empreintes à graver").police(17, .heavy).foregroundColor(MMD.encre)
                        Spacer()
                        Text("Jusqu'à \(Moteur.nbMax) empreintes · chaque doigt est scanné puis cadré")
                            .police(11.5, .medium).foregroundColor(MMD.gris)
                    }
                    if !moteur.connecte {
                        HStack(spacing: 10 * echelle) {
                            Image(systemName: "cable.connector").police(14, .bold).foregroundColor(MMD.doreFonce)
                            Text("Le capteur n'est pas connecté : branche-le en USB pour scanner. " +
                                 "Tu peux déjà renommer ou recadrer les empreintes existantes.")
                                .police(12, .semibold).foregroundColor(MMD.encre.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, 16 * echelle).padding(.vertical, 12 * echelle)
                        .carte(rayon: 16, fond: MMD.doreClair.opacity(0.55), cerne: MMD.dore.opacity(0.35), ombre: false)
                    }
                    LazyVGrid(columns: colonnes, spacing: 18 * echelle) {
                        ForEach(moteur.empreintes) { e in
                            CarteEmpreinte(moteur: moteur, empreinte: e,
                                           supprimer: { supprimer(e.index) },
                                           refaire: { refaire(e.index) })
                                .apparition(e.index)
                        }
                        if moteur.empreintes.count < Moteur.nbMax {
                            CarteAjout(premiere: moteur.empreintes.isEmpty,
                                       capteur: moteur.connecte, action: ajouter)
                                .apparition(moteur.empreintes.count)
                        }
                    }
                    if moteur.empreintes.count >= Moteur.nbMax {
                        Text("Maximum \(Moteur.nbMax) empreintes (trèfle à 4 feuilles).")
                            .police(11.5, .medium).foregroundColor(MMD.gris)
                    }
                }
                .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle).padding(.bottom, 30 * echelle)
            }
            PiedEtape {
                Text(moteur.empreintes.isEmpty
                     ? "Commence par scanner un doigt."
                     : "Quand toutes les empreintes sont là, passe à la composition.")
                    .police(12, .medium).foregroundColor(MMD.gris)
            } droite: {
                Button {
                    moteur.allerEtape(.composition)
                } label: {
                    HStack(spacing: 8 * echelle) {
                        Text("Composer la forme")
                        Image(systemName: "arrow.right").police(12.5, .heavy)
                    }
                }
                .buttonStyle(BoutonPrincipal(actif: !moteur.empreintes.isEmpty))
                .disabled(moteur.empreintes.isEmpty)
            }
        }
    }
}

/// Une empreinte : photo, prénom modifiable, actions.
struct CarteEmpreinte: View {
    @ObservedObject var moteur: Moteur
    let empreinte: EmpreinteItem
    let supprimer: () -> Void
    let refaire: () -> Void
    @State private var edition = false
    @State private var texte = ""
    @State private var survol = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                MMD.blanc
                if let img = moteur.apercusEmpreintes[empreinte.index] {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .scaledToFit().padding(16 * echelle)
                } else {
                    Chargement(texte: "photo en préparation…", taille: 36, encre: MMD.gris)
                }
            }
            .frame(height: 196 * echelle)
            .clipShape(CoinsHaut(rayon: MMD.rayon * echelle))
            .overlay(alignment: .topLeading) {
                Text("\(empreinte.index + 1)")
                    .police(11.5, .heavy).foregroundColor(.white)
                    .frame(width: 24 * echelle, height: 24 * echelle)
                    .background(Circle().fill(MMD.encre))
                    .padding(10 * echelle)
            }
            .overlay(alignment: .topTrailing) {
                if !empreinte.ajust.neutre {
                    Etiquette(texte: "placée", symbole: "hand.draw", fond: MMD.drageeClair, couleur: MMD.drageeFonce)
                        .padding(10 * echelle)
                }
            }
            .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)

            VStack(alignment: .leading, spacing: 10 * echelle) {
                HStack(spacing: 6 * echelle) {
                    if edition {
                        ChampTexte(invite: "Prénom", texte: $texte, auFocus: true) { valider() }
                        Button("OK") { valider() }.buttonStyle(BoutonDiscret())
                    } else {
                        Button {
                            texte = empreinte.nom
                            edition = true
                        } label: {
                            HStack(spacing: 7 * echelle) {
                                Text(empreinte.nom).police(16, .heavy).foregroundColor(MMD.encre).lineLimit(1)
                                Image(systemName: "pencil").police(11, .bold)
                                    .foregroundColor(MMD.gris).opacity(survol ? 1 : 0.5)
                            }
                        }
                        .buttonStyle(BoutonDiscret())
                        .padding(.leading, -10 * echelle)
                        .help("Renommer")
                        Spacer(minLength: 0)
                        Button { supprimer() } label: { Image(systemName: "trash") }
                            .buttonStyle(BoutonRond(taille: 30, couleur: MMD.rouge))
                            .help("Supprimer cette empreinte")
                    }
                }
                HStack(spacing: 6 * echelle) {
                    Button {
                        moteur.recadrerEmpreinte(empreinte.index)
                    } label: {
                        HStack(spacing: 5 * echelle) {
                            Image(systemName: "crop").police(11, .heavy)
                            Text("Ajuster le cadre").lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BoutonDoux(fond: MMD.drageeClair, texte: MMD.drageeFonce))
                    .help("Replacer l'ovale autour de l'empreinte")
                    Button {
                        refaire()
                    } label: {
                        HStack(spacing: 5 * echelle) {
                            Image(systemName: "arrow.counterclockwise").police(11, .heavy)
                            Text("Refaire").lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BoutonDoux(fond: MMD.roseClair, texte: MMD.roseFonce))
                    .disabled(!moteur.connecte)
                    .help(moteur.connecte ? "Rescanner ce doigt" : "Branche le capteur pour rescanner")
                }
            }
            .padding(.horizontal, 14 * echelle).padding(.vertical, 12 * echelle)
        }
        .carte(cerne: survol ? MMD.encre.opacity(0.3) : MMD.trait)
        .onHover { survol = $0 }
        .animation(.easeOut(duration: 0.18), value: survol)
    }

    private func valider() {
        edition = false
        moteur.renommerEmpreinte(empreinte.index, texte)
    }
}

/// La carte « + » pour ajouter une empreinte.
struct CarteAjout: View {
    let premiere: Bool
    let capteur: Bool
    let action: () -> Void
    @State private var survol = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12 * echelle) {
                ZStack {
                    Circle().fill(survol ? MMD.encre : MMD.blanc)
                        .overlay(Circle().strokeBorder(MMD.encre.opacity(survol ? 1 : 0.25), lineWidth: 1.6 * echelle))
                    Image(systemName: "plus").police(22, .heavy)
                        .foregroundColor(survol ? .white : MMD.encre)
                }
                .frame(width: 58 * echelle, height: 58 * echelle)
                Text(premiere ? "Scanner la première empreinte" : "Ajouter une empreinte")
                    .police(14.5, .heavy).foregroundColor(MMD.encre)
                Text(capteur ? "Le scan se lance quand on pose le doigt"
                             : "Branche d'abord le capteur")
                    .police(11.5, .medium).foregroundColor(MMD.gris)
                    .multilineTextAlignment(.center)
                Etiquette(texte: "⌘N", fond: MMD.voile, couleur: MMD.grisClair)
            }
            .frame(maxWidth: .infinity, minHeight: 300 * echelle)
            .background(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                .fill(survol ? MMD.blanc : MMD.blanc.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                .strokeBorder(MMD.encre.opacity(survol ? 0.5 : 0.2),
                              style: StrokeStyle(lineWidth: 1.6 * echelle, dash: [7 * echelle, 6 * echelle])))
            .contentShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: survol)
        }
        .buttonStyle(.plain)
        .disabled(!capteur)
        .opacity(capteur ? 1 : 0.6)
        .onHover { survol = $0 }
    }
}

// =========================================================================
// ÉTAPE 2 — la composition (forme, style, placement, taille réelle)
// =========================================================================

struct EtapeComposition: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle
    @Environment(\.statique) private var statique

    @State private var zoom: CGFloat = 1
    @State private var glisse: CGSize = .zero
    @State private var pointsParCm: CGFloat = 72 / 2.54

    /// L'empreinte en cours de placement et l'affichage « taille réelle »
    /// vivent dans le moteur : partagés entre le panneau et l'aperçu.
    private var selection: Int? {
        get { moteur.placement }
        nonmutating set { moteur.placement = newValue }
    }
    private var tailleReelle: Bool {
        get { moteur.tailleReelle }
        nonmutating set { moteur.tailleReelle = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18 * echelle) {
                zoneApercu
                panneau
                    .frame(width: 300 * echelle)
            }
            .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle).padding(.bottom, 16 * echelle)
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
        .onAppear { pointsParCm = TailleReelle.pointsParCm() }
        .onChange(of: moteur.empreintes.count) { _ in
            moteur.placement = nil
            zoom = 1
            glisse = .zero
        }
    }

    // MARK: panneau de droite

    private var panneau: some View {
        VStack(spacing: 12 * echelle) {
            Defilement {
                VStack(alignment: .leading, spacing: 14 * echelle) {
                    bloc("Forme", symbole: "heart") {
                    HStack(spacing: 8 * echelle) {
                        ForEach(moteur.formesDisponibles, id: \.0) { cle, nom in
                            VignetteChoix(choisie: moteur.forme == cle, titre: nom) {
                                FormeIcone(forme: cle, nb: moteur.empreintes.count,
                                           encre: MMD.encre, epaisseur: 1.8 * echelle)
                                    .padding(8 * echelle)
                            } action: { moteur.choisirForme(cle) }
                        }
                    }
                }
                bloc("Style de gravure", symbole: "scribble.variable") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8 * echelle), GridItem(.flexible())],
                              spacing: 8 * echelle) {
                        ForEach(Moteur.styles, id: \.cle) { s in
                            VignetteChoix(choisie: moteur.style == s.cle, titre: s.nom) {
                                StyleVignette(style: s.cle)
                                    .clipShape(RoundedRectangle(cornerRadius: 10 * echelle, style: .continuous))
                                    .padding(6 * echelle)
                            } action: { moteur.choisirStyle(s.cle) }
                        }
                    }
                    if let aide = Moteur.styles.first(where: { $0.cle == moteur.style })?.aide {
                        Text(aide).police(11, .medium).foregroundColor(MMD.gris)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
                .padding(.bottom, 4 * echelle)
            }
            blocEnregistrer            // toujours visible, hors du défilement
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

    /// Placement fin d'une empreinte dans son lobe (cœur, trèfle) : les
    /// puces vivent SUR l'aperçu, là où l'on glisse l'empreinte.
    private var pucesPlacement: some View {
        HStack(spacing: 6 * echelle) {
            Image(systemName: "hand.draw").police(11, .bold).foregroundColor(MMD.gris)
            Text("Placer").police(11, .heavy).foregroundColor(MMD.gris)
            ForEach(moteur.empreintes) { e in
                Puce(texte: e.nom, choisie: selection == e.index,
                     accent: MMD.roseFonce, fondChoisi: MMD.roseClair) {
                    moteur.placement = (selection == e.index) ? nil : e.index
                }
            }
        }
        .padding(.leading, 10 * echelle).padding(.trailing, 4 * echelle).padding(.vertical, 4 * echelle)
        .background(Capsule().fill(MMD.creme)
            .overlay(Capsule().strokeBorder(MMD.encre.opacity(0.1), lineWidth: 1 * echelle)))
    }

    /// La poignée de rotation de l'empreinte choisie, posée sur l'aperçu.
    private func cartePlacement(_ i: Int) -> some View {
        HStack(spacing: 12 * echelle) {
            CadranRotation(angle: lienAngle(i))
                .frame(width: 78 * echelle, height: 78 * echelle)
            VStack(alignment: .leading, spacing: 5 * echelle) {
                Text("Tu places « \(moteur.empreintes[i].nom) »")
                    .police(12, .heavy).foregroundColor(MMD.encre)
                Text("Glisse-la sur l'aperçu pour la déplacer ; tourne-la avec la poignée (ou ⌥ + molette).")
                    .police(10.5, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 190 * echelle, alignment: .leading)
                Button {
                    moteur.reinitialiserAjustement(i)
                } label: {
                    HStack(spacing: 5 * echelle) {
                        Image(systemName: "arrow.counterclockwise").police(10, .bold)
                        Text("Remettre au centre")
                    }
                }
                .buttonStyle(BoutonDiscret(couleur: MMD.roseFonce))
                .padding(.leading, -8 * echelle)
                .disabled(moteur.empreintes[i].ajust.neutre)
            }
        }
        .padding(12 * echelle)
        .background(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous).fill(MMD.creme)
            .overlay(RoundedRectangle(cornerRadius: 16 * echelle, style: .continuous)
                .strokeBorder(MMD.rose.opacity(0.7), lineWidth: 1.2 * echelle)))
        .compositingGroup()
        .shadow(color: MMD.encre.opacity(0.08), radius: 10 * echelle, y: 4 * echelle)
        .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
    }

    private var blocEnregistrer: some View {
        VStack(alignment: .leading, spacing: 10 * echelle) {
            Button {
                moteur.enregistrer()
            } label: {
                HStack(spacing: 8 * echelle) {
                    if moteur.composeEnCours {
                        Logo(taille: 16, tourne: true, encre: .white, drapeau: false)
                    } else {
                        Image(systemName: moteur.renduEnregistre ? "checkmark.seal.fill" : "square.and.arrow.down")
                            .police(13, .heavy)
                    }
                    Text(moteur.composeEnCours ? "Enregistrement…"
                         : (moteur.renduEnregistre ? "Rendu enregistré" : "Enregistrer le rendu"))
                    Spacer(minLength: 0)
                    Text("⌘S").police(10.5, .bold).opacity(0.55)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BoutonPrincipal(couleur: moteur.renduEnregistre ? MMD.vert : MMD.encre,
                                         actif: pretAEnregistrer))
            .disabled(!pretAEnregistrer)
            if let svg = moteur.cheminCompose {
                HStack(spacing: 6 * echelle) {
                    Text((svg as NSString).lastPathComponent)
                        .police(11, .semibold).foregroundColor(MMD.gris).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Voir") { moteur.montrerDansFinder(svg) }
                        .buttonStyle(BoutonDiscret())
                }
            } else {
                Text("Le SVG et le PNG à graver seront rangés dans le dossier de la commande.")
                    .police(11, .medium).foregroundColor(MMD.gris)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pretAEnregistrer: Bool {
        moteur.forme != nil && !moteur.composeEnCours && moteur.apercuCompose != nil
    }

    private func lienAngle(_ i: Int) -> Binding<Double> {
        Binding(
            get: { i < moteur.empreintes.count ? moteur.empreintes[i].ajust.angle : 0 },
            set: { nouvelle in
                guard i < moteur.empreintes.count else { return }
                let a = moteur.empreintes[i].ajust
                moteur.ajuster(i, dx: a.dx, dy: a.dy, angle: nouvelle)
            })
    }

    // MARK: la zone d'aperçu (zoom molette, glisser pour placer)

    private var zoneApercu: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                    .fill(MMD.blanc)
                if let img = moteur.apercuCompose {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .scaledToFit()
                        .padding(margeApercu)
                        .scaleEffect(zoom)
                        .offset(glisse)
                } else if !moteur.apercuEnCours {
                    VStack(spacing: 10 * echelle) {
                        FormeIcone(forme: moteur.forme ?? "coeur", nb: max(2, moteur.empreintes.count),
                                   encre: MMD.encre.opacity(0.2), epaisseur: 2 * echelle)
                            .frame(width: 70 * echelle, height: 70 * echelle)
                        Text("Choisis une forme à droite : l'aperçu se compose tout seul.")
                            .police(12.5, .medium)
                            .foregroundColor(MMD.gris)
                    }
                }
                if moteur.apercuEnCours {
                    ZStack {
                        MMD.blanc.opacity(moteur.apercuCompose == nil ? 1 : 0.8)
                        Chargement(texte: "Composition en cours…")
                    }
                }
                ZoneInteraction(
                    onPan: { dx, dy in deplacer(dx, dy, taille: geo.size) },
                    // dézoom très large : permet de juger l'empreinte à sa
                    // taille de gravure réelle (~1 cm à l'écran)
                    onZoom: { d in zoom = max(0.05, min(6, zoom * (1 + d * 0.005))) },
                    onRotation: { d in tourner(d) },
                    onDoubleClic: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        zoom = 1; glisse = .zero } },
                    main: true)

                // surcouche : étiquette, puces de placement, poignée, outils
                VStack {
                    HStack(alignment: .top) {
                        if let f = Libelle.forme(moteur.forme, nb: moteur.empreintes.count) {
                            Etiquette(texte: "\(f) · \(Libelle.style(moteur.style) ?? "")",
                                      symbole: Libelle.symboleForme(moteur.forme),
                                      fond: MMD.creme, couleur: MMD.encre)
                        }
                        Spacer()
                        if moteur.ajustementPossible { pucesPlacement }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 10 * echelle) {
                            if let i = selection, i < moteur.empreintes.count, moteur.ajustementPossible {
                                cartePlacement(i)
                            }
                            if tailleReelle { carteTailleReelle }
                        }
                        Spacer()
                        barreOutils
                    }
                }
                .padding(12 * echelle)
            }
            .clipShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
            .compositingGroup()
            .shadow(color: MMD.encre.opacity(0.05), radius: 14 * echelle, y: 5 * echelle)
        }
        .animation(.easeInOut(duration: 0.2), value: moteur.apercuEnCours)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: tailleReelle)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selection)
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
                .buttonStyle(BoutonRond(taille: 28, fond: tailleReelle ? MMD.doreClair : MMD.blanc,
                                        couleur: tailleReelle ? MMD.doreFonce : MMD.encre, cerne: false))
                .help("Taille réelle sur une médaille d'1 cm")
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
                        Medaille(diametre: pointsParCm * cm) {
                            if let img = moteur.apercuCompose {
                                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                            }
                        }
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

    private func zoomer(_ k: CGFloat) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            zoom = max(0.05, min(6, zoom * k))
        }
    }

    /// Marge autour de l'aperçu composé. Elle grandit avec l'interface, donc
    /// le calcul du rayon de lobe à l'écran DOIT lire la même valeur (sinon le
    /// glisser-ajuster se décale en grand écran).
    private var margeApercu: CGFloat { 18 * echelle }

    /// Glisser : déplace l'empreinte sélectionnée, sinon promène la vue.
    private func deplacer(_ dx: CGFloat, _ dy: CGFloat, taille: CGSize) {
        guard let i = selection, i < moteur.empreintes.count, moteur.ajustementPossible else {
            glisse.width += dx; glisse.height += dy
            return
        }
        let rayon = rayonLobeEcran(taille)
        let a = moteur.empreintes[i].ajust
        moteur.ajuster(i,
                       dx: a.dx + Double(dx / rayon),
                       dy: a.dy + Double(dy / rayon),
                       angle: a.angle)
    }

    /// Rayon d'un lobe mesuré À L'ÉCRAN (en points) : c'est l'unité de dx/dy
    /// du contrat, donc ce qu'il faut pour que l'empreinte suive la souris.
    /// L'aperçu est affiché en « scaledToFit » dans la zone (moins la marge,
    /// qui suit l'échelle) puis grossi par `zoom`. Tout est mesuré sur la
    /// taille RÉELLEMENT affichée : la conversion reste juste quelle que soit
    /// la taille de la fenêtre. Un facteur fixe ne marche pas non plus : le
    /// lobe occupe 44 % de la largeur du canevas pour le cœur mais 24 % pour
    /// le trèfle (voir formes.py).
    private func rayonLobeEcran(_ taille: CGSize) -> CGFloat {
        let img = moteur.apercuCompose?.size ?? .zero
        guard img.width > 0, img.height > 0 else { return 180 * zoom * echelle }
        let m = 2 * margeApercu
        let boite = CGSize(width: max(1, taille.width - m),
                           height: max(1, taille.height - m))
        let ajustement = min(boite.width / img.width, boite.height / img.height)
        let largeurAffichee = img.width * ajustement * zoom
        return max(20, CGFloat(fractionRayonLobe) * largeurAffichee)
    }

    /// Rayon de lobe rapporté à la LARGEUR du canevas produit par formes.py
    /// (RAYON_LOBE = 430 px, MARGE = 60 px) : cœur 980 px de large,
    /// trèfle à 3 feuilles 1797 px, trèfle à 4 feuilles 1857 px.
    private var fractionRayonLobe: Double {
        switch (moteur.forme, moteur.empreintes.count) {
        case ("coeur", _):  return 430.0 / 980.0
        case ("trefle", 4): return 430.0 / 1857.0
        default:            return 430.0 / 1797.0
        }
    }

    /// Molette + Option : rotation de l'empreinte sélectionnée.
    private func tourner(_ d: CGFloat) {
        guard let i = selection, i < moteur.empreintes.count, moteur.ajustementPossible else { return }
        let a = moteur.empreintes[i].ajust
        let angle = max(-180, min(180, a.angle + Double(d) * 0.25))
        moteur.ajuster(i, dx: a.dx, dy: a.dy, angle: angle)
    }
}

/// Vignette cliquable (forme ou style) : un dessin, un titre, un cadre qui
/// s'allume quand elle est choisie.
struct VignetteChoix<Dessin: View>: View {
    let choisie: Bool
    let titre: String
    @ViewBuilder var dessin: () -> Dessin
    let action: () -> Void
    @State private var survol = false
    @Environment(\.echelle) private var echelle

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6 * echelle) {
                dessin()
                    .frame(maxWidth: .infinity)
                    .frame(height: 52 * echelle)
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

/// Poignée de rotation : un cadran rond, on fait tourner le point.
struct CadranRotation: View {
    @Binding var angle: Double          // degrés, −180…180
    @Environment(\.echelle) private var echelle

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = min(geo.size.width, geo.size.height) / 2 - 6 * echelle
            let rad = CGFloat(angle - 90) * .pi / 180
            let poignee = CGPoint(x: c.x + r * cos(rad), y: c.y + r * sin(rad))
            ZStack {
                Circle().fill(MMD.blanc)
                    .overlay(Circle().strokeBorder(MMD.encre.opacity(0.15), lineWidth: 1.2 * echelle))
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(MMD.encre.opacity(i % 3 == 0 ? 0.35 : 0.15))
                        .frame(width: 1.4 * echelle, height: (i % 3 == 0 ? 6 : 3.5) * echelle)
                        .offset(y: -r + 4 * echelle)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
                Path { p in p.move(to: c); p.addLine(to: poignee) }
                    .stroke(MMD.roseFonce.opacity(0.6), style: StrokeStyle(lineWidth: 1.5 * echelle, lineCap: .round))
                Text("\(Int(angle.rounded()))°")
                    .police(11, .heavy, .monospaced).foregroundColor(MMD.encre)
                    .offset(y: 0)
                Circle().fill(MMD.roseFonce)
                    .frame(width: 14 * echelle, height: 14 * echelle)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2 * echelle))
                    .compositingGroup()
                    .shadow(color: MMD.encre.opacity(0.2), radius: 3 * echelle, y: 1 * echelle)
                    .position(poignee)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - c.x, dy = v.location.y - c.y
                    var a = Double(atan2(dy, dx)) * 180 / .pi + 90
                    if a > 180 { a -= 360 }
                    // aimant sur 0° et les multiples de 15°
                    let proche = (a / 15).rounded() * 15
                    if abs(a - proche) < 2.5 { a = proche }
                    angle = max(-180, min(180, a))
                })
        }
        .help("Fais tourner l'empreinte")
    }
}

// =========================================================================
// ÉTAPE 3 — l'envoi
// =========================================================================

struct EtapeEnvoi: View {
    @ObservedObject var moteur: Moteur
    let preparer: () -> Void
    @Environment(\.echelle) private var echelle

    var body: some View {
        VStack(spacing: 0) {
            Defilement {
                HStack(alignment: .top, spacing: 18 * echelle) {
                    VStack(alignment: .leading, spacing: 18 * echelle) {
                        recapitulatif
                        if let e = moteur.dernierExport { dernierEnvoi(e) }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18 * echelle) {
                        arbre
                        conseils
                    }
                    .frame(width: 340 * echelle)
                }
                .padding(.horizontal, 24 * echelle).padding(.top, 4 * echelle).padding(.bottom, 30 * echelle)
            }
            PiedEtape {
                Button {
                    moteur.allerEtape(.composition)
                } label: {
                    HStack(spacing: 6 * echelle) {
                        Image(systemName: "arrow.left").police(12, .heavy)
                        Text("Composition")
                    }
                }
                .buttonStyle(BoutonDiscret())
            } droite: {
                Button(action: preparer) {
                    HStack(spacing: 8 * echelle) {
                        Image(systemName: "paperplane.fill").police(13, .heavy)
                        Text(moteur.dernierExport == nil ? "Préparer le dossier à envoyer" : "Préparer à nouveau")
                        Text("⌘E").police(10.5, .bold).opacity(0.55)
                    }
                }
                .buttonStyle(BoutonPrincipal(actif: !moteur.exportEnCours))
                .disabled(moteur.exportEnCours)
            }
        }
    }

    private var recapitulatif: some View {
        VStack(alignment: .leading, spacing: 14 * echelle) {
            HStack(spacing: 10 * echelle) {
                TitreSection(texte: "Récapitulatif")
                Spacer()
                Etiquette(texte: Libelle.pluriel(moteur.empreintes.count, "empreinte"),
                          symbole: "hand.point.up.left.fill")
            }
            Text(moteur.nomCommande).police(22, .black).foregroundColor(MMD.encre)
            HStack(spacing: 14 * echelle) {
                ForEach(moteur.empreintes) { e in
                    VStack(spacing: 6 * echelle) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous).fill(MMD.blanc)
                            if let img = moteur.apercusEmpreintes[e.index] {
                                Image(nsImage: img).resizable().interpolation(.high)
                                    .scaledToFit().padding(5 * echelle)
                            }
                        }
                        .frame(width: 64 * echelle, height: 76 * echelle)
                        .overlay(RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous)
                            .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
                        Text(e.nom).police(11.5, .bold).foregroundColor(MMD.encre).lineLimit(1)
                    }
                }
                Spacer()
                if let img = moteur.apercuCompose {
                    VStack(spacing: 6 * echelle) {
                        Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                            .padding(8 * echelle)
                            .frame(width: 120 * echelle, height: 110 * echelle)
                            .background(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous).fill(MMD.blanc))
                            .overlay(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous)
                                .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
                        Text("rendu").police(11, .bold).foregroundColor(MMD.gris)
                    }
                }
            }
            Divider()
            HStack(spacing: 18 * echelle) {
                ligne("Forme", Libelle.forme(moteur.forme, nb: moteur.empreintes.count) ?? "pas encore choisie",
                      symbole: Libelle.symboleForme(moteur.forme), manque: moteur.forme == nil)
                ligne("Style", Libelle.style(moteur.style) ?? moteur.style, symbole: "scribble.variable")
                ligne("Rendu", moteur.renduEnregistre ? "enregistré" : "sera recalculé à l'envoi",
                      symbole: moteur.renduEnregistre ? "checkmark.seal.fill" : "clock", manque: false)
                Spacer()
            }
        }
        .padding(18 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private func ligne(_ titre: String, _ valeur: String, symbole: String, manque: Bool = false) -> some View {
        HStack(spacing: 8 * echelle) {
            Image(systemName: symbole).police(12, .bold)
                .foregroundColor(manque ? MMD.roseFonce : MMD.gris)
            VStack(alignment: .leading, spacing: 1 * echelle) {
                Text(titre.uppercased()).police(9.5, .heavy).tracking(1).foregroundColor(MMD.grisClair)
                Text(valeur).police(12.5, .bold).foregroundColor(manque ? MMD.roseFonce : MMD.encre)
            }
        }
    }

    private func dernierEnvoi(_ e: Export) -> some View {
        VStack(alignment: .leading, spacing: 12 * echelle) {
            HStack(spacing: 10 * echelle) {
                Image(systemName: "shippingbox.fill").police(16).foregroundColor(MMD.doreFonce)
                VStack(alignment: .leading, spacing: 1 * echelle) {
                    Text("Dossier prêt à envoyer").police(14, .heavy).foregroundColor(MMD.encre)
                    Text((e.zip as NSString).lastPathComponent)
                        .police(11.5, .medium).foregroundColor(MMD.gris).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            if !e.avertissements.isEmpty {
                ForEach(e.avertissements, id: \.self) { a in
                    HStack(alignment: .top, spacing: 6 * echelle) {
                        Image(systemName: "exclamationmark.triangle.fill").police(11, .bold).foregroundColor(MMD.roseFonce)
                        Text(a).police(11.5, .semibold).foregroundColor(MMD.encre.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ActionsEnvoi(moteur: moteur, export: e)
        }
        .padding(18 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(fond: MMD.doreClair.opacity(0.35), cerne: MMD.dore.opacity(0.35))
    }

    private var arbre: some View {
        VStack(alignment: .leading, spacing: 10 * echelle) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: "folder").police(11, .bold).foregroundColor(MMD.gris)
                TitreSection(texte: moteur.dernierExport == nil ? "Ce que contiendra l'envoi" : "Contenu de l'envoi")
            }
            ArbreFichiers(lignes: moteur.dernierExport?.relatifs ?? Export.arborescencePrevue(moteur),
                          racine: moteur.dernierExport?.nomExport ?? moteur.nomCommande)
        }
        .padding(16 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: 18, ombre: false)
    }

    private var conseils: some View {
        VStack(alignment: .leading, spacing: 8 * echelle) {
            HStack(spacing: 7 * echelle) {
                Image(systemName: "envelope").police(11, .bold).foregroundColor(MMD.gris)
                TitreSection(texte: "Comment ça se passe")
            }
            Text("Le dossier est préparé au nom du client (un sous-dossier par empreinte, " +
                 "avec sa photo et son tracé), puis compressé en zip. Ensuite, un clic ouvre " +
                 "un mail avec le zip en pièce jointe et le récapitulatif déjà rédigé : " +
                 "tu n'as plus qu'à mettre l'adresse et envoyer.")
                .police(11.5, .medium).foregroundColor(MMD.gris)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: 18, ombre: false)
    }
}

/// Les trois actions après un export : mail, Finder, presse-papiers.
struct ActionsEnvoi: View {
    @ObservedObject var moteur: Moteur
    let export: Export
    @Environment(\.echelle) private var echelle
    @State private var copie = false

    var body: some View {
        HStack(spacing: 8 * echelle) {
            Button {
                moteur.envoyerParMail()
            } label: {
                HStack(spacing: 7 * echelle) {
                    Image(systemName: "envelope.fill").police(12, .heavy)
                    Text("Envoyer par mail").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(BoutonPrincipal())
            Button {
                moteur.montrerDansFinder(export.zip)
            } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "folder").police(11.5, .bold)
                    Text("Montrer dans le Finder").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(BoutonSecondaire())
            Button {
                moteur.copierRecapitulatif()
                withAnimation { copie = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copie = false } }
            } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: copie ? "checkmark" : "doc.on.doc").police(11.5, .bold)
                    Text(copie ? "Copié !" : "Copier le récapitulatif").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(BoutonSecondaire())
        }
    }
}
