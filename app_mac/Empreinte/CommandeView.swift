import SwiftUI
import AppKit

// =========================================================================
// COMMANDE : la fiche d'un client. En haut la liste des empreintes (une
// carte par personne), en bas l'aperçu composé quand on choisit une forme.
// =========================================================================

struct CommandeView: View {
    @ObservedObject var moteur: Moteur
    @Environment(\.echelle) private var echelle

    // renommages
    @State private var editionNom = false
    @State private var texteNom = ""
    @State private var editionEmpreinte: Int? = nil
    @State private var textePrenom = ""

    // ajout d'une empreinte
    @State private var demandePrenom = false
    @State private var nouveauPrenom = ""

    // aperçu
    @State private var zoom: CGFloat = 1
    @State private var glisse: CGSize = .zero
    @State private var selection: Int? = nil     // empreinte en cours d'ajustement

    var body: some View {
        VStack(spacing: 0) {
            enTete
            ScrollView {
                VStack(alignment: .leading, spacing: 26 * echelle) {
                    sectionEmpreintes
                    if !moteur.empreintes.isEmpty { sectionApercu }
                    if moteur.dernierExport != nil || moteur.cheminCompose != nil {
                        sectionFichiers
                    }
                }
                .padding(.horizontal, 26 * echelle).padding(.top, 20 * echelle).padding(.bottom, 34 * echelle)
            }
            BarreStatut(moteur: moteur)
        }
        .alert("Nouvelle empreinte", isPresented: $demandePrenom) {
            TextField("Prénom", text: $nouveauPrenom)
            Button("Scanner") {
                let n = Moteur.nettoyer(nouveauPrenom)
                moteur.ajouterEmpreinte(n.isEmpty
                    ? "Empreinte \(moteur.empreintes.count + 1)" : n)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("À qui appartient cette empreinte ?")
        }
        .onChange(of: moteur.empreintes.count) { _ in
            selection = nil
            zoom = 1
            glisse = .zero
        }
    }

    // MARK: en-tête (nom de la commande modifiable sur place)

    private var enTete: some View {
        HStack(spacing: 14 * echelle) {
            Button {
                moteur.retourAccueil()
            } label: {
                HStack(spacing: 5 * echelle) {
                    Image(systemName: "chevron.left").police(12, .black)
                    Text("Commandes").police(13, .bold, .rounded)
                }
            }
            .buttonStyle(BoutonDiscret())

            LogoMarque(taille: 34 * echelle)

            if editionNom {
                TextField("Nom de la commande", text: $texteNom)
                    .textFieldStyle(.plain)
                    .police(18, .black, .rounded)
                    .padding(.horizontal, 8 * echelle).padding(.vertical, 4 * echelle)
                    .background(RoundedRectangle(cornerRadius: 8 * echelle).fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8 * echelle)
                            .strokeBorder(MMD.noir.opacity(0.35), lineWidth: 1.4 * echelle)))
                    .frame(maxWidth: 320 * echelle)
                    .onSubmit { validerNom() }
                Button("OK") { validerNom() }.buttonStyle(BoutonDiscret())
            } else {
                Text(moteur.nomCommande.isEmpty ? "Commande" : moteur.nomCommande)
                    .police(19, .black, .rounded)
                    .foregroundColor(MMD.noir).lineLimit(1)
                Button {
                    texteNom = moteur.nomCommande
                    editionNom = true
                } label: {
                    Image(systemName: "pencil").police(12, .bold)
                }
                .buttonStyle(BoutonDiscret()).help("Renommer la commande")
            }

            Spacer(minLength: 8 * echelle)
            PastilleConnexion(moteur: moteur)
        }
        .padding(.horizontal, 22 * echelle).padding(.top, 16 * echelle).padding(.bottom, 12 * echelle)
        .background(MMD.creme)
        .overlay(Rectangle().fill(MMD.trait).frame(height: 1), alignment: .bottom)
    }

    private func validerNom() {
        editionNom = false
        moteur.renommerCommande(texteNom)
    }

    // MARK: liste des empreintes

    private var sectionEmpreintes: some View {
        VStack(alignment: .leading, spacing: 12 * echelle) {
            TitreSection(texte: "Empreintes de la commande")

            if moteur.empreintes.isEmpty {
                HStack(spacing: 12 * echelle) {
                    Image(systemName: "hand.point.up.braille")
                        .police(22, .light)
                        .foregroundColor(MMD.noir.opacity(0.3))
                    Text("Aucune empreinte pour l'instant. Ajoute la première.")
                        .police(13.5, .medium).foregroundColor(MMD.gris)
                    Spacer()
                }
                .padding(18 * echelle).frame(maxWidth: .infinity, alignment: .leading)
                .carteMMD()
            } else {
                ForEach(moteur.empreintes) { e in
                    ligneEmpreinte(e).apparition(e.index)
                }
            }

            HStack(spacing: 10 * echelle) {
                Button {
                    nouveauPrenom = ""
                    demandePrenom = true
                } label: {
                    HStack(spacing: 7 * echelle) {
                        Image(systemName: "plus").police(12, .black)
                        Text("Ajouter une empreinte")
                            .police(13.5, .bold, .rounded)
                    }
                }
                .buttonStyle(BoutonSecondaire())
                .disabled(moteur.empreintes.count >= 4)

                if moteur.empreintes.count >= 4 {
                    Text("Maximum 4 empreintes (trèfle à 4 feuilles).")
                        .police(11.5).foregroundColor(MMD.gris)
                } else if !moteur.connecte {
                    Text("Capteur non connecté — branche-le pour scanner.")
                        .police(11.5).foregroundColor(MMD.rouge)
                }
            }
            .padding(.top, 2 * echelle)
        }
    }

    private func ligneEmpreinte(_ e: EmpreinteItem) -> some View {
        HStack(spacing: 14 * echelle) {
            miniature(e)
            if editionEmpreinte == e.index {
                TextField("Prénom", text: $textePrenom)
                    .textFieldStyle(.plain)
                    .police(14.5, .bold, .rounded)
                    .padding(.horizontal, 8 * echelle).padding(.vertical, 5 * echelle)
                    .background(RoundedRectangle(cornerRadius: 8 * echelle).fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8 * echelle)
                            .strokeBorder(MMD.noir.opacity(0.35), lineWidth: 1.4 * echelle)))
                    .frame(maxWidth: 220 * echelle)
                    .onSubmit { validerPrenom(e.index) }
                Button("OK") { validerPrenom(e.index) }.buttonStyle(BoutonDiscret())
            } else {
                VStack(alignment: .leading, spacing: 2 * echelle) {
                    Text(e.nom)
                        .police(15, .black, .rounded)
                        .foregroundColor(MMD.noir)
                    Text("Empreinte \(e.index + 1)")
                        .police(11, .medium)
                        .foregroundColor(MMD.gris)
                }
                Button {
                    textePrenom = e.nom
                    editionEmpreinte = e.index
                } label: {
                    Image(systemName: "pencil").police(11.5, .bold)
                }
                .buttonStyle(BoutonDiscret()).help("Renommer")
            }
            Spacer(minLength: 8 * echelle)
            Button {
                moteur.recadrerEmpreinte(e.index)
            } label: {
                HStack(spacing: 6 * echelle) {
                    Image(systemName: "crop").police(11.5, .bold)
                    Text("Re-cadrer").police(12.5, .bold, .rounded)
                }
            }
            .buttonStyle(BoutonSecondaire())
            Button {
                moteur.supprimerEmpreinte(e.index)
            } label: {
                Image(systemName: "trash").police(13, .bold)
            }
            .buttonStyle(BoutonDiscret()).help("Supprimer cette empreinte")
        }
        .padding(.horizontal, 14 * echelle).padding(.vertical, 12 * echelle)
        .carteMMD(rayon: 15)
    }

    private func validerPrenom(_ i: Int) {
        editionEmpreinte = nil
        moteur.renommerEmpreinte(i, textePrenom)
    }

    private func miniature(_ e: EmpreinteItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous)
                .fill(MMD.noir.opacity(0.04))
            if let img = moteur.apercusEmpreintes[e.index] {
                Image(nsImage: img).resizable().interpolation(.high)
                    .scaledToFit().padding(4 * echelle)
            } else {
                Image(systemName: "touchid")
                    .police(22, .light)
                    .foregroundColor(MMD.noir.opacity(0.25))
            }
        }
        .frame(width: 62 * echelle, height: 62 * echelle)
        .clipShape(RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12 * echelle, style: .continuous)
            .strokeBorder(MMD.trait, lineWidth: 1.2 * echelle))
    }

    // MARK: aperçu composé

    private var sectionApercu: some View {
        VStack(alignment: .leading, spacing: 14 * echelle) {
            TitreSection(texte: "Aperçu")

            VStack(alignment: .leading, spacing: 10 * echelle) {
                Text("Forme").police(12, .bold).foregroundColor(MMD.gris)
                HStack(spacing: 8 * echelle) {
                    ForEach(moteur.formesDisponibles, id: \.0) { cle, nom in
                        Puce(texte: nom, symbole: symboleForme(cle),
                             choisie: moteur.forme == cle) {
                            moteur.choisirForme(cle)
                        }
                    }
                    Spacer()
                }
                Text("Style").police(12, .bold).foregroundColor(MMD.gris)
                    .padding(.top, 2 * echelle)
                HStack(spacing: 8 * echelle) {
                    ForEach(Moteur.styles, id: \.cle) { s in
                        Puce(texte: s.nom, choisie: moteur.style == s.cle, accent: MMD.bleu) {
                            moteur.choisirStyle(s.cle)
                        }
                    }
                    Spacer()
                }
                if let aide = Moteur.styles.first(where: { $0.cle == moteur.style })?.aide {
                    Text(aide).police(11.5).foregroundColor(MMD.gris)
                }
            }

            if moteur.ajustementPossible { barreAjustement }

            zoneApercu

            HStack(spacing: 10 * echelle) {
                Button {
                    moteur.enregistrer()
                } label: {
                    HStack(spacing: 8 * echelle) {
                        if moteur.composeEnCours {
                            LogoQuiTourne(taille: 16, couleur: .white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .police(13, .black)
                        }
                        Text(moteur.composeEnCours ? "Enregistrement…" : "Enregistrer le rendu")
                            .police(14, .black, .rounded)
                    }
                }
                .buttonStyle(BoutonPrincipal(actif: pretAEnregistrer))
                .disabled(!pretAEnregistrer)

                Button {
                    moteur.exporter()
                } label: {
                    HStack(spacing: 8 * echelle) {
                        if moteur.exportEnCours {
                            LogoQuiTourne(taille: 15)
                        } else {
                            Image(systemName: "shippingbox")
                                .police(12.5, .black)
                        }
                        Text(moteur.exportEnCours ? "Préparation…" : "Exporter")
                            .police(13.5, .bold, .rounded)
                    }
                }
                .buttonStyle(BoutonSecondaire())
                .disabled(moteur.exportEnCours)

                Spacer()

                if zoom != 1 || glisse != .zero {
                    Button {
                        zoom = 1; glisse = .zero
                    } label: {
                        HStack(spacing: 6 * echelle) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .police(11, .bold)
                            Text("Vue d'ensemble")
                                .police(12.5, .bold, .rounded)
                        }
                    }
                    .buttonStyle(BoutonDiscret())
                }

                if moteur.forme != nil {
                    Button {
                        moteur.demanderApercu()
                    } label: {
                        HStack(spacing: 6 * echelle) {
                            Image(systemName: "arrow.clockwise").police(11.5, .bold)
                            Text("Actualiser").police(12.5, .bold, .rounded)
                        }
                    }
                    .buttonStyle(BoutonDiscret())
                    .disabled(moteur.apercuEnCours)
                }
            }
        }
    }

    private var pretAEnregistrer: Bool {
        moteur.forme != nil && !moteur.composeEnCours && moteur.apercuCompose != nil
    }

    private func symboleForme(_ cle: String) -> String {
        switch cle {
        case "coeur":  return "heart.fill"
        case "trefle": return "leaf.fill"
        default:       return "oval.fill"
        }
    }

    // MARK: ajustement empreinte par empreinte

    private var barreAjustement: some View {
        VStack(alignment: .leading, spacing: 9 * echelle) {
            HStack(spacing: 8 * echelle) {
                Text("Placer").police(12, .bold).foregroundColor(MMD.gris)
                ForEach(moteur.empreintes) { e in
                    Puce(texte: e.nom,
                         symbole: selection == e.index ? "hand.draw.fill" : nil,
                         choisie: selection == e.index,
                         accent: MMD.rouge) {
                        selection = (selection == e.index) ? nil : e.index
                    }
                }
                Spacer()
            }
            if let i = selection, i < moteur.empreintes.count {
                HStack(spacing: 12 * echelle) {
                    Text("Rotation").police(11.5, .semibold)
                        .foregroundColor(MMD.gris)
                    Slider(value: lienAngle(i), in: -45...45, step: 1)
                        .frame(width: 190 * echelle).tint(MMD.rouge)
                    Text("\(Int(moteur.empreintes[i].ajust.angle))°")
                        .police(11.5, .bold, .monospaced)
                        .foregroundColor(MMD.noir).frame(width: 38 * echelle, alignment: .leading)
                    Button {
                        moteur.reinitialiserAjustement(i)
                    } label: {
                        HStack(spacing: 5 * echelle) {
                            Image(systemName: "arrow.counterclockwise")
                                .police(11, .bold)
                            Text("Réinitialiser la position")
                                .police(12, .bold, .rounded)
                        }
                    }
                    .buttonStyle(BoutonDiscret())
                    Spacer()
                }
                Text("Glisse sur l'aperçu pour déplacer « \(moteur.empreintes[i].nom) » — " +
                     "molette + ⌥ pour la faire pivoter.")
                    .police(11).foregroundColor(MMD.gris)
            } else {
                Text("Choisis un prénom pour déplacer son empreinte dans la forme.")
                    .police(11).foregroundColor(MMD.gris)
            }
        }
        .padding(.horizontal, 14 * echelle).padding(.vertical, 12 * echelle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carteMMD(rayon: 15)
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
                    .fill(Color.white)
                if let img = moteur.apercuCompose {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .scaledToFit()
                        .padding(margeApercu)
                        .scaleEffect(zoom)
                        .offset(glisse)
                } else if !moteur.apercuEnCours {
                    VStack(spacing: 10 * echelle) {
                        Image(systemName: "square.dashed")
                            .police(30, .thin)
                            .foregroundColor(MMD.noir.opacity(0.25))
                        Text(moteur.forme == nil
                             ? "Choisis une forme ci-dessus pour composer le rendu."
                             : "Appuie sur une forme (ou « Actualiser ») pour composer le rendu.")
                            .police(12.5, .medium)
                            .foregroundColor(MMD.gris)
                    }
                }
                if moteur.apercuEnCours {
                    ZStack {
                        Color.white.opacity(moteur.apercuCompose == nil ? 1 : 0.82)
                        Chargement(texte: "Composition en cours…")
                    }
                }
                ZoneInteraction(
                    onPan: { dx, dy in deplacer(dx, dy, taille: geo.size) },
                    // dézoom très large : permet de juger l'empreinte à sa
                    // taille de gravure réelle (~1 cm à l'écran)
                    onZoom: { d in zoom = max(0.05, min(6, zoom * (1 + d * 0.005))) },
                    onRotation: { d in tourner(d) },
                    main: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MMD.rayon * echelle, style: .continuous)
                .strokeBorder(MMD.trait, lineWidth: 1.4 * echelle))
        }
        .frame(height: 400 * echelle)
        .animation(.easeInOut(duration: 0.2), value: moteur.apercuEnCours)
    }

    /// Marge autour de l'aperçu composé. Elle grandit avec l'interface, donc
    /// le calcul du rayon de lobe à l'écran DOIT lire la même valeur (sinon le
    /// glisser-ajuster se décale en grand écran).
    private var margeApercu: CGFloat { 14 * echelle }

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

    // MARK: fichiers produits

    private var sectionFichiers: some View {
        VStack(alignment: .leading, spacing: 12 * echelle) {
            TitreSection(texte: "Fichiers")
            if let svg = moteur.cheminCompose {
                HStack(spacing: 12 * echelle) {
                    Image(systemName: "checkmark.seal.fill")
                        .police(18).foregroundColor(MMD.bleu)
                    VStack(alignment: .leading, spacing: 2 * echelle) {
                        Text("Rendu enregistré")
                            .police(13.5, .bold, .rounded)
                            .foregroundColor(MMD.noir)
                        Text((svg as NSString).lastPathComponent)
                            .police(11.5).foregroundColor(MMD.gris).lineLimit(1)
                    }
                    Spacer()
                    Button("Voir dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: svg)])
                    }
                    .buttonStyle(BoutonSecondaire())
                }
                .padding(14 * echelle).frame(maxWidth: .infinity, alignment: .leading)
                .carteMMD(rayon: 15)
            }
            if let e = moteur.dernierExport {
                HStack(spacing: 12 * echelle) {
                    Image(systemName: "shippingbox.fill")
                        .police(18).foregroundColor(MMD.rouge)
                    VStack(alignment: .leading, spacing: 2 * echelle) {
                        Text("Dossier prêt à envoyer")
                            .police(13.5, .bold, .rounded)
                            .foregroundColor(MMD.noir)
                        Text((e.zip as NSString).lastPathComponent)
                            .police(11.5).foregroundColor(MMD.gris).lineLimit(1)
                    }
                    Spacer()
                    Button("Voir dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: e.zip)])
                    }
                    .buttonStyle(BoutonSecondaire())
                    Button {
                        moteur.envoyerParMail()
                    } label: {
                        HStack(spacing: 7 * echelle) {
                            Image(systemName: "envelope.fill")
                                .police(12, .bold)
                            Text("Envoyer par mail")
                                .police(13, .black, .rounded)
                        }
                    }
                    .buttonStyle(BoutonPrincipal())
                }
                .padding(14 * echelle).frame(maxWidth: .infinity, alignment: .leading)
                .carteMMD(rayon: 15)
            }
        }
    }
}
