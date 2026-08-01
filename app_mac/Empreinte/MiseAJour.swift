import SwiftUI
import AppKit

// =========================================================================
// MISE À JOUR EN UN BOUTON
//
// Félix publie depuis son Mac :   ./publier.sh 2.1 "ce qui change"
// Maman clique dans l'app :       roue dentée > « Rechercher une mise à
//                                 jour » > « Installer ».
//
// Le manifeste (version.json) et le paquet (dist/Empreinte_MMD.zip) sont
// lus en clair sur GitHub — aucun compte, aucun mot de passe, rien à
// configurer sur le Mac de maman.
//
// ⚠️  RÈGLE ABSOLUE : la mise à jour ne remplace QUE l'application. Les
//     commandes (~/Documents/Empreintes MMD, ou le dossier choisi) et les
//     réglages (~/.empreinte_mmd.json) ne sont JAMAIS touchés — ni lus, ni
//     déplacés, ni supprimés. Le script d'échange le vérifie lui-même
//     (voir `scriptEchange`) et refuse de tourner si la cible n'est pas
//     un bundle .app.
// =========================================================================

/// Ce que le serveur annonce.
struct InfoVersion: Equatable {
    var version: String
    var date: String
    var notes: String
    var zip: String
    var paquets: [String]

    /// « 1 août 2026 » si la date est lisible, sinon la chaîne brute.
    var dateLisible: String {
        let entree = DateFormatter()
        entree.locale = Locale(identifier: "en_US_POSIX")
        entree.dateFormat = "yyyy-MM-dd"
        guard let d = entree.date(from: String(date.prefix(10))) else { return date }
        let sortie = DateFormatter()
        sortie.locale = Locale(identifier: "fr_FR")
        sortie.dateFormat = "d MMMM yyyy"
        return sortie.string(from: d)
    }
}

/// Où en est la mise à jour (pilote l'affichage du panneau).
enum EtatMAJ: Equatable {
    case repos
    case verification
    case aJour
    case disponible
    case telechargement
    case installation
    case erreur(String)
}

// MARK: - les chemins

/// Tous les chemins utilisés par la mise à jour, au même endroit.
/// Les variables d'environnement ne servent QU'AUX TESTS (elles permettent
/// de rejouer une mise à jour complète dans un dossier temporaire sans
/// toucher à l'installation réelle) ; en usage normal elles sont absentes.
enum CheminsMAJ {
    static var support: URL {
        let env = ProcessInfo.processInfo.environment["EMPREINTE_MAJ_SUPPORT"]
        if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/EmpreinteMMD")
    }
    static var venv: URL       { support.appendingPathComponent("venv") }
    static var sauvegarde: URL { support.appendingPathComponent("sauvegarde") }
    static var travail: URL    { support.appendingPathComponent("maj") }
    static var journal: URL    { travail.appendingPathComponent("journal.txt") }

    /// L'application à remplacer : celle qui tourne en ce moment.
    static var appInstallee: URL? {
        let u = Bundle.main.bundleURL
        return u.pathExtension == "app" ? u : nil
    }

    /// L'adresse du manifeste. `EMPREINTE_MAJ_URL` sert aux tests hors ligne.
    static var urlManifeste: String {
        let env = ProcessInfo.processInfo.environment["EMPREINTE_MAJ_URL"]
        if let env, !env.isEmpty { return env }
        return "https://raw.githubusercontent.com/Felixooos/scanner/main/version.json"
    }
}

// MARK: - le contrôleur

/// Vérifie, télécharge, installe — et sait revenir en arrière.
/// Volontairement PAS `@MainActor` : le travail se fait en arrière-plan et
/// l'état publié est remis à jour sur le fil principal (`surMain`).
final class MiseAJour: ObservableObject, @unchecked Sendable {

    /// Une seule instance pour toute l'app (accueil, panneau, vérification
    /// silencieuse au lancement).
    static let partagee = MiseAJour()

