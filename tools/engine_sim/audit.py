# 監査: ランダム打鍵で、出力順の逆転・打鍵の消失・重複を数える
#   python3 audit.py <系列数> [show]
import sys, collections
from common import *
from new_engine import NewEngine
from make_fuzz_log import gen as _gen
import os
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.join(HERE,'..','..')
LAY17=os.path.join(ROOT,'resources','layouts','naginata_v17.json'); EDIT_AUTHOR=os.path.join(ROOT,'resources','edit_presets','author_example.json')
singles,combos=load_layout(LAY17); rc=release_combos(combos)
def audit(Eng, ev):
    # 押下ごとにIDを振り、出力に使われた押下を追跡する
    out=Eng(singles,rc,[],{}).run(ev)
    presses=[(t,k) for t,kind,k in ev if kind=='DN' and k!=SPACE]
    # 出力キーの消費: 各出力のキーを、まだ使われていない最も古い同キー押下に割り当て
    used=collections.defaultdict(list)
    for t,k in presses: used[k].append(t)
    ptr=collections.defaultdict(int); order=[]; dup=0
    for t,tok in out:
        ks=[tok[1]] if tok[0]=='single' else list(tok[1])
        firsts=[]
        for k in ks:
            if k==SPACE: continue
            i=ptr[k]
            if i>=len(used[k]): dup+=1; continue
            firsts.append(used[k][i]); ptr[k]+=1
        if firsts: order.append(min(firsts))
    lost=sum(len(v)-ptr[k] for k,v in used.items())
    inv=sum(1 for i in range(1,len(order)) if order[i]<order[i-1])
    return inv,lost,dup
R={'new':[0,0,0]}
N=int(sys.argv[1])
for seed in range(N):
    ev=_gen(seed, singles, combos)
    for name,E in (('new',NewEngine),):
        r=audit(E,ev); R[name]=[x+y for x,y in zip(R[name],r)]
print('対象: ランダム打鍵',N,'系列（約',N*400,'操作）')
for name in R: print('判定エンジン', '順序逆転',R[name][0],' 打鍵消失',R[name][1],' 打鍵重複',R[name][2])
if len(sys.argv)>2:
    for seed in range(N):
        ev=_gen(seed, singles, combos)
        out=NewEngine(singles,rc,[],{}).run(ev)
        r=audit(NewEngine,ev)
        if r[0]:
            # 該当箇所を表示
            presses=collections.defaultdict(list)
            for t,kind,k in ev:
                if kind=='DN': presses[k].append(t)
            ptr=collections.defaultdict(int); prev=None
            for t,tok in out:
                ks=[tok[1]] if tok[0]=='single' else list(tok[1])
                f=[]
                for k in ks:
                    if k==SPACE: continue
                    f.append(presses[k][ptr[k]]); ptr[k]+=1
                if f:
                    m=min(f)
                    if prev and m<prev[0]:
                        print('seed',seed,'prev',prev,'then',(m,tok,t//10**6))
                        for e in ev:
                            if prev[0]-200<=e[0]<=t//10**6+20: print('   ',e)
                    prev=(m,tok)
