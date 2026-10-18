# 基本シナリオ（期待出力つき）。v17配列とv18配列の両方で判定エンジンを検査する
import json, sys
from common import *
from new_engine import NewEngine
import os
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.join(HERE,'..','..')
LAY17=os.path.join(ROOT,'resources','layouts','naginata_v17.json'); EDIT_AUTHOR=os.path.join(ROOT,'resources','edit_presets','author_example.json')
R,F,J,K,L,I,D,SP,Q,E,V,M,O=15,3,38,40,37,34,2,49,12,14,9,46,31
def seq(*items):
    """('t', key, down, up) の列から DN/UP イベントを作る"""
    ev=[]
    for k,d,u in items: ev+=[(d,'DN',k),(u,'UP',k)]
    return sorted(ev,key=lambda e:(e[0],0 if e[1]=='UP' else 1))
def kana_of(lay):
    d=json.load(open(lay)); s={x['key']:x['kana'] for x in d['singles']}; c={frozenset(x['keys']):x['kana'] for x in d['combos']}
    def f(tok):
        if tok[0]=='single': return s.get(tok[1],{SP:'␣',32:'⌫'}.get(tok[1],f'[{tok[1]}]'))
        if tok[0]=='chord': return c.get(tok[1],'?')
        return '[編]'
    return f
SC=[ # (名前, イベント, v17期待, v18期待)
 ('単打の順序 し→る（重なりなし）', seq((R,0,80),(I,120,200)), 'しる','しる'),
 ('速いロールオーバー し→る（重なり15ms）', seq((R,0,100),(I,85,180)), 'しる','しる'),
 ('同時押し しょ（し＋よ=I）', seq((R,0,120),(I,10,125)), 'しょ','しょ'),
 ('センターシフト Space→F（ま）', seq((SP,0,150),(F,40,120)), 'ま','ま'),
 ('連続シフト Space押しっぱなしで F,J,K', seq((SP,0,400),(F,40,110),(J,150,220),(K,260,330)), 'まのも','まのも'),
 ('文字→親指 F先・Space後 重なり88%（ま）', seq((F,0,120),(SP,15,170)), 'ま','ま'),
 ('文字直後の変換Space（か＋変換）', seq((F,0,90),(SP,80,160)), 'か␣','か␣'),
 ('濁音 J+F（が）', seq((F,0,100),(J,15,110)), 'が','が'),
 ('3キー じょ（し＋よ＋濁J）', seq((R,0,120),(I,10,130),(J,20,125)), 'じょ','じょ'),
 ('とき連打（D, W, D, W）', seq((D,0,60),(13,90,150),(D,180,240),(13,270,330)), 'ときとき','ときとき'),
 ('しまう（R, Space+F, L）', seq((R,0,70),(SP,100,230),(F,130,200),(L,260,330)), 'しまう','しまう'),
 ('v18でのみ: ヴ（う＋濁F＋ー）', seq((L,0,120),(F,10,125),(41,20,130)), None,'ゔ'),
 ('v17でのみ: ヴ（Q単打）', seq((Q,0,80)), 'ヴ',None),
 ('シフト面 W: v17=め / v18=ね', seq((SP,0,150),(13,40,120)), 'め','ね'),
]
lays={'v17':LAY17,'v18':os.path.join(ROOT,'resources','layouts','naginata_v18.json')}
fails=0
for lname,lay in lays.items():
    singles,combos=load_layout(lay); rc=release_combos(combos); f=kana_of(lay)
    for name,ev,e17,e18 in SC:
        exp=e17 if lname=='v17' else e18
        if exp is None: continue
        evm=[(t,k,v) for t,k,v in ev]
        for E in (NewEngine,):
            out=''.join(f(tok) for _,tok in E(singles,rc,[],{}).run(evm))
            ok=out==exp; fails+=not ok
            print(f"[{lname}] {'OK ' if ok else 'NG '} {name}: {out}" + ('' if ok else f'  (期待 {exp})'))
print('不合格',fails)