    @Published var etat: EtatMAJ = .repos
    @Published var info: InfoVersion? = nil
    @Published var progression: Double = 0
    @Published var versionSauvegardee: String? = nil

    /// Ce qu'on fait quand l'app doit se fermer pour laisser la place au
    /// script d'échange. Remplacé en mode ligne de commande.
    var quitter: () -> Void = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private var telechargeur: Telechargeur?
    private let fm = FileManager.default

    init() { relireSauvegarde() }

    // MARK: état lisible

    var versionInstallee: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Vrai quand une version plus récente est connue (pastille discrète).
    var disponible: Bool {
        guard let info else { return false }
        return Self.comparer(info.version, versionInstallee) > 0
    }

    /// Vrai si on peut revenir à la version d'avant.
    var retourPossible: Bool {
        guard let v = versionSauvegardee else { return false }
        return fm.fileExists(atPath: Self.appSauvegardee.path) && v != versionInstallee
    }

    var occupe: Bool {
        etat == .verification || etat == .telechargement || etat == .installation
    }

    static var appSauvegardee: URL {
        CheminsMAJ.sauvegarde.appendingPathComponent("Empreinte.app")
    }

    // MARK: - 1. vérifier

    /// `silencieux` : au lancement de l'app, on ne montre RIEN (pas de
    /// fenêtre, pas de message d'erreur) — juste la pastille si ça vaut le
    /// coup. Jamais de fenêtre imposée pendant le travail.
    func verifier(silencieux: Bool = false) {
        if occupe { return }
        guard let url = URL(string: CheminsMAJ.urlManifeste) else {
            surMain { self.etat = .erreur("Adresse de mise à jour invalide.") }
            return
        }
        if !silencieux { surMain { self.etat = .verification } }

        // GitHub garde les fichiers en cache très longtemps : on exige la
        // version fraîche, sinon maman verrait l'ancien numéro pendant des
        // heures après une publication.
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")

        URLSession.shared.dataTask(with: req) { donnees, reponse, erreur in
            if let erreur = erreur {
                self.echouer(silencieux: silencieux,
                             "Pas de connexion Internet (ou GitHub ne répond pas). " +
                             "Réessaie plus tard.\n\n\(erreur.localizedDescription)")
                return
            }
            if let http = reponse as? HTTPURLResponse, http.statusCode != 200 {
                self.echouer(silencieux: silencieux,
                             "Le serveur a répondu \(http.statusCode). Réessaie plus tard.")
                return
            }
            guard let donnees, let lue = Self.lireManifeste(donnees) else {
                self.echouer(silencieux: silencieux,
                             "La fiche de version est illisible. Préviens Félix.")
                return
            }
            self.surMain {
                self.info = lue
                self.etat = Self.comparer(lue.version, self.versionInstallee) > 0
                    ? .disponible : .aJour
            }
        }.resume()
    }

    private func echouer(silencieux: Bool, _ message: String) {
        surMain {
            if silencieux {
                self.etat = .repos          // au lancement : on ne dérange pas
            } else {
                self.etat = .erreur(message)
            }
        }
    }

    // MARK: - 2. installer

    func installer() {
        guard let info = info, let app = CheminsMAJ.appInstallee else {
            surMain { self.etat = .erreur(
                "L'app ne tourne pas depuis un dossier Applications : " +
                "réinstalle-la avec INSTALLER.command.") }
            return
        }
        guard let url = URL(string: info.zip) else {
            surMain { self.etat = .erreur("Adresse du paquet invalide.") }
            return
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EmpreinteMAJ-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            surMain { self.etat = .erreur("Impossible de préparer le téléchargement.") }
            return
        }

        surMain { self.progression = 0; self.etat = .telechargement }
        let zip = temp.appendingPathComponent("paquet.zip")
        let t = Telechargeur(destination: zip) { [weak self] p in
            self?.surMain { self?.progression = p }
        } fin: { [weak self] souci in
            guard let self else { return }
            if let souci {
                try? self.fm.removeItem(at: temp)
                self.surMain { self.etat = .erreur(souci) }
                return
            }
            self.surMain { self.etat = .installation }
            DispatchQueue.global(qos: .userInitiated).async {
                if let souci = self.preparerEchange(temp: temp, zip: zip,
                                                   info: info, app: app) {
                    try? self.fm.removeItem(at: temp)
                    self.surMain { self.etat = .erreur(souci) }
                }
                // Si tout va bien, le script est lancé et l'app se ferme :
                // il n'y a plus rien à afficher.
            }
        }
        telechargeur = t
        t.demarrer(url)
    }

