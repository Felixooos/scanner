import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// =========================================================================
// MODE CAPTURES : `Empreinte --captures <dossier>` rend chaque écran clé en
// PNG avec des données factices (ImageRenderer), à deux tailles de fenêtre.
// C'est ce qui permet de VOIR l'interface sans capteur, sans moteur Python
// et sans relancer l'app en boucle. Aucune commande réelle n'est modifiée :
// on ne fait que lire quelques images existantes pour faire vrai.
// =========================================================================

enum Captures {
    @MainActor
    static func traiterArguments() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "--captures" else { return false }
        let dossier = args.count > 2 ? args[2]
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("captures")
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(atPath: dossier, withIntermediateDirectories: true)

        let m = Maquette()
        var n = 0
        let tailles: [(String, CGSize, CGFloat)] = [
            ("petite", CGSize(width: 1100, height: 760), 2),
            ("grande", CGSize(width: 2560, height: 1440), 1),
        ]
        for (suffixe, taille, scale) in tailles {
            for (nom, moteur) in scenes(m) {
                let vue = Racine(moteur: moteur)
                    .environment(\.statique, true)
                    .frame(width: taille.width, height: taille.height)
                if ecrire(vue, taille: taille, scale: scale,
                          chemin: "\(dossier)/\(nom)_\(suffixe).png") { n += 1 }
            }
            let echelle = Echelle.pour(taille)
            for (nom, feuille, fond) in feuilles(m) {
                let vue = ZStack {
                    Racine(moteur: fond).blur(radius: 10 * echelle)
                    MMD.encre.opacity(0.18)
                    feuille.environment(\.echelle, echelle)
                        .clipShape(RoundedRectangle(cornerRadius: 14 * echelle, style: .continuous))
                        .compositingGroup()
                        .shadow(color: MMD.encre.opacity(0.3), radius: 30 * echelle, y: 14 * echelle)
                }
                .environment(\.statique, true)
                .frame(width: taille.width, height: taille.height)
                if ecrire(vue, taille: taille, scale: scale,
                          chemin: "\(dossier)/\(nom)_\(suffixe).png") { n += 1 }
            }
        }
        print("→ \(n) captures écrites dans \(dossier)")
        return true
    }

    /// Rend une vue en PNG. Renvoie vrai si le fichier est écrit.
    @MainActor
    private static func ecrire<V: View>(_ vue: V, taille: CGSize, scale: CGFloat,
                                        chemin: String) -> Bool {
        let r = ImageRenderer(content: vue)
        r.proposedSize = ProposedViewSize(taille)
        r.scale = scale
        guard let cg = r.cgImage else {
            print("✗ rendu impossible : \(chemin)")
            return false
        }
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: chemin) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        let ok = CGImageDestinationFinalize(dest)
        print(ok ? "✓ \(chemin)" : "✗ \(chemin)")
        return ok
    }

    // MARK: les scènes

    /// Les écrans complets (nom de fichier, moteur préparé).
    @MainActor
    private static func scenes(_ m: Maquette) -> [(String, Moteur)] {
        var liste: [(String, Moteur)] = []
        liste.append(("01_accueil_vide", m.accueil(vide: true)))
        liste.append(("02_accueil", m.accueil(vide: false)))
        liste.append(("03_commande_vide", m.commande(nb: 0, etape: .empreintes)))
        liste.append(("04_commande_empreintes", m.commande(nb: 2, etape: .empreintes)))
        liste.append(("05_commande_composition", m.commande(nb: 2, etape: .composition,
                                                             forme: "coeur", placement: 1)))
        liste.append(("06_commande_composition_trefle", m.commande(nb: 3, etape: .composition,
                                                                    forme: "trefle", style: "sans",
                                                                    tailleReelle: true)))
        liste.append(("07_commande_envoi", m.commande(nb: 2, etape: .envoi, forme: "coeur")))
        liste.append(("08_commande_envoi_pret", m.commande(nb: 2, etape: .envoi, forme: "coeur",
                                                            exporte: true)))
        liste.append(("09_scan_attente", m.scan(poses: 0, phase: .attente)))
        liste.append(("10_scan_lecture", m.scan(poses: 2, phase: .scan)))
        liste.append(("11_scan_poses", m.scan(poses: 3, phase: .attente)))
        liste.append(("12_cadrage", m.cadrage()))
        liste.append(("13_accueil_erreur", m.accueil(vide: false, erreur: true)))
        return liste
    }

    /// Les feuilles (nom, feuille, écran de fond).
    @MainActor
    private static func feuilles(_ m: Maquette) -> [(String, AnyView, Moteur)] {
        let fond = m.accueil(vide: false)
        let commande = m.commande(nb: 2, etape: .envoi, forme: "coeur")
        let enCours = m.commande(nb: 2, etape: .envoi, forme: "coeur")
        enCours.exportEnCours = true
        enCours.exportProgres = ProgresExport(etape: 2, total: 4, texte: "Emma : photo et tracé…")
        let pret = m.commande(nb: 2, etape: .envoi, forme: "coeur", exporte: true)
        let maj = MiseAJour()
        maj.etat = .disponible
        maj.info = InfoVersion(version: "2.2", date: "2026-10-20",
                               notes: "• Nouvelle interface, plus claire et plus douce.\n" +
                                      "• L'envoi prépare un dossier lisible au nom du client.\n" +
                                      "• Les poses brutes sont conservées.",
                               zip: "", paquets: [])
        let majAJour = MiseAJour()
        majAJour.etat = .aJour
        return [
            ("20_feuille_nouvelle_commande",
             AnyView(FeuilleNom(titre: "Nouvelle commande",
                                explication: "À quel nom ? Le client, la famille, une référence…",
                                invite: "Nom du client", libelleValider: "Créer la commande",
                                defaut: "Famille Dupont") { _ in }), fond),
            ("21_feuille_reglages", AnyView(FeuilleReglages(moteur: fond)), fond),
            ("22_feuille_export_en_cours", AnyView(FeuilleExport(moteur: enCours)), commande),
            ("23_feuille_export_pret", AnyView(FeuilleExport(moteur: pret)), pret),
            ("24_mise_a_jour_disponible", AnyView(PanneauMiseAJour(moteur: fond, maj: maj)), fond),
            ("25_mise_a_jour_a_jour", AnyView(PanneauMiseAJour(moteur: fond, maj: majAJour)), fond),
        ]
    }
}

