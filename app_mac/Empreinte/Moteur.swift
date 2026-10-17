import SwiftUI
import AppKit

/// Une étape de la vie de l'app (pilote l'affichage central).
enum Phase: Equatable {
    case demarrage        // on lance le moteur Python
    case attente          // prêt, en attente d'un scan
    case compteRebours    // 3… 2… 1…
    case scan             // le capteur lit le doigt
    case travail          // raccordement / rendu final
    case termine          // empreinte finale enregistrée
}

/// Écran affiché.
enum Ecran: Equatable {
    case accueil      // grille des commandes sauvées
    case commande     // une commande : ses empreintes, la composition, l'envoi
    case scan         // on scanne l'empreinte d'une personne
    case cadrage      // on cadre (crop) l'empreinte scannée
}

/// Les trois étapes visibles d'une commande (navigation libre entre elles).
enum EtapeCommande: Int, CaseIterable, Equatable {
    case empreintes = 1
    case composition = 2
    case envoi = 3

    var titre: String {
        switch self {
        case .empreintes:  return "Empreintes"
        case .composition: return "Composition"
        case .envoi:       return "Envoi"
        }
    }
    var symbole: String {
        switch self {
        case .empreintes:  return "hand.point.up.left"
        case .composition: return "heart.text.square"
        case .envoi:       return "paperplane"
        }
    }
}

/// Un port série proposé par le moteur.
struct Port: Identifiable, Hashable {
    let device: String
    let nom: String
    let typique: Bool
    var id: String { device }
}

/// Placement fin d'une empreinte dans son lobe (contrat V2).
/// dx, dy : fraction du rayon de lobe (dx > 0 vers la droite, dy > 0 vers le bas).
/// angle : degrés, rotation de l'empreinte sur elle-même.
struct Ajustement: Equatable {
    var dx: Double = 0
    var dy: Double = 0
    var angle: Double = 0
    var neutre: Bool { abs(dx) < 0.0005 && abs(dy) < 0.0005 && abs(angle) < 0.05 }
}

/// Une empreinte de la commande courante.
struct EmpreinteItem: Identifiable, Equatable {
    var index: Int
    var nom: String
    var crop: [Double]? = nil
    var completer: Bool = true
    var ajust: Ajustement = Ajustement()
    var photo: String? = nil
    var id: Int { index }
}

/// Une commande sauvée sur disque (vue « accueil »).
struct ResumeCommande: Identifiable, Equatable {
    let id: String
    var nom: String
    var date: String
    var nb: Int
    var forme: String?
    var style: String?
    var vignette: String?

    /// Date lisible en français (« 1 août 2026 »), sinon la chaîne brute.
    var dateLisible: String { Self.lisible(date, format: "d MMM yyyy") }

    /// « 1 août 2026 à 14:30 ».
    var dateComplete: String { Self.lisible(date, format: "d MMMM yyyy 'à' HH:mm") }

    static func lisible(_ date: String, format: String) -> String {
        let entree = ISO8601DateFormatter()
        entree.formatOptions = [.withInternetDateTime]
        var d = entree.date(from: date)
        if d == nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            d = f.date(from: String(date.prefix(19)))
        }
        guard let d else { return date }
        let sortie = DateFormatter()
        sortie.locale = Locale(identifier: "fr_FR")
        sortie.dateFormat = format
        return sortie.string(from: d)
    }
}

/// Résultat d'un export (dossier lisible + zip prêt à envoyer).
struct Export: Equatable {
    var dossier: String                 // Exports/<Nom client>/
    var zip: String                     // Exports/<Nom client>.zip
    var resume: String                  // texte du mail
    var nomExport: String = ""          // « Dupont »
    var fichiers: [String] = []         // chemins absolus produits
    var forme: String? = nil
    var style: String? = nil
    var styleDefaut = false             // aucun style choisi : « Traits soudés » d'office
    var avertissements: [String] = []
    var horodatage = Date()             // distingue deux exports identiques

    /// Chemins relatifs au dossier d'export, triés (pour dessiner l'arbre).
    var relatifs: [String] {
        let base = (dossier as NSString).standardizingPath + "/"
        return fichiers.compactMap { f -> String? in
            let s = (f as NSString).standardizingPath
            return s.hasPrefix(base) ? String(s.dropFirst(base.count)) : (f as NSString).lastPathComponent
        }.sorted()
    }
}

/// Un lobe de la forme assemblée, tel que le moteur le décrit dans
/// `apercu_pret.lobes` : où est l'empreinte i SUR le PNG d'aperçu (fractions
/// de largeur / hauteur), ses demi-axes de placement, son angle affiché et
/// la zone visible (pour poser l'étiquette et le cadre de sélection).
struct Lobe: Equatable {
    var index: Int
    var cx: Double, cy: Double
    var rx: Double, ry: Double
    var angle: Double
    var zone: [Double]           // [x0, y0, x1, y1]

    static func lire(_ brut: Any?) -> [Lobe] {
        guard let liste = brut as? [[String: Any]] else { return [] }
        return liste.compactMap { d in
            guard let i = d["index"] as? Int,
                  let cx = d["cx"] as? Double, let cy = d["cy"] as? Double else { return nil }
            let rx = d["rx"] as? Double ?? 0.3, ry = d["ry"] as? Double ?? 0.3
            let zone = (d["zone"] as? [Double]).flatMap { $0.count == 4 ? $0 : nil }
                ?? [max(0, cx - rx), max(0, cy - ry), min(1, cx + rx), min(1, cy + ry)]
            return Lobe(index: i, cx: cx, cy: cy, rx: rx, ry: ry,
                        angle: d["angle"] as? Double ?? 0, zone: zone)
        }
    }
}