    /// Dézippe, VALIDE, sauvegarde, écrit le script d'échange et le lance.
    /// Renvoie un message d'erreur, ou nil si l'échange est en route.
    private func preparerEchange(temp: URL, zip: URL, info: InfoVersion,
                                 app: URL) -> String? {
        let extrait = temp.appendingPathComponent("extrait")
        if !Self.executer("/usr/bin/ditto", ["-x", "-k", zip.path, extrait.path]) {
            return "Le paquet téléchargé est illisible (téléchargement interrompu ?). " +
                   "Réessaie."
        }
        guard let neuve = Self.trouverBundle(dans: extrait) else {
            return "Le paquet ne contient pas l'application. Préviens Félix."
        }
        if let souci = Self.validerBundle(neuve, versionAnnoncee: info.version) {
            return "Le paquet reçu n'est pas valable : \(souci). Rien n'a été changé."
        }

        // --- sauvegarde de la version actuelle (le filet du retour arrière)
        let sauvegarde = CheminsMAJ.sauvegarde
        try? fm.createDirectory(at: sauvegarde, withIntermediateDirectories: true)
        let copieApp = Self.appSauvegardee
        try? fm.removeItem(at: copieApp)
        if !Self.executer("/usr/bin/ditto", [app.path, copieApp.path]) {
            return "Impossible de sauvegarder la version actuelle : on n'installe rien."
        }
        let vActuelle = versionInstallee
        try? vActuelle.write(to: sauvegarde.appendingPathComponent("version.txt"),
                             atomically: true, encoding: .utf8)
        surMain { self.versionSauvegardee = vActuelle }

        // --- le script d'échange
        try? fm.createDirectory(at: CheminsMAJ.travail, withIntermediateDirectories: true)
        let script = temp.appendingPathComponent("echanger.sh")
        let texte = Self.scriptEchange(app: app, source: neuve,
                                       sauvegarde: copieApp,
                                       venv: CheminsMAJ.venv,
                                       journal: CheminsMAJ.journal,
                                       paquets: info.paquets,
                                       temp: temp)
        do {
            try texte.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return "Impossible d'écrire le script d'installation."
        }
        return lancerScript(script) ? nil : "Impossible de lancer l'installation."
    }

    // MARK: - 3. retour arrière

