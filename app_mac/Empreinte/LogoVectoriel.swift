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
    static let rayonBord: CGFloat = 87.75       // bord extérieur de l'anneau
    static let rayonAnneau: CGFloat = 85.6      // milieu du grand anneau
    static let rayonCentre: CGFloat = 28.4      // milieu du petit anneau
    static let epaisseurAnneau: CGFloat = 4.25
    static let epaisseurLettre: CGFloat = 6.5
    static let rayonPoint: CGFloat = 3.7
    static let points: [CGPoint] = [CGPoint(x: -6.97, y: 45.49), CGPoint(x: 2.29, y: 46.79), CGPoint(x: 11.71, y: 45.66)]
    /// x0, y0, x1, y1 des deux bandes du drapeau (le blanc reste « vide »)
    static let bleu: (CGFloat, CGFloat, CGFloat, CGFloat) = (-8.05, 60.83, -1.75, 75.63)
    static let rouge: (CGFloat, CGFloat, CGFloat, CGFloat) = (4.95, 60.83, 13.95, 75.63)

    /// Squelette des lettres « MAMAN M'A DIT » (à tracer avec bouts ronds).
    static func lettres(_ q: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var p = Path()
        p.move(to: q(9.41, -46.67))
        p.addLine(to: q(19.39, -69.56))
        p.addLine(to: q(19.14, -50.37))
        p.addLine(to: q(32.95, -64.18))
        p.addLine(to: q(23.85, -41.22))
        p.move(to: q(46.94, -53.36))
        p.addLine(to: q(45.53, -51.96))
        p.move(to: q(35.95, -30.77))
        p.addLine(to: q(60.05, -38.56))
        p.addLine(to: q(43.29, -18.81))
        p.move(to: q(43.91, -31.00))
        p.addLine(to: q(45.53, -27.61))
        p.move(to: q(69.81, 9.92))
        p.addLine(to: q(48.59, 5.32))
        p.move(to: q(69.81, 9.92))
        p.addCurve(to: q(48.59, 5.32), control1: q(77.42, 29.79), control2: q(31.81, 15.79))
        p.move(to: q(61.19, 37.01))
        p.addLine(to: q(39.85, 24.13))
        p.move(to: q(52.53, 48.52))
        p.addLine(to: q(45.40, 55.06))
        p.move(to: q(45.20, 47.65))
        p.addLine(to: q(32.19, 33.66))
        p.move(to: q(-28.92, 37.12))
        p.addLine(to: q(-47.90, 53.41))
        p.addLine(to: q(-39.32, 36.17))
        p.addLine(to: q(-57.57, 42.38))
        p.addLine(to: q(-39.42, 25.81))
        p.move(to: q(-42.68, 19.93))
        p.addLine(to: q(-68.11, 19.59))
        p.addLine(to: q(-45.99, 6.13))
        p.move(to: q(-50.74, 13.99))
        p.addLine(to: q(-51.59, 11.84))
        p.move(to: q(-46.67, -0.98))
        p.addLine(to: q(-71.18, -6.67))
        p.addLine(to: q(-52.19, -9.88))
        p.addLine(to: q(-68.05, -21.10))
        p.addLine(to: q(-43.91, -16.28))
        p.move(to: q(-40.91, -22.38))
        p.addLine(to: q(-55.89, -42.92))
        p.addLine(to: q(-31.88, -33.13))
        p.move(to: q(-41.20, -32.21))
        p.addLine(to: q(-39.45, -35.68))
        p.move(to: q(-25.56, -37.29))
        p.addLine(to: q(-37.35, -59.28))
        p.addLine(to: q(-16.14, -42.28))
        p.addLine(to: q(-27.83, -64.28))
        return p
    }
}

/// Le logo complet. `tourne` fait tourner l'anneau de texte autour du centre
/// immobile : c'est l'indicateur de chargement de la maison.
struct LogoMMDVectoriel: View {
    var encre: Color = Color(red: 0.07, green: 0.07, blue: 0.08)
    var tourne: Bool = false
    var drapeau: Bool = true
    /// tours par seconde quand `tourne`
    var vitesse: Double = 0.16

    var body: some View {
        GeometryReader { geo in
            let cote = min(geo.size.width, geo.size.height)
            ZStack {
                if tourne {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        anneau(cote)
                            .rotationEffect(.degrees((t * vitesse * 360)
                                .truncatingRemainder(dividingBy: 360)))
                    }
                } else {
                    anneau(cote)
                }
                centre(cote)
            }
            .frame(width: cote, height: cote)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Maman m'a dit")
    }

    private typealias G = LogoMMDGeometrie

    /// Grand anneau + texte (la partie qui tourne).
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

    /// Petit anneau, points de suspension et drapeau (immobiles).
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