/// Les deux vues de l'étape Composition.
enum VueComposition: Equatable {
    case chaque        // chaque empreinte seule, dans le style choisi
    case assembler     // la forme assemblée (optionnel)
}

/// Avancement d'un export (événement optionnel `export_progres`).
struct ProgresExport: Equatable {
    var etape: Int
    var total: Int
    var texte: String
    var fraction: Double { total > 0 ? Double(max(0, etape - 1)) / Double(total) : 0 }
}

/// Contrôleur : lance `moteur_live.py`, lui envoie des commandes et publie
/// l'état pour l'interface. Toute la logique lourde reste côté Python.
@MainActor
final class Moteur: ObservableObject {
    // état matériel / scan
    @Published var phase: Phase = .demarrage
    @Published var statut: String = "Démarrage…"
    @Published var poses: Int = 0
    @Published var apercu: NSImage? = nil          // mosaïque en cours de scan
    @Published var historiquePoses: [NSImage] = [] // la mosaïque après chaque pose
    @Published var ports: [Port] = []
    @Published var portActif: String? = nil
    @Published var connecte = false
    @Published var capteurPret = false
    @Published var compte: Int = 3
    @Published var erreur: String? = nil

    // navigation
    @Published var ecran: Ecran = .accueil
    @Published var etape: EtapeCommande = .empreintes

    // bibliothèque de commandes
    @Published var commandes: [ResumeCommande] = []
    @Published var dossierStockage: String = ""
    @Published var chargementListe = false

    // commande courante
    @Published var idCommande: String = ""
    @Published var nomCommande: String = ""
    @Published var empreintes: [EmpreinteItem] = []
    @Published var apercusEmpreintes: [Int: NSImage] = [:]   // miniatures par index
    @Published var personneEnCours: String = ""

    // aperçu composé
    @Published var forme: String? = nil            // nil = pas encore demandé
    @Published var style: String = "contact"
    @Published var apercuCompose: NSImage? = nil
    @Published var apercuEnCours = false
    @Published var composeEnCours = false
    @Published var cheminCompose: String? = nil
    @Published var placement: Int? = nil           // empreinte en cours de placement
    @Published var tailleReelle = false            // médaille à l'échelle 1 affichée
    @Published var lobes: [Lobe] = []              // géométrie de l'aperçu (moteur V2+)
    @Published var largeurForme: Double? = nil     // fraction du PNG occupée par la forme
    @Published var apercuForme: String? = nil      // pour quelle forme / style l'aperçu
    @Published var apercuStyle: String? = nil      //   affiché a été calculé
    @Published var ajustsApercu: [Int: Ajustement] = [:]   // les ajust au moment de l'aperçu

    // rendus d'une empreinte seule : [index: [style: image]] (+ largeur de forme)
    @Published var rendusEmpreintes: [Int: [String: NSImage]] = [:]
    @Published var largeurFormeEmpreinte: [Int: Double] = [:]
    @Published var rendusEnCours: Set<String> = []     // « i|style »

    // navigation dans l'étape Composition
    @Published var vueComposition: VueComposition = .chaque
    @Published var detailEmpreinte: Int? = nil     // fiche « comparer les styles »

    // export
    @Published var exportEnCours = false
    @Published var exportProgres: ProgresExport? = nil
    @Published var dernierExport: Export? = nil

    // cadrage
    @Published var cropInitial: [Double]? = nil
    @Published var completerInitial = true
    /// Vrai quand l'écran de cadrage a été ouvert par RECADRER : le moteur
    /// attend alors un VALIDER qui met à jour CETTE empreinte-là. Repasser
    /// par l'écran de scan ferait perdre le nouveau scan et écraserait
    /// quand même le cadrage de l'empreinte re-cadrée.
    @Published var recadrage = false

    private var processus: Process?
    private var versMoteur: FileHandle?
    private var tampon = Data()
    private var tacheCompte: Task<Void, Never>?
    private var tacheAjust: Task<Void, Never>?
    private var tacheErreur: Task<Void, Never>?

    static let nbMax = 4

    var occupe: Bool { phase == .compteRebours || phase == .scan || phase == .travail }

    /// Formes proposées selon le nombre d'empreintes (clé moteur, libellé).
    /// « separees » = une médaille par empreinte (pas d'assemblage), toujours là.
    var formesDisponibles: [(String, String)] {
        switch empreintes.count {
        case 2:  return [("separees", "Séparées"), ("coeur", "Cœur"),
                         ("ovale_lr", "Ovale coupé"), ("tete_beche", "Tête-bêche")]
        case 3:  return [("separees", "Séparées"), ("trefle", "Trèfle 3")]
        case 4:  return [("separees", "Séparées"), ("trefle", "Trèfle 4")]
        default: return [("separees", "Séparées")]
        }
    }

    /// Explication courte de chaque forme (vignettes de l'assemblage).
    nonisolated static let aideFormes: [String: String] = [
        "separees":  "Une médaille par empreinte, chacune gravée seule.",
        "coeur":     "Deux empreintes penchées l'une vers l'autre.",
        "ovale_lr":  "Un ovale : moitié gauche, moitié droite, fine coupure.",
        "tete_beche": "Un ovale : le haut de l'une, le bas de l'autre retournée.",
        "trefle":    "Chaque empreinte est une feuille, tournée vers le centre.",
    ]

