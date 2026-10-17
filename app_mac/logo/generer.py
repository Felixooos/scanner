"""Génère le logo vectoriel MMD (SVG + Swift + PNG haute déf) depuis ajust2.json."""
import json, numpy as np, cv2
A=json.load(open('ajust2.json')); L=[A['lettres'][k] for k in sorted(A['lettres'],key=int)]
cx,cy=173.654,100.775; RM=59.0
W=6.5; R_EXT=85.6; R_INT=28.4; E_ANN=4.25; R_BORD=87.75
POINTS=[(-6.97,45.49),(2.29,46.79),(11.71,45.66)]; R_PT=3.7
BLEU=(-8.05,60.83,-1.75,75.63); ROUGE=(4.95,60.83,13.95,75.63)
def g(l,P):
    a=np.deg2rad(l['ang']); c=np.array([RM*np.sin(a), -RM*np.cos(a)])
    R=np.array([[np.cos(a),-np.sin(a)],[np.sin(a),np.cos(a)]])
    return (np.asarray(P,float).reshape(-1,2)-24)@R.T + c
# chaque lettre -> liste de sous-chemins ('L', pts) ou ('C', p0,c1,c2,p3)
chemins=[]
for l in L:
    P=np.array(l['p']).reshape(-1,2); n=l['nom']
    if n in ('I','apo'): chemins.append(('L',g(l,P[0:2])))
    elif n=='T': chemins+= [('L',g(l,P[0:2])),('L',g(l,P[2:4]))]
    elif n=='M': chemins.append(('L',g(l,P[0:5])))
    elif n=='N': chemins.append(('L',g(l,P[0:4])))
    elif n=='A': chemins+= [('L',g(l,P[0:3])),('L',g(l,P[3:5]))]
    elif n=='D':
        chemins.append(('L',g(l,P[0:2])))
        chemins.append(('C',g(l,[P[0],P[2],P[3],P[1]])))
f=lambda v:f'{v:.2f}'
# ---------------- SVG ----------------
d=[]
for t,pts in chemins:
    if t=='L': d.append('M'+' L'.join(f'{f(x)} {f(y)}' for x,y in pts))
    else: d.append(f'M{f(pts[0][0])} {f(pts[0][1])} C'+' '.join(f'{f(x)} {f(y)}' for x,y in pts[1:]))
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-R_BORD-1} {-R_BORD-1} {2*R_BORD+2} {2*R_BORD+2}">
<g fill="none" stroke="#000" stroke-linecap="round" stroke-linejoin="round">
<circle r="{R_EXT}" stroke-width="{E_ANN}"/><circle r="{R_INT}" stroke-width="{E_ANN}"/>
<path stroke-width="{W}" d="{' '.join(d)}"/></g>
<g fill="#000">{''.join(f'<circle cx="{x}" cy="{y}" r="{R_PT}"/>' for x,y in POINTS)}</g>
<rect x="{BLEU[0]}" y="{BLEU[1]}" width="{BLEU[2]-BLEU[0]:.2f}" height="{BLEU[3]-BLEU[1]:.2f}" fill="#0505FF"/>
<rect x="{ROUGE[0]}" y="{ROUGE[1]}" width="{ROUGE[2]-ROUGE[0]:.2f}" height="{ROUGE[3]-ROUGE[1]:.2f}" fill="#FF1010"/>
</svg>'''
open('logo_mmd.svg','w').write(svg)
# ---------------- Swift ----------------
lignes=[]
for t,pts in chemins:
    if t=='L':
        lignes.append(f'        p.move(to: q({f(pts[0][0])}, {f(pts[0][1])}))')
        for x,y in pts[1:]: lignes.append(f'        p.addLine(to: q({f(x)}, {f(y)}))')
    else:
        (x0,y0),(x1,y1),(x2,y2),(x3,y3)=pts
        lignes.append(f'        p.move(to: q({f(x0)}, {f(y0)}))')
        lignes.append(f'        p.addCurve(to: q({f(x3)}, {f(y3)}), control1: q({f(x1)}, {f(y1)}), control2: q({f(x2)}, {f(y2)}))')
pts_swift=', '.join(f'CGPoint(x: {x}, y: {y})' for x,y in POINTS)
swift=open('LogoVectoriel.modele.swift').read()
swift=swift.replace('@@LETTRES@@','\n'.join(lignes)).replace('@@POINTS@@',pts_swift)
for k,v in dict(W=W,R_EXT=R_EXT,R_INT=R_INT,E_ANN=E_ANN,R_BORD=R_BORD,R_PT=R_PT).items():
    swift=swift.replace(f'@@{k}@@',str(v))
swift=swift.replace('@@BLEU@@',', '.join(map(str,BLEU))).replace('@@ROUGE@@',', '.join(map(str,ROUGE)))
open('LogoVectoriel.swift','w').write(swift)
# ---------------- PNG haute déf (contrôle + icône) ----------------
def png(taille, chemin, fond=(255,255,255)):
    SS=4; T=taille*SS; k=T/2/(R_BORD+1); o=T/2
    im=np.full((T,T,3),fond,np.uint8)
    P=lambda x,y:(int(round((o+x*k)*16)),int(round((o+y*k)*16)))
    def poly(pts,w):
        a=np.array([P(x,y) for x,y in pts],np.int32)
        cv2.polylines(im,[a],False,(0,0,0),max(1,int(round(w*k))),cv2.LINE_AA,shift=4)
    th=np.linspace(0,2*np.pi,721)
    for r in (R_EXT,R_INT): poly([(r*np.cos(t),r*np.sin(t)) for t in th],E_ANN)
    for t,pts in chemins:
        if t=='L': poly(pts,W)
        else:
            u=np.linspace(0,1,60)[:,None]; p0,p1,p2,p3=pts
            poly(((1-u)**3)*p0+3*((1-u)**2)*u*p1+3*(1-u)*u*u*p2+u**3*p3,W)
    for x,y in POINTS: cv2.circle(im,P(x,y),int(round(R_PT*k*16)),(0,0,0),-1,cv2.LINE_AA,shift=4)
    for (x0,y0,x1,y1),c in ((BLEU,(255,5,5)),(ROUGE,(16,16,255))):
        cv2.rectangle(im,P(x0,y0),P(x1,y1),c,-1,cv2.LINE_AA,shift=4)
    cv2.imwrite(chemin,cv2.resize(im,(taille,taille),interpolation=cv2.INTER_AREA))
png(1024,'logo_mmd_1024.png'); png(400,'logo_mmd_400.png')
print(len(chemins),'sous-chemins')
