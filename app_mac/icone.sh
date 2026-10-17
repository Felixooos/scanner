#!/bin/bash
# icone.sh — régénère app_mac/Empreinte.icns depuis logo/logo_mmd_1024.png :
# le badge « Maman m'a dit » posé sur une tuile crème aux coins très arrondis,
# façon icône macOS moderne (tuile de 824 px centrée dans 1024, ombre douce).
#
#   ./icone.sh          écrit Empreinte.icns (puis relance construire.sh)
set -e
ICI="$(cd "$(dirname "$0")" && pwd)"
LOGO="$ICI/logo/logo_mmd_1024.png"
TRAVAIL="$(mktemp -d)"
ICONSET="$TRAVAIL/Empreinte.iconset"
mkdir -p "$ICONSET"
[ -f "$LOGO" ] || { echo "❌ logo introuvable : $LOGO" >&2; exit 1; }

echo "→ Composition de l'icône 1024…"
/usr/bin/python3 - "$LOGO" "$TRAVAIL/icone_1024.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter

logo_chemin, sortie = sys.argv[1], sys.argv[2]
T = 1024                      # canevas
SS = 4                        # sur-échantillonnage pour des bords nets
C = T * SS
tuile = int(824 * SS)         # la tuile standard des icônes macOS
rayon = int(tuile * 0.225)    # coins très arrondis
x0 = (C - tuile) // 2
y0 = (C - tuile) // 2

# --- l'ombre douce sous la tuile
ombre = Image.new("RGBA", (C, C), (0, 0, 0, 0))
d = ImageDraw.Draw(ombre)
d.rounded_rectangle([x0, y0 + 10 * SS, x0 + tuile, y0 + tuile + 10 * SS],
                    radius=rayon, fill=(22, 21, 23, 70))
ombre = ombre.filter(ImageFilter.GaussianBlur(14 * SS))

# --- la tuile crème, légèrement plus claire en haut (papier)
masque = Image.new("L", (C, C), 0)
ImageDraw.Draw(masque).rounded_rectangle([x0, y0, x0 + tuile, y0 + tuile],
                                         radius=rayon, fill=255)
haut, bas = (255, 253, 248), (249, 244, 235)
degrade = Image.new("RGB", (1, tuile))
for y in range(tuile):
    t = y / (tuile - 1)
    degrade.putpixel((0, y), tuple(int(haut[i] + (bas[i] - haut[i]) * t) for i in range(3)))
degrade = degrade.resize((tuile, tuile))
fond = Image.new("RGBA", (C, C), (0, 0, 0, 0))
fond.paste(degrade, (x0, y0))
fond.putalpha(masque)

# --- fin liseré encre, très discret, comme le trait des cartes de l'app
lisere = Image.new("RGBA", (C, C), (0, 0, 0, 0))
ImageDraw.Draw(lisere).rounded_rectangle([x0, y0, x0 + tuile, y0 + tuile],
                                         radius=rayon, outline=(22, 21, 23, 28),
                                         width=3 * SS)

# --- le logo, centré, à 66 % de la tuile
logo = Image.open(logo_chemin).convert("RGBA")
# le PNG du logo est sur fond blanc : on le rend transparent (fond -> alpha)
px = logo.load()
w, h = logo.size
for y in range(h):
    for x in range(w):
        r, g, b, a = px[x, y]
        if r > 245 and g > 245 and b > 245:
            px[x, y] = (r, g, b, 0)
cote = int(tuile * 0.66)
logo = logo.resize((cote, cote), Image.LANCZOS)
lx = (C - cote) // 2
ly = (C - cote) // 2

image = Image.alpha_composite(ombre, fond)
image = Image.alpha_composite(image, lisere)
image.alpha_composite(logo, (lx, ly))
image = image.resize((T, T), Image.LANCZOS)
image.save(sortie)
print("   icône 1024 écrite")
PY

echo "→ Déclinaisons (iconutil)…"
for taille in 16 32 128 256 512; do
    sips -z $taille $taille "$TRAVAIL/icone_1024.png" --out "$ICONSET/icon_${taille}x${taille}.png" >/dev/null
    double=$((taille * 2))
    sips -z $double $double "$TRAVAIL/icone_1024.png" --out "$ICONSET/icon_${taille}x${taille}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICI/Empreinte.icns"
cp "$TRAVAIL/icone_1024.png" "$ICI/.build_bin/icone_1024.png" 2>/dev/null || true
rm -rf "$TRAVAIL"
echo "✅ $ICI/Empreinte.icns"