    /// La forme courante assemble-t-elle vraiment les empreintes ?
    var formeAssemblee: Bool { forme.map { Libelle.formesAssemblees.contains($0) } ?? false }

    /// L'aperçu affiché correspond-il à la forme et au style courants ?
    var apercuAJour: Bool {
        apercuCompose != nil && apercuForme == forme && apercuStyle == style
    }

    /// Les styles de tracé, avec libellé et explication.
    nonisolated static let styles: [(cle: String, nom: String, aide: String)] = [
        ("contact", "Traits soudés", "Traits fins, les bifurcations se rejoignent."),
        ("sans",    "Traits",        "Traits fins, aucun trait ne touche son voisin."),
        ("gabor",   "Gabor",         "Crêtes épaisses et séparées (vallées visibles)."),
        ("photo",   "Photo",         "La vraie photo de l'empreinte, découpée."),
    ]

    /// Le placement fin n'a de sens que sur les formes assemblées.
    var ajustementPossible: Bool { formeAssemblee && empreintes.count > 1 }

    /// Le lobe de l'empreinte i sur l'aperçu courant (s'il est connu).
    func lobe(_ index: Int) -> Lobe? { lobes.first { $0.index == index } }

    /// Écart entre le placement courant et celui de l'aperçu affiché : c'est
    /// ce qu'on montre tout de suite à l'écran en attendant le nouvel aperçu.
    func ecartPlacement(_ index: Int) -> Ajustement {
        guard index < empreintes.count else { return Ajustement() }
        let a = empreintes[index].ajust
        let b = ajustsApercu[index] ?? Ajustement()
        return Ajustement(dx: a.dx - b.dx, dy: a.dy - b.dy, angle: a.angle - b.angle)
    }

    /// Un rendu a-t-il été enregistré pour la commande courante ?
    var renduEnregistre: Bool { cheminCompose != nil }

    // MARK: - cycle de vie

