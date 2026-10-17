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
                NumeroEmpreinte(index: empreinte.index, taille: 26)
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
        .carte(cerne: survol ? TeinteEmpreinte.pour(empreinte.index).fonce.opacity(0.7) : MMD.trait)
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
                            .strokeBorder(TeinteEmpreinte.pour(e.index).moyen, lineWidth: 1.4 * echelle))
                        .overlay(alignment: .topLeading) {
                            NumeroEmpreinte(index: e.index, taille: 18).padding(4 * echelle)
                        }
                        Text(e.nom).police(11.5, .heavy)
                            .foregroundColor(TeinteEmpreinte.pour(e.index).fonce).lineLimit(1)
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
                ligne("Rendu", moteur.renduEnregistre ? "enregistré"
                      : (moteur.formeAssemblee ? "sera recalculé à l'envoi" : "une médaille par empreinte"),
                      symbole: moteur.renduEnregistre ? "checkmark.seal.fill" : (moteur.formeAssemblee ? "clock" : "circle.grid.2x2"),
                      manque: false)
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
                          racine: moteur.dernierExport?.nomExport ?? moteur.nomCommande,
                          empreintes: moteur.empreintes.map { ($0.index, $0.nom) })
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
