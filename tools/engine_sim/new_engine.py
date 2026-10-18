# 新判定エンジン（設計案）: 押下順に「先頭キー」を一つずつ確定させる方式
#  - 判定規則は judge() に一本化。確定時刻（タイマー）は同じ規則の境界時刻から導出する
#  - 先頭キーの相手は「その先頭キーと組める（定義がある）キー」だけを探す
#  - 出力は必ず押下順（和音は最初のキーの押下時刻の位置）
from common import SPACE
DEF=dict(THUMB_RATIO=0.60, CHAR_THEN_THUMB_RATIO=0.80, CHAR_RATIO=0.60, CHAR_SHORTER_LO=0.60, CHAR_SHORTER_HI=0.90,
         CHAR_SHORTER_MIN_OV_MS=40, CHAR_SHORTER_NEST_CAP_MS=200, THUMB_OVERLAP_OK_MS=25, ROLLOVER_GUARD_MS=12,
         EDIT_PAIR_MS=60, TIMER_MARGIN_MS=1)
MS=1_000_000
class Key:
    __slots__=('code','down','up','shift','done')
    def __init__(s,c,t): s.code=c; s.down=t; s.up=None; s.shift=False; s.done=False
    # shift: 連続シフトとして保持中（Spaceのみ） / done: 出力済みで解放待ち

class Judge:
    """2キーが同時押しかどうかの規則。True=同時押し / False=別打鍵 / None=まだ決められない"""
    def __init__(s,p): s.p=p
    def th(s,a,b):
        if a.code==SPACE: return s.p['THUMB_RATIO']
        if b.code==SPACE: return s.p['CHAR_THEN_THUMB_RATIO']
        return s.p['CHAR_RATIO']
    @staticmethod
    def ov(a,b,now):
        e1=a.up if a.up is not None else now; e2=b.up if b.up is not None else now
        return max(0, min(e1,e2)-max(a.down,b.down))
    def shorter_ok(s,ovMs,r2,maxDurMs):
        p=s.p
        return ovMs>=p['CHAR_SHORTER_MIN_OV_MS'] and r2>=p['CHAR_SHORTER_LO'] and (r2<p['CHAR_SHORTER_HI'] or maxDurMs<=p['CHAR_SHORTER_NEST_CAP_MS'])
    def judge(s,a,b,now):
        """a: 先に押したキー, b: 後に押したキー"""
        p=s.p; th=s.th(a,b); char=(a.code!=SPACE and b.code!=SPACE)
        ovMs=s.ov(a,b,now)/MS
        # 規則1: Space先行の絶対重なり救済（どちらかが離された後で、重なりが一定以上）
        if a.code==SPACE and p['THUMB_OVERLAP_OK_MS']>0 and (a.up is not None or b.up is not None) and ovMs>=p['THUMB_OVERLAP_OK_MS']:
            return True
        if b.up is not None:
            # 規則2: 後キー基準の重なり割合
            r=ovMs/((b.up-b.down)/MS) if b.up>b.down else 0.0
            if r>=th: return True
            # 規則3: 文字同士の第2判定（短い方基準）
            if char and a.up is not None:
                d1=(a.up-a.down)/MS; d2=(b.up-b.down)/MS
                if s.shorter_ok(ovMs, ovMs/max(1,min(d1,d2)), max(d1,d2)): return True
            return False
        if a.up is None: return None          # 両方押下中
        # a は離され、b は押下中
        if b.code==SPACE:                      # 文字→親指: 文字の押下時間を分母に即決
            d1=(a.up-a.down)/MS
            return (ovMs/d1 if d1>0 else 0.0)>=th
        d1=(a.up-a.down)/MS; d2now=(now-b.down)/MS
        if char:
            if d2now>=d1 and d1>0 and s.shorter_ok(ovMs, ovMs/d1, max(d1,d2now)): return True
            maxr=ovMs/d2now if d2now>0 else 1.0
            r2min=ovMs/d1 if d1>0 else 0
            r2max=ovMs/max(1,min(d1,d2now))
            cap_possible=d1<=p['CHAR_SHORTER_NEST_CAP_MS'] and d2now<=p['CHAR_SHORTER_NEST_CAP_MS']
            r2possible=ovMs>=p['CHAR_SHORTER_MIN_OV_MS'] and r2max>=p['CHAR_SHORTER_LO'] and (r2min<p['CHAR_SHORTER_HI'] or cap_possible)
            if maxr<th and not r2possible: return False
            return None
        maxr=ovMs/d2now if d2now>0 else 1.0
        if maxr<th: return False
        return None
    def boundaries(s,a,b):
        """judge(a,b) の結果が変わりうる時刻（a離鍵済み・b押下中のときのみ意味を持つ）"""
        if a.up is None or b.up is not None: return []
        ov=max(0,a.up-b.down); th=s.th(a,b)
        t=[b.down+int(ov/th)]                               # 割合がしきい値を割る時刻
        if a.code!=SPACE and b.code!=SPACE:
            t.append(b.down+(a.up-a.down))                   # bの押下時間がaに並ぶ時刻（第2判定の分母が確定）
            t.append(b.down+int(s.p['CHAR_SHORTER_NEST_CAP_MS']*MS))  # 短同時押し救済の上限を超える時刻
        return t