    /// Réinstalle la version d'avant depuis la sauvegarde.
    func revenirEnArriere() {
        guard let app = CheminsMAJ.appInstallee else { return }
        let copie = Self.appSauvegardee
        guard fm.fileExists(atPath: copie.path) else {
            surMain { self.etat = .erreur("Aucune version précédente sauvegardée.") }
            return
        }
        surMain { self.etat = .installation }
        DispatchQueue.global(qos: .userInitiated).async {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("EmpreinteRetour-\(UUID().uuidString)")
            try? self.fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try? self.fm.createDirectory(at: CheminsMAJ.travail,
                                         withIntermediateDirectories: true)
            let script = temp.appendingPathComponent("revenir.sh")
            // La source EST la sauvegarde ; aucun paquet Python à toucher.
            let texte = Self.scriptEchange(app: app, source: copie,
                                           sauvegarde: copie,
                                           venv: CheminsMAJ.venv,
                                           journal: CheminsMAJ.journal,
                                           paquets: [], temp: temp)
            do {
                try texte.write(to: script, atomically: true, encoding: .utf8)
                try self.fm.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)
            } catch {
                self.surMain { self.etat = .erreur("Retour impossible : script illisible.") }
                return
            }
            if !self.lancerScript(script) {
                self.surMain { self.etat = .erreur("Retour impossible : lancement refusé.") }
            }
        }
    }

    private func relireSauvegarde() {
        let note = CheminsMAJ.sauvegarde.appendingPathComponent("version.txt")
        if let t = try? String(contentsOf: note, encoding: .utf8) {
            versionSauvegardee = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - outils

    private func surMain(_ bloc: @escaping () -> Void) {
        if Thread.isMainThread { bloc() } else { DispatchQueue.main.async(execute: bloc) }
    }

    /// Lance le script détaché (il doit survivre à la fermeture de l'app)
    /// puis demande la fermeture.
    private func lancerScript(_ script: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + & : le script continue tout seul quand l'app se ferme.
        p.arguments = ["-c", "nohup /bin/bash \"$1\" \"$2\" >/dev/null 2>&1 &",
                       "sh", script.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        quitter()
        return true
    }

    @discardableResult
    static func executer(_ outil: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: outil)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: lecture du manifeste

    static func lireManifeste(_ donnees: Data) -> InfoVersion? {
        guard let brut = try? JSONSerialization.jsonObject(with: donnees),
              let o = brut as? [String: Any],
              let version = (o["version"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              let zip = o["zip"] as? String, !zip.isEmpty
        else { return nil }
        return InfoVersion(version: version,
                           date: o["date"] as? String ?? "",
                           notes: o["notes"] as? String ?? "",
                           zip: zip,
                           paquets: o["paquets_python"] as? [String] ?? [])
    }

    // MARK: comparaison de versions

    /// Comparaison NUMÉRIQUE, composant par composant : 2.10 est plus
    /// récent que 2.9 (une comparaison de texte dirait le contraire).
    /// Renvoie 1 si a > b, -1 si a < b, 0 si égales.
    static func comparer(_ a: String, _ b: String) -> Int {
        let ca = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let cb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0
            let y = i < cb.count ? cb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    // MARK: validation du paquet reçu

    /// Cherche le premier `*.app` dans le dossier dézippé (le zip contient
    /// un dossier « Empreinte MMD » avec l'app dedans).
    static func trouverBundle(dans dossier: URL) -> URL? {
        let fm = FileManager.default
        var aExplorer = [dossier]
        var profondeur = 0
        while !aExplorer.isEmpty && profondeur < 4 {
            var suivants: [URL] = []
            for d in aExplorer {
                let contenu = (try? fm.contentsOfDirectory(at: d,
                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for u in contenu.sorted(by: { $0.path < $1.path }) {
                    if u.pathExtension == "app" { return u }
                    var estDossier: ObjCBool = false
                    if fm.fileExists(atPath: u.path, isDirectory: &estDossier),
                       estDossier.boolValue { suivants.append(u) }
                }
            }
            aExplorer = suivants
            profondeur += 1
        }
        return nil
    }

    /// Un vrai bundle, avec un exécutable, et au moins la version annoncée.
    /// Renvoie nil si tout va bien, sinon la raison du refus.
    static func validerBundle(_ app: URL, versionAnnoncee: String) -> String? {
        let fm = FileManager.default
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let donnees = try? Data(contentsOf: plist),
              let brut = try? PropertyListSerialization.propertyList(
                  from: donnees, options: [], format: nil),
              let dict = brut as? [String: Any]
        else { return "Info.plist illisible" }

        guard let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty else {
            return "aucun exécutable déclaré"
        }
        let binaire = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(exe)
        guard fm.isExecutableFile(atPath: binaire.path) else {
            return "l'exécutable « \(exe) » est absent"
        }
        guard let v = dict["CFBundleShortVersionString"] as? String else {
            return "version absente du bundle"
        }
        if comparer(v, versionAnnoncee) < 0 {
            return "le paquet contient la version \(v), pas la \(versionAnnoncee)"
        }
        return nil
    }

    // MARK: le script d'échange

    /// Protège une valeur pour le shell (chemins avec espaces, apostrophes).
    static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Le script qui remplace l'app pendant qu'elle est fermée.
    /// Sert AUSSI au retour arrière (la source est alors la sauvegarde).
    static func scriptEchange(app: URL, source: URL, sauvegarde: URL, venv: URL,
                              journal: URL, paquets: [String], temp: URL) -> String {
        let listePaquets = paquets.map { shq($0) }.joined(separator: " ")
        return """
        #!/bin/bash
        # =====================================================================
        # echanger.sh — écrit par l'app « Empreinte » pour se remplacer.
        # Généré automatiquement : ne pas modifier à la main.
        #
        # ⚠️  SÉCURITÉ : ce script n'écrit QUE dans trois endroits.
        #        1. le bundle de l'application ................ $APP
        #        2. l'environnement Python dédié .............. $VENV
        #        3. la sauvegarde de la version précédente .... $SAUVEGARDE
        #     Il ne touche JAMAIS aux commandes de la cliente
        #     (~/Documents/Empreintes MMD, ou le dossier choisi dans l'app)
        #     ni aux réglages (~/.empreinte_mmd.json) : ces chemins
        #     n'apparaissent nulle part ci-dessous, et les assertions de la
        #     section « garde-fous » refusent de démarrer si la cible n'est
        #     pas un bundle .app hors des dossiers de données.
        # =====================================================================
        PID="$1"
        APP=\(shq(app.path))
        SOURCE=\(shq(source.path))
        SAUVEGARDE=\(shq(sauvegarde.path))
        VENV=\(shq(venv.path))
        JOURNAL=\(shq(journal.path))
        TEMP=\(shq(temp.path))
        PAQUETS=(\(listePaquets))

        mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null
        log() { printf '%s  %s\\n' "$(date '+%d/%m %H:%M:%S')" "$*" >> "$JOURNAL" 2>/dev/null; }
        refus() { log "REFUS — $*"; exit 1; }

        log "──── échange demandé ────"
        log "app     : $APP"
        log "source  : $SOURCE"

        # ---- garde-fous (avant la moindre écriture) -------------------------
        case "$APP" in
            *.app) ;;
            *) refus "la cible n'est pas un bundle .app : $APP" ;;
        esac
        case "$APP" in
            *"/Documents/"*|*"Empreintes MMD"*|*".empreinte_mmd.json"*)
                refus "la cible est dans les données de la cliente : $APP" ;;
        esac
        case "$SAUVEGARDE" in
            *"/Documents/"*|*"Empreintes MMD"*)
                refus "la sauvegarde est dans les données : $SAUVEGARDE" ;;
        esac
        case "$VENV" in
            *"/Documents/"*|*"Empreintes MMD"*)
                refus "l'environnement Python est dans les données : $VENV" ;;
        esac
        [ -d "$APP" ]    || refus "application introuvable"
        [ -d "$SOURCE" ] || refus "version à installer introuvable"
        [ -x "$SOURCE/Contents/MacOS/Empreinte" ] || refus "version à installer sans exécutable"
        [ -d "$SAUVEGARDE" ] || refus "pas de sauvegarde : on n'échange rien"

        restaurer() {
            log "→ restauration de la version précédente"
            rm -rf "$APP"
            ditto "$SAUVEGARDE" "$APP" >/dev/null 2>&1
            xattr -cr "$APP" >/dev/null 2>&1
            codesign --force --deep --sign - "$APP" >/dev/null 2>&1
            open "$APP" >/dev/null 2>&1
            log "→ ancienne version remise en place"
            exit 1
        }

        # ---- 1. attendre que l'app soit vraiment fermée ---------------------
        if [ -n "$PID" ]; then
            i=0
            while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do
                sleep 0.1
                i=$((i + 1))
            done
        fi
        pkill -x Empreinte >/dev/null 2>&1
        sleep 0.6

        # ---- 2. l'échange ---------------------------------------------------
        log "remplacement du bundle"
        rm -rf "$APP" || refus "suppression impossible (dossier protégé ?)"
        if ! ditto "$SOURCE" "$APP" >/dev/null 2>&1; then
            log "copie ratée"
            restaurer
        fi
        xattr -cr "$APP" >/dev/null 2>&1
        codesign --force --deep --sign - "$APP" >/dev/null 2>&1
        log "bundle remplacé"

        # ---- 3. les bibliothèques Python qui manquent -----------------------
        PY="$VENV/bin/python3"
        if [ "${#PAQUETS[@]}" -gt 0 ] && [ -x "$PY" ]; then
            for p in "${PAQUETS[@]}"; do
                if "$PY" -m pip show "$p" >/dev/null 2>&1; then
                    log "paquet déjà présent : $p"
                else
                    log "installation du paquet manquant : $p"
                    "$PY" -m pip install "$p" >>"$JOURNAL" 2>&1 \\
                        || log "⚠️ installation de $p impossible (Internet ?)"
                fi
            done
        elif [ "${#PAQUETS[@]}" -gt 0 ]; then
            log "pas d'environnement Python dédié ($VENV) : paquets non vérifiés"
        fi

        # ---- 4. relance + filet de sécurité ---------------------------------
        # Une app qui plante au démarrage apparaît une fraction de seconde
        # dans la liste des processus : voir le processus UNE fois ne prouve
        # rien. On attend d'abord, on cherche, puis on RECONFIRME plus tard.
        demarree() { pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; }

        log "relance de l'application"
        open "$APP" >/dev/null 2>&1
        sleep 6
        VIVANT=0
        i=0
        while [ "$i" -lt 20 ]; do
            if demarree; then
                VIVANT=1
                break
            fi
            sleep 1
            i=$((i + 1))
        done
        if [ "$VIVANT" = "1" ]; then
            sleep 5
            demarree || { VIVANT=0; log "l'app s'est ouverte puis refermée aussitôt"; }
        fi
        if [ "$VIVANT" = "1" ]; then
            log "✅ terminé : la nouvelle version tourne"
        else
            log "❌ la nouvelle version ne démarre pas"
            restaurer
        fi

        # ---- ménage (après coup, pour ne pas se couper l'herbe sous le pied)
        (sleep 5; rm -rf "$TEMP") >/dev/null 2>&1 &
        exit 0
        """
    }
}

// MARK: - téléchargement avec progression

/// Télécharge un fichier en montrant l'avancement.
final class Telechargeur: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progression: (Double) -> Void
    private let fin: (String?) -> Void          // nil = tout va bien
    private var session: URLSession?
    private var souci: String?

    init(destination: URL,
         progression: @escaping (Double) -> Void,
         fin: @escaping (String?) -> Void) {
        self.destination = destination
        self.progression = progression
        self.fin = fin
    }

    func demarrer(_ url: URL) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        s.downloadTask(with: req).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite totalBytesExpected: Int64) {
        guard totalBytesExpected > 0 else { return }
        progression(min(1, Double(totalBytesWritten) / Double(totalBytesExpected)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            souci = "Le paquet n'a pas été trouvé sur GitHub (erreur \(http.statusCode)). " +
                    "Préviens Félix."
            return
        }
        // Le fichier temporaire disparaît dès qu'on rend la main : on copie
        // tout de suite, ici même.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            souci = "Impossible d'enregistrer le paquet téléchargé."
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error = error {
            fin("Le téléchargement s'est interrompu (connexion ?).\n\n" +
                error.localizedDescription)
        } else {
            fin(souci)
        }
    }
}

// MARK: - le panneau visible par maman

/// Ce que maman voit quand elle clique « Rechercher une mise à jour ».
/// Jamais de fenêtre imposée : ce panneau ne s'ouvre que sur son clic.
struct PanneauMiseAJour: View {
    @ObservedObject var moteur: Moteur
    @ObservedObject var maj: MiseAJour
    @Environment(\.echelle) private var echelle
    @Environment(\.dismiss) private var fermer
    @State private var confirmeRetour = false

    /// On ne remplace jamais l'app au milieu d'un scan ou d'un rendu.
    private var travailEnCours: Bool {
        moteur.occupe || moteur.apercuEnCours || moteur.composeEnCours
            || moteur.exportEnCours
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * echelle) {
            enTete
            contenu
                .frame(maxWidth: .infinity, alignment: .leading)
            piedDePage
        }
        .padding(26 * echelle)
        .frame(width: 470 * echelle)
        .background(MMD.creme)
        .alert("Revenir à la version précédente ?", isPresented: $confirmeRetour) {
            Button("Revenir", role: .destructive) { maj.revenirEnArriere() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'app va se fermer, remettre la version \(maj.versionSauvegardee ?? "") " +
                 "en place, puis se rouvrir. Tes commandes ne sont pas concernées.")
        }
    }

    private var enTete: some View {
        HStack(spacing: 14 * echelle) {
            LogoMarque(taille: 44 * echelle)
            VStack(alignment: .leading, spacing: 2 * echelle) {
                Text("Mise à jour de l'application")
                    .police(19, .black, .rounded).foregroundColor(MMD.noir)
                Text("Version installée : \(maj.versionInstallee)")
                    .police(12, .medium).foregroundColor(MMD.gris)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var contenu: some View {
        switch maj.etat {

        case .repos, .verification:
            Chargement(texte: "Recherche d'une nouvelle version…", taille: 44)
                .frame(maxWidth: .infinity).padding(.vertical, 24 * echelle)

        case .aJour:
            ligne(symbole: "checkmark.circle.fill", couleur: MMD.bleu,
                  titre: "Tout est à jour",
                  detail: "Tu as déjà la dernière version. Rien à faire.")

        case .disponible:
            VStack(alignment: .leading, spacing: 12 * echelle) {
                ligne(symbole: "arrow.down.circle.fill", couleur: MMD.rouge,
                      titre: "Nouvelle version \(maj.info?.version ?? "")",
                      detail: maj.info.map { "Publiée le \($0.dateLisible)" } ?? "")
                if let notes = maj.info?.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .police(13, .medium).foregroundColor(MMD.noir)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14 * echelle)
                    }
                    .frame(maxHeight: 150 * echelle)
                    .carteMMD()
                }
                if travailEnCours {
                    Text("Un scan ou un rendu est en cours : termine-le d'abord, " +
                         "l'app doit se fermer pour s'installer.")
                        .police(12, .semibold).foregroundColor(MMD.rouge)
                }
                Text("Tes commandes et tes réglages ne sont pas touchés.")
                    .police(11.5).foregroundColor(MMD.gris)
            }

        case .telechargement:
            VStack(alignment: .leading, spacing: 10 * echelle) {
                Text("Téléchargement… \(Int(maj.progression * 100)) %")
                    .police(13.5, .bold, .rounded).foregroundColor(MMD.noir)
                ProgressView(value: maj.progression)
                    .tint(MMD.bleu)
                Text("Ne ferme pas l'app.")
                    .police(11.5).foregroundColor(MMD.gris)
            }
            .padding(.vertical, 10 * echelle)

        case .installation:
            Chargement(texte: "Installation…\nL'app va se fermer et se rouvrir toute seule.",
                       taille: 44)
                .frame(maxWidth: .infinity).padding(.vertical, 20 * echelle)

        case .erreur(let message):
            ligne(symbole: "exclamationmark.triangle.fill", couleur: MMD.rouge,
                  titre: "Ça n'a pas marché", detail: message)
        }
    }

    private func ligne(symbole: String, couleur: Color,
                       titre: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12 * echelle) {
            Image(systemName: symbole).police(22, .regular).foregroundColor(couleur)
            VStack(alignment: .leading, spacing: 4 * echelle) {
                Text(titre).police(15, .black, .rounded).foregroundColor(MMD.noir)
                if !detail.isEmpty {
                    Text(detail).police(12.5, .medium).foregroundColor(MMD.gris)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var piedDePage: some View {
        HStack(spacing: 10 * echelle) {
            if maj.retourPossible && !maj.occupe {
                Button("Revenir à la version \(maj.versionSauvegardee ?? "")") {
                    confirmeRetour = true
                }
                .buttonStyle(BoutonDiscret())
            }
            Spacer()
            if !maj.occupe {
                Button("Fermer") { fermer() }
                    .buttonStyle(BoutonSecondaire())
                    .keyboardShortcut(.cancelAction)
            }
            switch maj.etat {
            case .disponible:
                Button("Installer") { maj.installer() }
                    .buttonStyle(BoutonPrincipal(actif: !travailEnCours))
                    .disabled(travailEnCours)
                    .keyboardShortcut(.defaultAction)
            case .erreur:
                Button("Réessayer") { maj.verifier() }
                    .buttonStyle(BoutonPrincipal())
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - mode ligne de commande (tests et dépannage)

/// Permet de jouer une mise à jour sans interface :
///
///     Empreinte.app/Contents/MacOS/Empreinte --maj-verifier
///     Empreinte.app/Contents/MacOS/Empreinte --maj-installer
///     Empreinte.app/Contents/MacOS/Empreinte --maj-retour
///
/// C'est EXACTEMENT le code des boutons, sans SwiftUI : c'est ce qui permet
/// de vérifier tout le mécanisme (téléchargement, validation, échange,
/// retour arrière) avant de livrer.
enum OutilMAJ {
    /// Petite boîte partagée avec le script : « l'app se serait fermée ici ».
    private final class Drapeau { var leve = false }

    static func traiterArguments() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        let maj = MiseAJour.partagee
        let drapeau = Drapeau()
        maj.quitter = { drapeau.leve = true }

        let verification: (EtatMAJ) -> Bool = { etat in
            switch etat {
            case .aJour, .disponible, .erreur: return true
            default: return false
            }
        }
        let echec: (EtatMAJ) -> Bool = { etat in
            if case .erreur = etat { return true }
            return false
        }

        switch args[1] {
        case "--version":
            print(maj.versionInstallee)
            return true

        case "--maj-verifier":
            maj.verifier()
            attendre(maj, drapeau, jusqua: verification)
            decrire(maj)
            return true

        case "--maj-installer":
            maj.verifier()
            attendre(maj, drapeau, jusqua: verification)
            decrire(maj)
            guard maj.etat == .disponible else { return true }
            print("→ installation…")
            maj.installer()
            attendre(maj, drapeau, jusqua: echec)
            decrire(maj)
            return true

        case "--maj-retour":
            maj.revenirEnArriere()
            attendre(maj, drapeau, jusqua: echec)
            decrire(maj)
            return true

        default:
            return false
        }
    }

    private static func attendre(_ maj: MiseAJour, _ drapeau: Drapeau,
                                 jusqua: (EtatMAJ) -> Bool,
                                 secondes: Double = 300) {
        let limite = Date().addingTimeInterval(secondes)
        while !drapeau.leve && !jusqua(maj.etat) && Date() < limite {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if drapeau.leve { print("→ l'app se ferme, le script d'échange prend le relais.") }
    }

    private static func decrire(_ maj: MiseAJour) {
        print("version installée : \(maj.versionInstallee)")
        if let i = maj.info {
            print("version publiée  : \(i.version)  (\(i.date))")
            print("notes            : \(i.notes)")
            print("paquets          : \(i.paquets.joined(separator: ", "))")
        }
        switch maj.etat {
        case .repos:         print("état : rien à signaler")
        case .verification:  print("état : vérification en cours")
        case .aJour:         print("état : à jour")
        case .disponible:    print("état : MISE À JOUR DISPONIBLE")
        case .telechargement:print("état : téléchargement")
        case .installation:  print("état : installation lancée")
        case .erreur(let m): print("état : ERREUR — \(m)")
        }
    }
}
