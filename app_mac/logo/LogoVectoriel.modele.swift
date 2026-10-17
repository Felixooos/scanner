import SwiftUI

// LogoVectoriel.swift — le logo « Maman m'a dit », redessiné trait pour trait
// d'après le logo d'origine : lettres monolignes à bouts ronds dont chaque
// trait a été ajusté sur l'image fournie (même tracé à la main, mêmes petites
// irrégularités), anneaux et points mesurés au pixel près.
//
// Fichier GÉNÉRÉ (outil : logo/generer.py) — ne pas retoucher les coordonnées
// à la main : elles sont exprimées dans le repère du logo d'origine, centre en
// (0, 0), bord extérieur de l'anneau à `rayonBord`.

enum LogoMMDGeometrie {
    static let rayonBord: CGFloat = @@R_BORD@@       // bord extérieur de l'anneau
    static let rayonAnneau: CGFloat = @@R_EXT@@      // milieu du grand anneau
    static let rayonCentre: CGFloat = @@R_INT@@      // milieu du petit anneau
    static let epaisseurAnneau: CGFloat = @@E_ANN@@
    static let epaisseurLettre: CGFloat = @@W@@
    static let rayonPoint: CGFloat = @@R_PT@@
    static let points: [CGPoint] = [@@POINTS@@]
    /// x0, y0, x1, y1 des deux bandes du drapeau (le blanc reste « vide »)
    static let bleu: (CGFloat, CGFloat, CGFloat, CGFloat) = (@@BLEU@@)
    static let rouge: (CGFloat, CGFloat, CGFloat, CGFloat) = (@@ROUGE@@)

    /// Squelette des lettres « MAMAN M'A DIT » (à tracer avec bouts ronds).
    static func lettres(_ q: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var p = Path()
@@LETTRES@@
        return p
    }
}

/// Le logo complet. `tourne` fait tourner tout le badge sur lui-même
/// (drapeau compris) : c'est l'indicateur de chargement de la maison.
struct LogoMMDVectoriel: View {
    var encre: Color = Color(red: 0.07, green: 0.07, blue: 0.08)
    var tourne: Bool = false
    var drapeau: Bool = true
    /// tours par seconde quand `tourne`
    var vitesse: Double = 0.16

    var body: some View {
        GeometryReader { geo in
            let cote = min(geo.size.width, geo.size.height)
            Group {
                if tourne {
                    // tout le badge tourne d'un bloc : texte, anneaux, points
                    // ET drapeau, comme une médaille qu'on fait pivoter
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        badge(cote)
                            .rotationEffect(.degrees((t * vitesse * 360)
                                .truncatingRemainder(dividingBy: 360)))
                    }
                } else {
                    badge(cote)
                }
            }
            .frame(width: cote, height: cote)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Maman m'a dit")
    }

    private typealias G = LogoMMDGeometrie

    /// Le badge entier, dans un carré de `cote`.
    private func badge(_ cote: CGFloat) -> some View {
        ZStack {
            anneau(cote)
            centre(cote)
        }
    }

    /// Grand anneau + texte.
    private func anneau(_ cote: CGFloat) -> some View {
        Canvas { ctx, taille in
            let k = taille.width / 2 / (G.rayonBord + 1)
            let o = CGPoint(x: taille.width / 2, y: taille.height / 2)
            let q: (CGFloat, CGFloat) -> CGPoint = { CGPoint(x: o.x + $0 * k, y: o.y + $1 * k) }
            let r = G.rayonAnneau * k
            ctx.stroke(Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(encre), lineWidth: G.epaisseurAnneau * k)
            ctx.stroke(G.lettres(q), with: .color(encre),
                       style: StrokeStyle(lineWidth: G.epaisseurLettre * k,
                                          lineCap: .round, lineJoin: .round))
        }
        .frame(width: cote, height: cote)
    }

    /// Petit anneau, points de suspension et drapeau.
    private func centre(_ cote: CGFloat) -> some View {
        Canvas { ctx, taille in
            let k = taille.width / 2 / (G.rayonBord + 1)
            let o = CGPoint(x: taille.width / 2, y: taille.height / 2)
            let r = G.rayonCentre * k
            ctx.stroke(Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(encre), lineWidth: G.epaisseurAnneau * k)
            for p in G.points {
                let rp = G.rayonPoint * k
                ctx.fill(Path(ellipseIn: CGRect(x: o.x + p.x * k - rp, y: o.y + p.y * k - rp,
                                                 width: 2 * rp, height: 2 * rp)),
                         with: .color(encre))
            }
            guard drapeau else { return }
            for (b, couleur) in [(G.bleu, Color(red: 0.02, green: 0.02, blue: 1.0)),
                                 (G.rouge, Color(red: 1.0, green: 0.06, blue: 0.06))] {
                ctx.fill(Path(CGRect(x: o.x + b.0 * k, y: o.y + b.1 * k,
                                     width: (b.2 - b.0) * k, height: (b.3 - b.1) * k)),
                         with: .color(couleur))
            }
        }
        .frame(width: cote, height: cote)
    }
}