class NewEngine:
    def __init__(s, singles, rcombos, edit_actions, base_action, params=None):
        s.p=dict(DEF); s.p.update(params or {}); s.J=Judge(s.p)
        s.rc=rcombos; s.ea=edit_actions
        s.comboKeys={}                  # frozenset -> [(kanaOnly)] 
        for k,tag,ko in rcombos: s.comboKeys.setdefault(k,[]).append(ko)
        s.triples=[k for k in s.comboKeys if len(k)==3]
        s.triplePairs=set()
        for t in s.triples:
            a=sorted(t); s.triplePairs|={frozenset((a[0],a[1])),frozenset((a[0],a[2])),frozenset((a[1],a[2]))}
        s.buf=[]; s.pressed=set(); s.editHeld={}; s.lastDown={}; s.kana=True; s.deadline=None; s.out=[]
    def has_combo(s,keys):
        for ko in s.comboKeys.get(keys,[]):
            if not ko or s.kana: return True
        if not s.kana and len(keys)==2 and SPACE in keys: return True   # 英数時の Space+キー = Shift+キー
        return False
    def emit(s,tok,t): s.out.append((t,tok))
    # ---- 中核: 先頭キーを押下順に確定させる ----
    def resolve(s,now):
        J=s.J
        while True:
            s.buf=[k for k in s.buf if not (k.done and k.up is not None)]
            live=[k for k in s.buf if not k.done]
            if not live: return
            h=live[0]; rest=live[1:]
            # (1) 3キー同時押しの候補（hを含むもの）
            decided=False
            for i in range(len(rest)):
                for j in range(i+1,len(rest)):
                    b,c=rest[i],rest[j]
                    keys=frozenset((h.code,b.code,c.code))
                    if len(keys)<3 or not s.has_combo(keys): continue
                    if h.up is None and b.up is None and c.up is None: return      # 3つとも押下中→待つ
                    def pj(x,y): return True if (x.up is None and y.up is None) else J.judge(x,y,now)
                    v=[pj(h,b),pj(b,c),pj(h,c)]
                    if None in v: return                                         # 未確定→待つ
                    e=[(k.up if k.up is not None else now)-k.down for k in (h,b,c)]
                    sym=max(e)>0 and min(e)/max(e)>=s.p['CHAR_RATIO']
                    held3=all(k.up is None or k.up>c.down for k in (h,b))
                    if (all(v) or (sym and held3)):
                        s.emit(('chord',keys),now); s._consume(h); s._consume(b); s._consume(c)
                        decided=True; break
                if decided: break
            if decided: continue
            # (2) 2キー: hと組めるキーだけを押下順に調べる
            chord=None
            for b in rest:
                pair=frozenset((h.code,b.code))
                if len(pair)<2: continue
                if h.shift and b.shift:
                    continue
                v=J.judge(h,b,now)
                if not s.has_combo(pair):
                    if v is None: return          # 組めないキーでも、hとの関係が未確定なら順序保持のため待つ
                    continue
                if v is None: return
                if not v: continue
                # 誤和音ガード: 両方離鍵済みで重なりが極小、かつ後続キーがある
                if h.up is not None and b.up is not None and J.ov(h,b,now)<s.p['ROLLOVER_GUARD_MS']*MS and any(k is not b for k in rest if k.down>b.down):
                    continue
                # 3キーへ伸びる可能性があれば待つ
                if pair in s.triplePairs and any(J.judge(b,c,now) is None for c in rest if c.down>b.down):
                    return
                chord=b; break
            if chord is not None:
                s.emit(('chord',frozenset((h.code,chord.code))),now); s._consume(h); s._consume(chord)
                continue
            # (3) 組める相手がいない
            if h.up is None and not any(k.up is not None or J.judge(h,k,now) is not None for k in rest):
                return                            # hは押下中で、まだ何も決まっていない→待つ
            if h.up is None and not rest: return
            if h.shift: h.done=True               # 連続シフトのSpaceは黙って退場
            else: s.emit(('single',h.code),now); h.done=True
    def _consume(s,k):
        if k.code==SPACE and k.up is None and SPACE in s.pressed: k.shift=True   # 連続シフト
        else: k.done=True
        if k.done and k.up is not None: pass
    def _schedule(s,now):
        best=None; live=[k for k in s.buf if not k.done]
        for i,a in enumerate(live):
            for b in live[i+1:]:
                for t in s.J.boundaries(a,b):
                    t+=int(s.p['TIMER_MARGIN_MS']*MS)
                    if t>now and (best is None or t<best): best=t
        s.deadline=best
    def fire_timers_until(s,t):
        while s.deadline is not None and s.deadline<=t:
            d=s.deadline; s.deadline=None; s.resolve(d); s._schedule(d)
    def editCompleted(s,code):
        best=None
        for keys,steps in s.ea:
            if code not in keys: continue
            others=keys-{code}
            if not all(o in s.pressed for o in others): continue
            ts=[s.lastDown[o] for o in others if o in s.lastDown]
            if len(ts)>=2 and (max(ts)-min(ts))/MS>s.p['EDIT_PAIR_MS']: continue
            if best is None or len(keys)>len(best[0]): best=(keys,steps)
        return best
    def keyDown(s,code,t):
        s.fire_timers_until(t)
        s.pressed.add(code); s.lastDown[code]=t
        if code!=SPACE:
            e=s.editCompleted(code)
            if e:
                s.emit(('edit',e[0]),t)
                for k in s.buf:
                    if k.code in e[0] and not k.done: k.done=True   # アンカーは出力しない
                return
        s.buf.append(Key(code,t)); s.resolve(t); s._schedule(t)
    def keyUp(s,code,t):
        s.fire_timers_until(t)
        s.pressed.discard(code)
        c=[k for k in s.buf if k.code==code and k.up is None]
        if not c: return
        c[-1].up=t
        s.resolve(t); s._schedule(t)
    def run(s,events):
        for t_ms,kind,val in events:
            t=t_ms*MS
            if kind=='MODE': s.fire_timers_until(t); s.kana=val
            elif kind=='DN': s.keyDown(val,t)
            elif kind=='UP': s.keyUp(val,t)
        s.fire_timers_until(10**30)
        return s.out
