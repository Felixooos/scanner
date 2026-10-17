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
        liste.append(("05_composition_chaque", m.commande(nb: 2, etape: .composition, forme: "separees")))
        liste.append(("05b_composition_detail", m.commande(nb: 2, etape: .composition, forme: "separees",
                                                           detail: 0)))
        liste.append(("06_assembler_coeur", m.commande(nb: 2, etape: .composition, forme: "coeur",
                                                       placement: 1, vue: .assembler)))
        liste.append(("06b_assembler_ovale", m.commande(nb: 2, etape: .composition, forme: "ovale_lr",
                                                        tailleReelle: true, vue: .assembler)))
        liste.append(("06c_assembler_tete_beche", m.commande(nb: 2, etape: .composition, forme: "tete_beche",
                                                             placement: 0, vue: .assembler)))
        liste.append(("06d_assembler_trefle", m.commande(nb: 3, etape: .composition, forme: "trefle",
                                                         style: "sans", placement: 2, vue: .assembler)))
        liste.append(("06e_assembler_separees", m.commande(nb: 2, etape: .composition, forme: "separees",
                                                           vue: .assembler)))
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
    let ovaleLR: String?             // fabriqués pour les captures (EMPREINTE_FAUX)
    let teteBeche: String?
    let rendus: [String: NSImage]    // une empreinte seule, par style (repli)
    let dossierProjet: String
    /// Vraies sorties du moteur (dossier EMPREINTE_REELS) : les événements
    /// `apercu_pret` par forme (et leur variante « ajustée »), et les
    /// `rendu_empreinte` par index et style.
    let reels: [String: [String: Any]]        // "coeur", "coeur_ajuste", …
    let rendusReels: [Int: [String: NSImage]]
    let largeurRendusReels: [Int: Double]

    init() {
        let fm = FileManager.default
        dossierProjet = Moteur.localiserScript().2
        let apercus = (dossierProjet as NSString).appendingPathComponent("photos/_apercus")
        func existe(_ p: String) -> String? { fm.fileExists(atPath: p) ? p : nil }
        coeur = existe((apercus as NSString).appendingPathComponent("apercu_coeur_contact.png"))
        trefle = existe((apercus as NSString).appendingPathComponent("apercu_trefle_traits.png"))
        simple = existe((apercus as NSString).appendingPathComponent("apercu_simple_contact.png"))
        // PNG factices d'ovale coupé / tête-bêche (dossier donné par EMPREINTE_FAUX),
        // tant que le moteur ne les produit pas lui-même.
        let faux = ProcessInfo.processInfo.environment["EMPREINTE_FAUX"] ?? apercus
        ovaleLR = existe((faux as NSString).appendingPathComponent("apercu_ovale_lr_contact.png"))
        teteBeche = existe((faux as NSString).appendingPathComponent("apercu_tete_beche_contact.png"))

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

        // --- vraies sorties du moteur
        var ev: [String: [String: Any]] = [:]
        var rr: [Int: [String: NSImage]] = [:]
        var lr: [Int: Double] = [:]
        if let dossier = ProcessInfo.processInfo.environment["EMPREINTE_REELS"],
           let noms = try? fm.contentsOfDirectory(atPath: dossier) {
            for n in noms.sorted() where n.hasSuffix(".json") {
                let chemin = (dossier as NSString).appendingPathComponent(n)
                guard let data = fm.contents(atPath: chemin),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // le png est rangé à côté du json, quel que soit le chemin écrit dedans
                var o = obj
                o["png"] = (dossier as NSString).appendingPathComponent(
                    ((n as NSString).deletingPathExtension as NSString).appendingPathExtension("png") ?? n)
                let base = (n as NSString).deletingPathExtension      // apercu_coeur_contact_ajuste
                if base.hasPrefix("apercu_") {
                    var cle = String(base.dropFirst("apercu_".count))  // coeur_contact_ajuste
                    let ajuste = cle.hasSuffix("_ajuste")
                    if ajuste { cle = String(cle.dropLast("_ajuste".count)) }
                    if let r = cle.range(of: "_contact") { cle = String(cle[..<r.lowerBound]) }
                    ev[ajuste ? cle + "_ajuste" : cle] = o
                } else if base.hasPrefix("rendu_"),
                          let i = o["index"] as? Int, let st = Moteur.cleStyle(o["style"] as? String),
                          let png = o["png"] as? String, let img = Moteur.imageFraiche(png) {
                    var d = rr[i] ?? [:]
                    d[st] = img
                    rr[i] = d
                    if let l = o["largeur_forme"] as? Double { lr[i] = l }
                }
            }
        }
        reels = ev
        rendusReels = rr
        largeurRendusReels = lr
        var r: [String: NSImage] = [:]
        for st in ["sans", "gabor", "photo"] {
            if let img = Moteur.imageFraiche((apercus as NSString).appendingPathComponent("apercu_simple_\(st).png")) {
                r[st] = img
            }
        }
        // le vieil échantillon « contact » montre deux doigts : une vraie
        // vignette de commande (une seule empreinte, traits soudés) fait mieux
        if let v = vi.first(where: { $0.contains("perrier") }) ?? vi.first, let img = Moteur.imageFraiche(v) {
            r["contact"] = img
        }
        rendus = r
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

    /// Les lobes « comme le moteur les enverrait » pour une forme donnée.
    func lobesFactices(_ forme: String, nb: Int, ajusts: [Ajustement]) -> [Lobe] {
        func l(_ i: Int, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ a: Double, _ z: [Double]) -> Lobe {
            let aj = i < ajusts.count ? ajusts[i] : Ajustement()
            return Lobe(index: i, cx: cx + aj.dx * rx, cy: cy + aj.dy * ry, rx: rx, ry: ry,
                        angle: a + aj.angle, zone: z)
        }
        switch forme {
        case "coeur":      // valeurs mesurées sur le vrai moteur
            return [l(0, 0.2745, 0.4794, 0.2133, 0.4125, -20, [0.0612, 0.0669, 0.4888, 0.8930]),
                    l(1, 0.7250, 0.4811, 0.2138, 0.4142, 20, [0.5112, 0.0669, 0.9398, 0.8963])]
        case "ovale_lr":
            return [l(0, 0.5, 0.5, 0.4272, 0.4398, 0, [0.0728, 0.0612, 0.4867, 0.9398]),
                    l(1, 0.5, 0.5, 0.4272, 0.4398, 0, [0.5134, 0.0612, 0.9284, 0.9398])]
        case "tete_beche":
            return [l(0, 0.5, 0.5, 0.4272, 0.4398, 0, [0.0728, 0.0602, 0.9284, 0.4890]),
                    l(1, 0.5, 0.5, 0.4272, 0.4398, 180, [0.0728, 0.5110, 0.9284, 0.9408])]
        case "trefle":
            // rayon de lobe 430 px sur 1797 (3) / 1857 (4) px, ovale 0,8 × rayon
            let r = nb == 4 ? 430.0 / 1857.0 : 430.0 / 1797.0
            let rx = r * 0.8
            let pts: [(Double, Double, Double)] = nb == 4
                ? [(0.5, 0.27, 0), (0.73, 0.5, 90), (0.5, 0.73, 180), (0.27, 0.5, 270)]
                : [(0.5, 0.27, 0), (0.70, 0.62, 120), (0.30, 0.62, 240)]
            return pts.enumerated().map { i, p in
                l(i, p.0, p.1, rx, r, p.2, [p.0 - r, p.1 - r, p.0 + r, p.1 + r])
            }
        default:
            // planche « séparées » : une médaille par empreinte, côte à côte
            let n = max(1, nb)
            return (0..<n).map { i in
                let x0 = Double(i) / Double(n), x1 = Double(i + 1) / Double(n)
                return l(i, (x0 + x1) / 2, 0.5, 0.45 / Double(n), 0.45, 0, [x0 + 0.02, 0.05, x1 - 0.02, 0.95])
            }
        }
    }

    func commande(nb: Int, etape: EtapeCommande, forme: String? = nil, style: String = "contact",
                  placement: Int? = nil, tailleReelle: Bool = false, exporte: Bool = false,
                  vue: VueComposition = .chaque, detail: Int? = nil) -> Moteur {
        let m = base()
        m.ecran = .commande
        m.etape = etape
        m.idCommande = "20261017_143000_dupont"
        m.nomCommande = "Famille Dupont"
        m.style = style
        for i in 0..<nb {
            var e = EmpreinteItem(index: i, nom: Self.prenoms[i % 4])
            // le même ajust que la sortie moteur « _ajuste » du dossier réel
            if i == 1 { e.ajust = Ajustement(dx: 0.12, dy: -0.05, angle: 15) }
            m.empreintes.append(e)
            m.apercusEmpreintes[i] = photos[i % photos.count]
        }
        if let forme {
            m.forme = forme
            // d'abord la vraie sortie du moteur (variante ajustée si l'empreinte 2 l'est)
            let ajustee = nb == 2 && !m.empreintes[1].ajust.neutre
            if let ev = (ajustee ? reels[forme + "_ajuste"] : nil) ?? reels[forme],
               let png = ev["png"] as? String, let img = Moteur.imageFraiche(png) {
                m.apercuCompose = img
                m.lobes = Lobe.lire(ev["lobes"])
                m.largeurForme = ev["largeur_forme"] as? Double
                if !ajustee { for i in 0..<nb { m.empreintes[i].ajust = Ajustement() } }
            } else {
                let chemin: String?
                switch forme {
                case "coeur":      chemin = coeur
                case "trefle":     chemin = trefle
                case "ovale_lr":   chemin = ovaleLR ?? coeur
                case "tete_beche": chemin = teteBeche ?? coeur
                default:           chemin = simple
                }
                m.apercuCompose = chemin.flatMap(Moteur.imageFraiche)
                m.lobes = lobesFactices(forme, nb: nb, ajusts: m.empreintes.map(\.ajust))
                m.largeurForme = forme == "coeur" ? 0.88 : 0.85
            }
            m.apercuForme = forme
            m.apercuStyle = style
            m.ajustsApercu = Dictionary(uniqueKeysWithValues: m.empreintes.map { ($0.index, $0.ajust) })
            if etape != .composition || exporte {
                m.cheminCompose = "\(m.dossierStockage)/\(m.idCommande)/rendus/\(forme)_\(style).svg"
            }
        }
        for i in 0..<nb {
            // vrais rendus seuls quand on les a, sinon les anciens échantillons
            var parStyle = rendus
            for (st, img) in rendusReels[i] ?? [:] { parStyle[st] = img }
            m.rendusEmpreintes[i] = parStyle
            m.largeurFormeEmpreinte[i] = largeurRendusReels[i] ?? 0.856
        }
        m.vueComposition = vue
        m.detailEmpreinte = detail
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
