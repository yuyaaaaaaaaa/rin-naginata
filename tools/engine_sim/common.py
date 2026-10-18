# 共通: ログ読み込み、配列・編集定義の読み込み
import json, re
SPACE=49
KEYNAME={15:"r(し)",3:"f",1:"s",2:"d",0:"a",40:"k(い)",37:"l(う)",49:"SPACE",43:",",47:".",9:"v",46:"m",31:"o(す)",13:"w",14:"e",34:"i(る)"}
NAME2KEY={v:k for k,v in KEYNAME.items()}
def nm2code(s):
    if s in NAME2KEY: return NAME2KEY[s]
    m=re.fullmatch(r'code(\d+)',s); return int(m.group(1))
def nm(c): return KEYNAME.get(c, f"code{c}")

def parse_log(path):
    """returns list of sessions; each: dict(events=[(t_ms,'DN'|'UP'|'MODE',val)], decisions=[(t_ms, token)])"""
    sessions=[]; cur=None
    for line in open(path, encoding='utf-8'):
        m=re.match(r'\[(\d+)ms\] (.*)', line.rstrip('\n'))
        if not m: continue
        t=int(m.group(1)); body=m.group(2)
        if body.startswith('=== ログ記録開始'):
            cur={'events':[], 'decisions':[]}; sessions.append(cur); continue
        if cur is None: continue
        if body.startswith('DN '): cur['events'].append((t,'DN',nm2code(body[3:])))
        elif body.startswith('UP '): cur['events'].append((t,'UP',nm2code(body[3:])))
        elif body.startswith('[mode]'): cur['events'].append((t,'MODE', body.endswith('かな')))
        else:
            b=body.strip()
            tok=None
            mm=re.match(r'同時打鍵 (\S+?)\+(\S+?)( \(|$)', b)
            if mm: tok=('chord',frozenset([nm2code(mm.group(1)),nm2code(mm.group(2))]))
            mm=re.match(r'3キー同時 (\S+)\+(\S+)\+(\S+)$', b)
            if mm: tok=('chord',frozenset(nm2code(mm.group(i)) for i in (1,2,3)))
            mm=re.match(r'単打(?:\(英数\))? (\S+)', b)
            if mm and not b.startswith('単打 ') and not b.startswith('単打(英数) '): mm=None
            if mm: tok=('single',nm2code(mm.group(1)))
            if b.startswith('SPACE単打'): tok=('single',SPACE)
            mm=re.match(r'編集モード (.+)$', b)
            if mm: tok=('edit',frozenset(nm2code(x) for x in mm.group(1).split('+')))
            if b.startswith('長押しリピート'): tok=('repeat',None)
            if tok: cur['decisions'].append((t,tok))
    return sessions

def load_layout(path):
    d=json.load(open(path))
    singles={s['key']:s['romaji'] for s in d['singles']}
    combos={frozenset(c['keys']):c['romaji'] for c in d['combos']}
    return singles, combos

def load_edit(path):
    d=json.load(open(path))
    ea=[(frozenset(e['keys']), e['steps']) for e in d['editActions']]
    ba={int(k):v for k,v in d.get('baseActions',{}).items()}
    return ea, ba

def release_combos(combos):
    """buildTables相当: 配列のコンボ＋固定コンボ（V+M=Enter, Space+V/M, F+G, J+H）"""
    rc=[(k,'kana',True) for k in combos]   # (keys, tag, kanaOnly)
    rc+= [(frozenset([9,46]),'enter',False),(frozenset([49,9]),'comma',True),(frozenset([49,46]),'period',True),
          (frozenset([5,3]),'eisu',False),(frozenset([38,4]),'kana',False)]
    return rc