    func demarrer() {
        let (python, script, dossier) = Self.localiserScript()
        guard let script else {
            phase = .attente
            signaler("Introuvable : moteur_live.py. Relance INSTALLER.command " +
                     "ou place l'app dans le dossier empreintescanner.")
            statut = "Script du moteur introuvable"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script]
        p.currentDirectoryURL = URL(fileURLWithPath: dossier)
        let sortie = Pipe(), entree = Pipe(), erreurs = Pipe()
        p.standardOutput = sortie
        p.standardInput = entree
        p.standardError = erreurs
        versMoteur = entree.fileHandleForWriting

        sortie.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            // DispatchQueue.main est FIFO : les lignes JSON gardent leur ordre.
            DispatchQueue.main.async { self.avaler(data) }
        }
        // on ignore le flux d'erreurs (diagnostics), on le draine juste
        erreurs.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .demarrage {
                    self.signaler("Le moteur Python n'a pas pu démarrer.")
                    self.statut = "Erreur de démarrage"
                    self.phase = .attente
                }
            }
        }
        do { try p.run() } catch {
            signaler("Impossible de lancer Python : \(error.localizedDescription)")
            statut = "Erreur de démarrage"
            phase = .attente
            return
        }
        processus = p
    }

    func arreter() {
        tacheCompte?.cancel()
        tacheAjust?.cancel()
        envoyer("QUIT")
        processus?.terminate()
    }

    // MARK: - matériel

    func choisirPort(_ device: String) {
        portActif = device
        connecte = false
        capteurPret = false
        statut = "Connexion à \(device)…"
        envoyer("CONNECT \(device)")
    }

    func rafraichirPorts() { envoyer("PORTS") }

    /// Libellé court de l'état du capteur.
    var etatCapteur: String {
        capteurPret ? "Capteur prêt" : (connecte ? "Connecté" : "Pas de capteur")
    }

    func nouveauScan() {
        guard connecte, !occupe else { return }
        erreur = nil
        envoyer("LED ATTENTE")
        tacheCompte?.cancel()
        tacheCompte = Task { @MainActor in
            for n in [3, 2, 1] {
                compte = n
                phase = .compteRebours
                statut = "Pose ton doigt bien à plat…"
                try? await Task.sleep(nanoseconds: 750_000_000)
                if Task.isCancelled { return }
            }
            phase = .scan
            statut = "Scan en cours — garde le doigt appuyé"
            envoyer("SCAN")
        }
    }

    /// Capture sans compte à rebours (le doigt est déjà posé sur le capteur).
    func scanImmediat() {
        guard connecte, !occupe else { return }
        erreur = nil
        tacheCompte?.cancel()
        phase = .scan
        statut = "Doigt détecté — ne bouge pas !"
        envoyer("SCAN")
    }

    func recommencer() {
        guard !occupe else { return }
        envoyer("RESET")
    }

    // MARK: - bibliothèque de commandes

    func chargerCommandes() {
        guard versMoteur != nil else { return }     // moteur absent : rien à lire
        chargementListe = true
        envoyer("COMMANDES")
    }

    func demanderDossier() { envoyer("DOSSIER") }

    func changerDossier(_ chemin: String) {
        guard versMoteur != nil else { return }
        chargementListe = true
        envoyer("DOSSIER \(chemin)")
    }

    func creerCommande(_ nom: String) {
        reinitialiserCommande()
        envoyer("COMMANDE \(nom)")
        nomCommande = nom
        etape = .empreintes
        ecran = .commande
    }

    func ouvrirCommande(_ id: String) {
        reinitialiserCommande()
        idCommande = id
        if let r = commandes.first(where: { $0.id == id }) {
            nomCommande = r.nom
            forme = r.forme
            style = r.style ?? style
            if let v = r.vignette { apercuCompose = Self.imageFraiche(v) }
        }
        envoyer("OUVRIR \(id)")
        etape = .empreintes
        ecran = .commande
    }

    func supprimerCommande(_ id: String) {
        envoyer("SUPPRIMER_COMMANDE \(id)")
        commandes.removeAll { $0.id == id }
    }

    func renommerCommande(_ nom: String) {
        let propre = Self.nettoyer(nom)
        guard !propre.isEmpty else { return }
        nomCommande = propre
        envoyer("RENOMMER \(propre)")
    }

    func retourAccueil() {
        ecran = .accueil
        chargerCommandes()
    }

    private func reinitialiserCommande() {
        idCommande = ""
        nomCommande = ""
        empreintes = []
        apercusEmpreintes = [:]
        apercuCompose = nil
        cheminCompose = nil
        dernierExport = nil
        exportProgres = nil
        forme = nil
        placement = nil
        lobes = []
        largeurForme = nil
        apercuForme = nil
        apercuStyle = nil
        ajustsApercu = [:]
        rendusEmpreintes = [:]
        largeurFormeEmpreinte = [:]
        rendusEnCours = []
        vueComposition = .chaque
        detailEmpreinte = nil
        apercuEnCours = false
        composeEnCours = false
        recadrage = false          // OUVRIR / COMMANDE remettent le moteur à zéro
    }

    // MARK: - étapes de la commande

    /// Change d'étape. En arrivant sur la composition sans forme valable, on
    /// en choisit une d'office (la première proposée) pour que l'aperçu
    /// apparaisse sans rien demander.
    func allerEtape(_ e: EtapeCommande) {
        etape = e
        if e == .composition, !empreintes.isEmpty {
            // On arrive toujours sur « chaque empreinte » ; l'assemblage est
            // optionnel et se choisit ensuite.
            vueComposition = .chaque
            detailEmpreinte = nil
            let valables = formesDisponibles.map(\.0)
            if let f = forme, valables.contains(f) {
                if formeAssemblee && !apercuAJour && !apercuEnCours { demanderApercu() }
            } else {
                choisirForme("separees")
            }
            demanderRendusManquants()
        }
    }

    /// Bascule entre « chaque empreinte » et « assembler ».
    func montrerComposition(_ v: VueComposition) {
        vueComposition = v
        detailEmpreinte = nil
        if v == .assembler, formeAssemblee, !apercuAJour, !apercuEnCours { demanderApercu() }
        if v == .chaque { demanderRendusManquants() }
    }

    /// Ouvre (ou ferme) la fiche « comparer les styles » d'une empreinte.
    func ouvrirDetail(_ index: Int?) {
        detailEmpreinte = index
        if let i = index {
            for s in Self.styles { demanderRenduEmpreinte(i, style: s.cle) }
        }
    }

    // MARK: - empreintes

    func ajouterEmpreinte(_ nom: String) {
        personneEnCours = Self.nettoyer(nom)
        apercu = nil
        historiquePoses = []
        poses = 0
        phase = .attente
        erreur = nil
        recadrage = false
        envoyer("EMPREINTE \(personneEnCours)")
        ecran = .scan
    }

    /// Refait l'empreinte i : l'ancienne est retirée, puis on rescanne la
    /// même personne (la nouvelle empreinte arrive en fin de liste).
    func refaireEmpreinte(_ index: Int) {
        guard index < empreintes.count else { return }
        let nom = empreintes[index].nom
        supprimerEmpreinte(index)
        ajouterEmpreinte(nom)
    }

    func renommerEmpreinte(_ index: Int, _ nom: String) {
        let propre = Self.nettoyer(nom)
        guard !propre.isEmpty, index < empreintes.count else { return }
        empreintes[index].nom = propre
        envoyer("RENOMMER_EMPREINTE \(index) \(propre)")
    }

    func supprimerEmpreinte(_ index: Int) {
        apercuCompose = nil
        apercusEmpreintes = [:]
        oublierRendus()
        placement = nil
        envoyer("SUPPRIMER \(index)")
    }

    /// Rouvre le cadrage d'une empreinte déjà enregistrée.
    func recadrerEmpreinte(_ index: Int) {
        envoyer("RECADRER \(index)")
    }

    /// Passe à l'écran de cadrage de l'empreinte qu'on vient de scanner.
    func ouvrirCadrage() {
        guard poses > 0, !occupe else { return }
        ecran = .cadrage
    }

    /// Valide le cadrage : envoie le crop normalisé + le choix de complétion.
    func validerCadrage(cx: Double, cy: Double, hw: Double, hh: Double,
                        completer: Bool) {
        phase = .travail
        statut = "Enregistrement de l'empreinte…"
        let c = completer ? "1" : "0"
        envoyer(String(format: "VALIDER %.4f %.4f %.4f %.4f %@", cx, cy, hw, hh, c))
    }

    func annulerEmpreinte() {
        ecran = .commande
        envoyer("LED PRET")
    }

    func retourScan() {
        ecran = .scan
        envoyer("LED PRET")
    }

    /// Demande les miniatures individuelles (une par empreinte).
    func rafraichirMiniatures() {
        for e in empreintes { envoyer("EMPREINTE_APERCU \(e.index)") }
    }

    // MARK: - aperçu composé

    func choisirForme(_ f: String) {
        forme = f
        placement = nil
        demanderApercu()
    }

    func choisirStyle(_ s: String) {
        style = s
        demanderRendusManquants()
        if forme != nil { demanderApercu() }
    }

    /// Demande un aperçu (rendu composé) — mis en cache côté moteur. Pour
    /// « separees », c'est la planche qui sert de vignette à la commande.
    func demanderApercu() {
        guard let forme, !empreintes.isEmpty else { return }
        apercuEnCours = true
        envoyer("APERCU \(forme) \(style)")
    }

    /// Rendu d'une empreinte SEULE dans un style (moteur V2+ : RENDU_EMPREINTE).
    func demanderRenduEmpreinte(_ index: Int, style s: String) {
        guard index < empreintes.count else { return }
        if rendusEmpreintes[index]?[s] != nil { return }
        let cle = "\(index)|\(s)"
        guard !rendusEnCours.contains(cle), versMoteur != nil else { return }
        rendusEnCours.insert(cle)
        envoyer("RENDU_EMPREINTE \(index) \(s)")
    }

    /// Les rendus seuls de toutes les empreintes dans le style courant.
    func demanderRendusManquants() {
        for e in empreintes { demanderRenduEmpreinte(e.index, style: style) }
        if let i = detailEmpreinte {
            for s in Self.styles { demanderRenduEmpreinte(i, style: s.cle) }
        }
    }

    /// Le rendu seul de l'empreinte i dans le style courant (ou nil).
    func renduSeul(_ index: Int, style s: String? = nil) -> NSImage? {
        rendusEmpreintes[index]?[s ?? style]
    }

    /// Vide les rendus seuls (le cadrage ou la liste a changé).
    private func oublierRendus() {
        rendusEmpreintes = [:]
        largeurFormeEmpreinte = [:]
        rendusEnCours = []
    }

    // MARK: placement direct (cadre sur l'aperçu)

    /// Déplace l'empreinte i de (ddx, ddy) fractions de rayon de lobe.
    func deplacerPlacement(_ index: Int, ddx: Double, ddy: Double) {
        guard index < empreintes.count else { return }
        let a = empreintes[index].ajust
        ajuster(index, dx: a.dx + ddx, dy: a.dy + ddy, angle: a.angle)
    }

    /// Tourne l'empreinte i de `delta` degrés (aimant optionnel tous les 15°).
    func tournerPlacement(_ index: Int, delta: Double, aimant: Bool = false) {
        guard index < empreintes.count else { return }
        let a = empreintes[index].ajust
        var angle = a.angle + delta
        if aimant { angle = (angle / 15).rounded() * 15 }
        angle = max(-180, min(180, angle))
        ajuster(index, dx: a.dx, dy: a.dy, angle: angle)
    }

    /// Pose directement l'angle de l'empreinte i (poignée de rotation).
    func fixerAngle(_ index: Int, _ angle: Double) {
        guard index < empreintes.count else { return }
        let a = empreintes[index].ajust
        ajuster(index, dx: a.dx, dy: a.dy, angle: max(-180, min(180, angle)))
    }

    /// Modifie le placement d'une empreinte (aperçu redemandé après un délai).
    func ajuster(_ index: Int, dx: Double, dy: Double, angle: Double) {
        guard index < empreintes.count else { return }
        empreintes[index].ajust = Ajustement(dx: max(-1, min(1, dx)),
                                             dy: max(-1, min(1, dy)),
                                             angle: angle)
        programmerAjustement(index)
    }

    func reinitialiserAjustement(_ index: Int) {
        guard index < empreintes.count else { return }
        empreintes[index].ajust = Ajustement()
        programmerAjustement(index)
    }

    /// Debounce ~300 ms : on n'inonde pas le moteur pendant un glissement.
    private func programmerAjustement(_ index: Int) {
        tacheAjust?.cancel()
        tacheAjust = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard index < self.empreintes.count else { return }
            let a = self.empreintes[index].ajust
            self.envoyer("AJUSTER \(index) " +
                         String(format: "%.4f %.4f %.2f", a.dx, a.dy, a.angle))
            self.demanderApercu()
        }
    }

    /// Enregistre le rendu final (SVG + PNG) dans le dossier de la commande.
    func enregistrer() {
        guard let forme, !empreintes.isEmpty, !composeEnCours else { return }
        composeEnCours = true
        cheminCompose = nil
        statut = "Enregistrement du rendu…"
        envoyer("ENREGISTRER \(forme) \(style)")
    }

    // MARK: - export et envoi

    func exporter() {
        guard !exportEnCours else { return }
        exportEnCours = true
        exportProgres = nil
        statut = "Préparation du dossier à envoyer…"
        envoyer("EXPORTER")
    }

    /// Ouvre le compositeur de mail avec le zip en pièce jointe et le
    /// récapitulatif en corps de message : maman envoie elle-même.
    func envoyerParMail() {
        guard let e = dernierExport else { return }
        guard let service = NSSharingService(named: .composeEmail) else {
            signaler("Aucun logiciel de mail configuré sur ce Mac.")
            return
        }
        service.subject = "Empreintes — \(nomCommande)"
        service.perform(withItems: [e.resume, URL(fileURLWithPath: e.zip)])
    }

    func montrerDansFinder(_ chemin: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: chemin)])
    }

    func copierRecapitulatif() {
        guard let e = dernierExport else { return }
        let presse = NSPasteboard.general
        presse.clearContents()
        presse.setString(e.resume, forType: .string)
        statut = "Récapitulatif copié — colle-le où tu veux."
    }

    private func envoyer(_ commande: String) {
        guard let versMoteur else { return }
        versMoteur.write(Data((commande + "\n").utf8))
    }

    /// Affiche une erreur qui s'efface toute seule (jamais bloquante).
    func signaler(_ texte: String) {
        erreur = texte
        tacheErreur?.cancel()
        tacheErreur = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if Task.isCancelled { return }
            if self.erreur == texte { self.erreur = nil }
        }
    }

    // MARK: - réception

    private func avaler(_ data: Data) {
        tampon.append(data)
        while let i = tampon.firstIndex(of: 0x0A) {
            let ligne = tampon.subdata(in: tampon.startIndex..<i)
            tampon.removeSubrange(tampon.startIndex...i)
            if let texte = String(data: ligne, encoding: .utf8) { traiter(texte) }
        }
    }

    private func traiter(_ ligne: String) {
        guard let d = ligne.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let event = obj["event"] as? String else { return }

        switch event {
        case "ready":
            majPorts(obj["ports"])
            if let d = obj["dossier_commandes"] as? String { dossierStockage = d }
            demanderDossier()
            chargerCommandes()
            // Uniquement un port qui RESSEMBLE à l'ESP32 : tout Mac expose
            // /dev/cu.wlan-debug, cu.debug-console, cu.Bluetooth-Incoming-Port.
            // Se connecter au premier venu bloque le moteur 10 s sur un
            // appareil qui n'est pas le capteur, et affiche « Connecté ».
            if let premier = ports.first(where: { $0.typique }) {
                choisirPort(premier.device)
            } else {
                phase = .attente
                statut = "Branche le capteur en USB, puis choisis le port."
            }

        case "ports":
            majPorts(obj["ports"])

        case "connected":
            connecte = true
            portActif = obj["port"] as? String ?? portActif
            capteurPret = (obj["capteur"] as? Bool) ?? false
            phase = .attente
            statut = capteurPret
                ? "Capteur prêt — pose un doigt pour scanner."
                : "Connecté au capteur. (Capteur non confirmé — tu peux essayer.)"

        case "status":
            statut = obj["texte"] as? String ?? statut

        case "bouton":
            if ecran == .scan && connecte && !occupe { nouveauScan() }

        case "touche":
            // Doigt posé sur le capteur : on capture tout de suite.
            if ecran == .scan && connecte && !occupe { scanImmediat() }

        case "scan_ok":
            poses = obj["poses"] as? Int ?? poses
            if let chemin = obj["apercu"] as? String, let img = Self.imageFraiche(chemin) {
                apercu = img
                historiquePoses.append(img)
            }
            phase = .attente
            statut = "Raccordée ! \(Libelle.pluriel(poses, "pose")) — " +
                     "décale un peu le doigt puis repose-le."

        case "scan_rejete":
            phase = .attente
            statut = obj["raison"] as? String ?? "Pose non raccordée — réessaie."

        case "scan_fail":
            phase = .attente
            statut = obj["raison"] as? String ?? "Scan raté — réessaie."

        case "reset":
            poses = 0
            apercu = nil
            historiquePoses = []
            phase = .attente
            statut = "On repart de zéro — pose ton doigt sur le capteur."

        case "final":
            phase = .termine
            statut = "Empreinte enregistrée."

        case "dossier":
            if let c = obj["chemin"] as? String { dossierStockage = c }

        case "commandes":
            chargementListe = false
            majCommandes(obj["liste"])

        case "commande":
            idCommande = obj["id"] as? String ?? idCommande
            nomCommande = obj["nom"] as? String ?? nomCommande
            if let f = Self.cleForme(obj["forme"] as? String) { forme = f }
            if let s = Self.cleStyle(obj["style"] as? String) { style = s }
            // Le moteur V2 envoie la liste complète ; un moteur plus ancien
            // n'enverrait que les prénoms — on accepte les deux.
            if let brut = obj["empreintes"], !(brut is NSNull) {
                empreintes = Self.lireEmpreintes(brut)
            } else if obj["noms"] != nil {
                majNoms(obj["noms"])
            }
            chargerPhotos()
            rafraichirMiniatures()

        case "empreinte_debut":
            personneEnCours = obj["personne"] as? String ?? personneEnCours
            poses = 0
            apercu = nil
            historiquePoses = []
            cropInitial = nil
            completerInitial = true
            recadrage = false
            phase = .attente
            statut = "Empreinte de \(personneEnCours) — pose le doigt sur le capteur."

        case "recadrer":
            personneEnCours = obj["personne"] as? String ?? personneEnCours
            cropInitial = obj["crop"] as? [Double]
            completerInitial = (obj["completer"] as? Bool) ?? true
            recadrage = true
            if let chemin = obj["apercu"] as? String { apercu = Self.imageFraiche(chemin) }
            phase = .attente
            ecran = .cadrage
            statut = "Ajuste le cadre de \(personneEnCours)."

        case "empreinte_validee":
            // Après une suppression au milieu, les index glissent : on relit
            // l'état complet quand le moteur l'envoie (V2), sinon les réglages
            // (crop, completer, ajust) resteraient décalés d'un cran.
            if let brut = obj["empreintes"], !(brut is NSNull),
               let liste = brut as? [[String: Any]] {
                empreintes = Self.lireEmpreintes(liste)
            } else {
                majNoms(obj["noms"])
            }
            if let photos = obj["photos"] as? [String] {
                for (i, p) in photos.enumerated() where i < empreintes.count {
                    empreintes[i].photo = p
                    apercusEmpreintes[i] = Self.imageFraiche(p)
                }
            }
            recadrage = false
            phase = .attente
            // On revient à la liste des empreintes : PAS de composite
            // automatique (la forme sera rechoisie à l'étape composition).
            apercuCompose = nil
            cheminCompose = nil
            forme = nil
            placement = nil
            lobes = []
            apercuForme = nil
            oublierRendus()
            // « Refaire » enchaîne SUPPRIMER puis EMPREINTE : la validation de
            // la suppression arrive alors que le scan a déjà commencé — on ne
            // quitte pas l'écran de scan dans ce cas.
            if ecran != .scan {
                apercu = nil
                poses = 0
                historiquePoses = []
                ecran = .commande
                etape = .empreintes
            }
            rafraichirMiniatures()
            statut = "\(Libelle.pluriel(empreintes.count, "empreinte")) dans la commande."

        case "empreinte_apercu":
            if let i = obj["index"] as? Int, let png = obj["png"] as? String,
               let img = Self.imageFraiche(png) {
                apercusEmpreintes[i] = img
            }

        case "ajuste":
            if let i = obj["index"] as? Int, i < empreintes.count,
               let a = obj["ajust"] as? [String: Any] {
                empreintes[i].ajust = Self.lireAjust(a)
            }

        case "apercu_pret":
            apercuEnCours = false
            if let chemin = obj["png"] as? String {
                apercuCompose = Self.imageFraiche(chemin)
            }
            // Champs V2+ (moteur plus ancien : absents, l'app se débrouille).
            apercuForme = Self.cleForme(obj["forme"] as? String) ?? forme
            apercuStyle = Self.cleStyle(obj["style"] as? String) ?? style
            lobes = Lobe.lire(obj["lobes"])
            largeurForme = obj["largeur_forme"] as? Double
            ajustsApercu = Dictionary(uniqueKeysWithValues: empreintes.map { ($0.index, $0.ajust) })
            statut = "Aperçu prêt."

        case "rendu_empreinte":
            if let i = obj["index"] as? Int, let s = Self.cleStyle(obj["style"] as? String) {
                rendusEnCours.remove("\(i)|\(s)")
                if let png = obj["png"] as? String, let img = Self.imageFraiche(png) {
                    var parStyle = rendusEmpreintes[i] ?? [:]
                    parStyle[s] = img
                    rendusEmpreintes[i] = parStyle
                }
                if let l = obj["largeur_forme"] as? Double { largeurFormeEmpreinte[i] = l }
            }

        case "compose":
            composeEnCours = false
            cheminCompose = obj["svg"] as? String
            statut = "Rendu enregistré dans le dossier de la commande."

        case "export_progres":
            if let etape = obj["etape"] as? Int, let total = obj["total"] as? Int {
                let texte = obj["texte"] as? String ?? ""
                exportProgres = ProgresExport(etape: etape, total: total, texte: texte)
                if !texte.isEmpty { statut = texte }
            }

        case "exporte":
            exportEnCours = false
            exportProgres = nil
            if let dossier = obj["dossier"] as? String, let zip = obj["zip"] as? String {
                var e = Export(dossier: dossier, zip: zip,
                               resume: obj["resume"] as? String ?? nomCommande)
                e.nomExport = obj["nom_export"] as? String
                    ?? (dossier as NSString).lastPathComponent
                e.fichiers = obj["fichiers"] as? [String] ?? []
                e.forme = Self.cleForme(obj["forme"] as? String)
                e.style = Self.cleStyle(obj["style"] as? String)
                e.styleDefaut = (obj["style_defaut"] as? Bool) ?? false
                e.avertissements = obj["avertissements"] as? [String] ?? []
                dernierExport = e
                statut = "Dossier prêt : \((zip as NSString).lastPathComponent)"
            }

        case "error":
            let raison = obj["raison"] as? String ?? "erreur inconnue"
            if let i = obj["index"] as? Int {          // un rendu seul a échoué
                rendusEnCours = rendusEnCours.filter { !$0.hasPrefix("\(i)|") }
            } else if raison.lowercased().contains("rendu_empreinte") {
                rendusEnCours = []
            }
            composeEnCours = false
            exportEnCours = false
            exportProgres = nil
            apercuEnCours = false
            chargementListe = false
            // Les commandes que l'ancien moteur ne connaît pas ne doivent pas
            // affoler l'utilisateur : on n'affiche que les vraies erreurs.
            // « Export incomplet : … » double les `avertissements` de
            // l'événement `exporte`, déjà montrés dans la feuille d'envoi.
            let doublonExport = raison.hasPrefix("Export incomplet")
                && !(dernierExport?.avertissements.isEmpty ?? true)
            if !raison.lowercased().hasPrefix("commande inconnue") && !doublonExport {
                signaler(raison)
            }
            if (obj["fatal"] as? Bool) == true { statut = "Dépendances manquantes" }
            if occupe { phase = .attente }

        default:
            break        // événement inconnu : on l'ignore, sans casser l'app
        }
    }

    // MARK: - décodage

    private func majPorts(_ brut: Any?) {
        guard let liste = brut as? [[String: Any]] else { return }
        ports = liste.compactMap { p in
            guard let device = p["device"] as? String else { return nil }
            return Port(device: device,
                        nom: p["nom"] as? String ?? device,
                        typique: (p["typique"] as? Bool) ?? false)
        }
    }

    private func majCommandes(_ brut: Any?) {
        guard let liste = brut as? [[String: Any]] else { commandes = []; return }
        commandes = liste.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return ResumeCommande(id: id,
                                  nom: c["nom"] as? String ?? id,
                                  date: c["date"] as? String ?? "",
                                  nb: c["nb"] as? Int ?? 0,
                                  forme: Self.cleForme(c["forme"] as? String),
                                  style: Self.cleStyle(c["style"] as? String),
                                  vignette: c["vignette"] as? String)
        }
    }

    /// Met à jour les prénoms sans perdre les réglages déjà connus.
    private func majNoms(_ brut: Any?) {
        guard let noms = brut as? [String] else { return }
        var nouvelles: [EmpreinteItem] = []
        for (i, n) in noms.enumerated() {
            var e = i < empreintes.count ? empreintes[i] : EmpreinteItem(index: i, nom: n)
            e.index = i
            e.nom = n
            nouvelles.append(e)
        }
        empreintes = nouvelles
    }

    private func chargerPhotos() {
        for e in empreintes {
            guard apercusEmpreintes[e.index] == nil, let p = e.photo else { continue }
            apercusEmpreintes[e.index] = Self.imageFraiche(p)
        }
    }

    private static func lireAjust(_ d: [String: Any]) -> Ajustement {
        Ajustement(dx: d["dx"] as? Double ?? 0,
                   dy: d["dy"] as? Double ?? 0,
                   angle: d["angle"] as? Double ?? 0)
    }

    /// Accepte les deux formes possibles : liste de prénoms (V1) ou liste
    /// d'objets complets (V2).
    private static func lireEmpreintes(_ brut: Any?) -> [EmpreinteItem] {
        if let noms = brut as? [String] {
            return noms.enumerated().map { EmpreinteItem(index: $0.offset, nom: $0.element) }
        }
        if let liste = brut as? [[String: Any]] {
            return liste.enumerated().map { i, d in
                var e = EmpreinteItem(index: i,
                                      nom: d["nom"] as? String ?? "Empreinte \(i + 1)")
                e.crop = d["crop"] as? [Double]
                e.completer = (d["completer"] as? Bool) ?? true
                if let a = d["ajust"] as? [String: Any] { e.ajust = lireAjust(a) }
                e.photo = d["photo"] as? String
                return e
            }
        }
        return []
    }

    /// Noms canoniques : formes.py accepte des synonymes (« trefle3 »,
    /// « traits »…) et le moteur range dans commande.json le nom reçu. Sans
    /// cette remise au propre, une commande enregistrée en style « traits »
    /// se rouvre avec AUCUNE puce allumée alors que le rendu, lui, sera bien
    /// en « traits soudés ».
    static func cleForme(_ brut: String?) -> String? {
        guard let f = brut?.lowercased(), !f.isEmpty else { return nil }
        switch f {
        case "trefle3", "trefle4", "trèfle": return "trefle"
        case "cœur":                         return "coeur"
        case "simple", "ovale", "separe", "séparées", "separees": return "separees"
        case "ovale_coupe", "ovale-lr":      return "ovale_lr"
        case "tete-beche", "tête-bêche":     return "tete_beche"
        default:                             return f
        }
    }

    static func cleStyle(_ brut: String?) -> String? {
        guard let s = brut?.lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "traits", "traits_soudes", "soude": return "contact"
        case "traits_fins", "fins":              return "sans"
        case "plein":                            return "gabor"
        default:                                 return s
        }
    }

    /// Un nom sur une seule ligne (le protocole est ligne par ligne).
    static func nettoyer(_ texte: String) -> String {
        texte.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
             .trimmingCharacters(in: .whitespaces)
    }

    /// Charge une image depuis un fichier sans passer par le cache NSImage.
    static func imageFraiche(_ chemin: String) -> NSImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: chemin)) else {
            return nil
        }
        return NSImage(data: data)
    }

    // MARK: - localisation du script Python

    /// Renvoie (interpréteur python, chemin de moteur_live.py, dossier de travail).
    /// Ordre : dans l'app → à côté → dossier de développement → Application Support.
    static func localiserScript() -> (String, String?, String) {
        let fm = FileManager.default
        var dossiers: [String] = []
        // 1) embarqué dans l'app (distribution par clé USB)
        if let res = Bundle.main.resourcePath {
            dossiers.append((res as NSString).appendingPathComponent("moteur"))
        }
        // 2) à côté de l'app (app posée dans le dossier du projet)
        dossiers.append(Bundle.main.bundleURL.deletingLastPathComponent().path)
        // 3) le dossier de développement classique — AVANT la copie installée,
        //    sinon l'app de dev exécuterait les .py figés par INSTALLER.command
        dossiers.append((NSHomeDirectory() as NSString)
            .appendingPathComponent("Desktop/empreintescanner"))
        // 4) installé dans la bibliothèque de l'utilisateur
        dossiers.append((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/EmpreinteMMD/moteur"))
        // 5) dossier courant (lancement en ligne de commande)
        dossiers.append(fm.currentDirectoryPath)

        var dossierChoisi = dossiers.last ?? fm.currentDirectoryPath
        var script: String? = nil
        for d in dossiers {
            let candidat = (d as NSString).appendingPathComponent("moteur_live.py")
            if fm.fileExists(atPath: candidat) {
                script = candidat
                dossierChoisi = d
                break
            }
        }
        return (localiserPython(), script, dossierChoisi)
    }

    /// L'interpréteur Python à utiliser. INSTALLER.command note le sien dans
    /// `python.txt` : c'est lui qui a reçu les dépendances, il est prioritaire.
    private static func localiserPython() -> String {
        let fm = FileManager.default
        let note = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/EmpreinteMMD/python.txt")
        if let texte = try? String(contentsOfFile: note, encoding: .utf8) {
            let chemin = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            if fm.isExecutableFile(atPath: chemin) { return chemin }
        }
        let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                       "/usr/bin/python3"]
        return pythons.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
}