// MARK: - les données factices

/// Fabrique des moteurs « en carton » : aucun processus lancé, seulement
/// des états posés à la main et quelques vraies images lues sur le disque.
@MainActor
struct Maquette {
    let photos: [NSImage]            // photos normalisées (photo.png)
    let mosaiques: [NSImage]         // mosaïques brutes (mosaique.png)
    let vignettes: [String]          // vignette.png de commandes existantes
    let coeur: String?               // aperçus composés d'exemple
    let trefle: String?
    let simple: String?
    let dossierProjet: String

    init() {
        let fm = FileManager.default
        dossierProjet = Moteur.localiserScript().2
        let apercus = (dossierProjet as NSString).appendingPathComponent("photos/_apercus")
        func existe(_ p: String) -> String? { fm.fileExists(atPath: p) ? p : nil }
        coeur = existe((apercus as NSString).appendingPathComponent("apercu_coeur_contact.png"))
        trefle = existe((apercus as NSString).appendingPathComponent("apercu_trefle_traits.png"))
        simple = existe((apercus as NSString).appendingPathComponent("apercu_simple_contact.png"))

        // commandes réelles (LECTURE SEULE) : on pioche photos et vignettes
        let racine = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Empreintes MMD")
        var ph: [NSImage] = [], mo: [NSImage] = [], vi: [String] = []
        if let ids = try? fm.contentsOfDirectory(atPath: racine) {
            for id in ids.sorted() where !id.hasPrefix(".") {
                let d = (racine as NSString).appendingPathComponent(id)
                let v = (d as NSString).appendingPathComponent("vignette.png")
                if fm.fileExists(atPath: v) { vi.append(v) }
                let emp = (d as NSString).appendingPathComponent("empreintes")
                for e in (try? fm.contentsOfDirectory(atPath: emp)) ?? [] {
                    let p = ((emp as NSString).appendingPathComponent(e) as NSString)
                        .appendingPathComponent("photo.png")
                    let mq = ((emp as NSString).appendingPathComponent(e) as NSString)
                        .appendingPathComponent("mosaique.png")
                    if let img = Moteur.imageFraiche(p) { ph.append(img) }
                    if let img = Moteur.imageFraiche(mq) { mo.append(img) }
                }
            }
        }
        photos = ph.isEmpty ? [Maquette.dessin("contact"), Maquette.dessin("gabor")] : ph
        mosaiques = mo.isEmpty ? photos : mo
        vignettes = vi
    }

    /// Image de secours dessinée (si aucune commande réelle n'est lisible).
    static func dessin(_ style: String) -> NSImage {
        let r = ImageRenderer(content: StyleVignette(style: style).frame(width: 400, height: 500))
        r.scale = 1
        return r.nsImage ?? NSImage(size: NSSize(width: 400, height: 500))
    }

    private static let prenoms = ["Louis", "Emma", "Gaspard", "Jeanne"]

    private func base() -> Moteur {
        let m = Moteur()
        m.phase = .attente
        m.connecte = true
        m.capteurPret = true
        m.statut = "Capteur prêt — pose un doigt pour scanner."
        m.portActif = "/dev/cu.usbserial-0001"
        m.ports = [Port(device: "/dev/cu.usbserial-0001", nom: "Capteur (USB)", typique: true),
                   Port(device: "/dev/cu.Bluetooth-Incoming-Port", nom: "Bluetooth", typique: false)]
        m.dossierStockage = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Empreintes MMD")
        return m
    }

