# 凛のアイコン（案A「一閃」）を作るスクリプト。resources/icon/ の各ファイルを生成する
#   必要: pip install cairosvg pillow
import cairosvg, io
from PIL import Image
BIG='''<g transform="rotate(42 50 50) translate(0 1)">
<path d="M48.4 33 L48.4 19 C48.4 11 52.6 6.2 59.6 3.4 C56.6 9.8 53.6 17.6 52.6 33 Z" fill="#F7F5F0"/>
<rect x="45.2" y="33" width="9.6" height="2.2" rx="1.1" fill="#F7F5F0"/>
<rect x="48.7" y="35.6" width="2.6" height="55" rx="1.3" fill="#F7F5F0"/>
<rect x="48.4" y="88.6" width="3.2" height="5.4" rx="1.2" fill="#C8452E"/></g>'''
MID='''<g transform="rotate(42 50 50) translate(0 1)"><path d="M48.4 33 L48.4 19 C48.4 11 52.6 6.2 59.6 3.4 C56.6 9.8 53.6 17.6 52.6 33 Z" fill="#F7F5F0"/><rect x="45.2" y="33" width="9.6" height="2.2" rx="1.1" fill="#F7F5F0"/><rect x="48.2" y="35.6" width="3.6" height="55" rx="1.8" fill="#F7F5F0"/><rect x="48" y="88.6" width="4" height="5.4" rx="1.2" fill="#C8452E"/></g>'''
SMALL='''<g transform="rotate(42 50 50) translate(0 1)"><path d="M47.6 33 L47.6 19 C47.6 11 52.6 6 60.6 3 C57 9.8 54 17.6 53.4 33 Z" fill="#F7F5F0"/><rect x="47.4" y="33" width="5.2" height="60" rx="2.6" fill="#F7F5F0"/></g>'''
def app_svg(inner):
    # macOS のアイコン格子: 1024 の中に 824 の角丸本体（余白 100）
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><filter id="s" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.28"/></filter></defs>
<g filter="url(#s)"><rect x="100" y="100" width="824" height="824" rx="185" fill="#1F2A44"/></g>
<g transform="translate(100 100) scale(8.24)">{inner}</g></svg>'''
def render(svg, px):
    png=cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert('RGBA')
imgs={}
for px in (16,32,64,128,256,512,1024):
    inner = SMALL if px<=32 else MID if px<=64 else BIG
    imgs[px]=render(app_svg(inner),px)
    imgs[px].save(f'icon_{px}.png')
imgs[1024].save('AppIcon.icns', append_images=[imgs[p] for p in (16,32,64,128,256,512)])
# メニューバー用テンプレート画像（黒＋透過、18pt）
MENU='''<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100"><g transform="rotate(42 50 50)"><path d="M46 33 L46 19 C46 10 51.6 5 61 2 C57.4 9.8 54.4 17.6 54 33 Z" fill="#000"/><rect x="45.5" y="33" width="9" height="61" rx="4.5" fill="#000"/></g></svg>'''
render(MENU,18).save('MenuIcon.png'); render(MENU,36).save('MenuIcon@2x.png')
# 確認用の一覧
sheet=Image.new('RGBA',(1024+40+512+40+256+40+128+40+64+40+32+40+16+40+36*2, 1064),(236,234,228,255))
x=20
for px in (1024,512,256,128,64,32,16):
    sheet.alpha_composite(imgs[px],(x,20)); x+=px+40
m=Image.open('MenuIcon@2x.png'); bg=Image.new('RGBA',(72,52),(245,245,247,255)); bg.alpha_composite(m,(18,8)); sheet.alpha_composite(bg,(x,20))
sheet.save('preview.png')