    func accueil(vide: Bool, erreur: Bool = false) -> Moteur {
        let m = base()
        m.ecran = .accueil
        if !vide {
            let noms = ["Famille Dupont", "Louis & Emma", "Mamie Jeanne", "Bébé Gaspard",
                        "Les jumeaux Martin", "Camille", "Cadeau de Noël", "Anniversaire Léa"]
            let formes: [(String?, Int)] = [("coeur", 2), ("trefle", 3), ("simple", 1), ("simple", 1),
                                            ("coeur", 2), (nil, 0), ("trefle", 4), ("simple", 1)]
            let images: [String?] = [coeur, trefle, vignettes.first, vignettes.dropFirst().first,
                                     nil, nil, nil, vignettes.last]
            for (i, nom) in noms.enumerated() {
                let jour = 17 - i * 3
                m.commandes.append(ResumeCommande(
                    id: "2026101\(i)_1200_\(i)", nom: nom,
                    date: String(format: "2026-10-%02dT14:3%d:00", max(1, jour), i),
                    nb: formes[i].1, forme: formes[i].0, style: "contact",
                    vignette: images[i]))
            }
        }
        if erreur {
            m.erreur = "Aucun ESP32 trouvé. Branche-le en USB, puis choisis le port."
            m.connecte = false
            m.capteurPret = false
            m.statut = "Branche le capteur en USB, puis choisis le port."
        }
        return m
    }

    func commande(nb: Int, etape: EtapeCommande, forme: String? = nil, style: String = "contact",
                  placement: Int? = nil, tailleReelle: Bool = false, exporte: Bool = false) -> Moteur {
        let m = base()
        m.ecran = .commande
        m.etape = etape
        m.idCommande = "20261017_143000_dupont"
        m.nomCommande = "Famille Dupont"
        m.style = style
        for i in 0..<nb {
            var e = EmpreinteItem(index: i, nom: Self.prenoms[i % 4])
            if i == 1 { e.ajust = Ajustement(dx: 0.12, dy: -0.05, angle: 8) }
            m.empreintes.append(e)
            m.apercusEmpreintes[i] = photos[i % photos.count]
        }
        if let forme {
            m.forme = forme
            let chemin = forme == "coeur" ? coeur : (forme == "trefle" ? trefle : simple)
            m.apercuCompose = chemin.flatMap(Moteur.imageFraiche)
            if etape != .composition || exporte {
                m.cheminCompose = "\(m.dossierStockage)/\(m.idCommande)/rendus/\(forme)_\(style).svg"
            }
        }
        m.placement = placement
        m.tailleReelle = tailleReelle
        if exporte {
            let base = "\(m.dossierStockage)/Exports/Famille Dupont"
            let f = Libelle.forme(forme, nb: nb) ?? "Cœur"
            let s = Libelle.style(style) ?? "Traits soudés"
            var fichiers = ["\(base)/Récapitulatif.txt",
                            "\(base)/Famille Dupont – \(f) \(s).svg",
                            "\(base)/Famille Dupont – \(f) \(s).png"]
            for e in m.empreintes {
                fichiers += ["\(base)/\(e.nom)/\(e.nom) – photo.png",
                             "\(base)/\(e.nom)/\(e.nom) – \(s).svg",
                             "\(base)/\(e.nom)/\(e.nom) – \(s).png"]
            }
            m.dernierExport = Export(
                dossier: base, zip: "\(m.dossierStockage)/Exports/Famille Dupont.zip",
                resume: "Commande « Famille Dupont »\nCréée le 17 octobre 2026\n" +
                        "2 empreintes : Louis et Emma.\nForme : cœur — Style : traits soudés.",
                nomExport: "Famille Dupont", fichiers: fichiers, forme: forme, style: style)
            m.statut = "Dossier prêt : Famille Dupont.zip"
        }
        return m
    }

    func scan(poses: Int, phase: Phase) -> Moteur {
        let m = commande(nb: 1, etape: .empreintes)
        m.ecran = .scan
        m.personneEnCours = "Emma"
        m.poses = poses
        m.phase = phase
        if poses > 0 {
            let img = mosaiques[0]
            m.apercu = img
            m.historiquePoses = Array(repeating: img, count: poses)
            m.statut = "Raccordée ! \(Libelle.pluriel(poses, "pose")) — décale un peu le doigt puis repose-le."
        } else {
            m.statut = "Empreinte de Emma — pose le doigt sur le capteur."
        }
        if phase == .scan { m.statut = "Scan en cours — garde le doigt appuyé" }
        return m
    }

    func cadrage() -> Moteur {
        let m = scan(poses: 3, phase: .attente)
        m.ecran = .cadrage
        m.statut = "Ajuste le cadre de Emma."
        return m
    }
}
