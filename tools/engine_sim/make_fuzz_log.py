# ランダム打鍵を打鍵ログ形式で書き出す
#   python3 make_fuzz_log.py <配列.json> <系列数> > fuzz.log
import sys, random
from common import *
def gen(seed, singles, combos, n=400):
    keys = sorted(singles) + [SPACE] * 4
    chords = [sorted(k) for k in combos]
    R = random.Random(seed); t = 1000; ev = []
    for _ in range(n):
        r = R.random()
        if r < 0.55:
            k = R.choice(keys); d = R.randint(40, 160); ev += [(t, 'DN', k), (t + d, 'UP', k)]; t += R.randint(20, 200)
        elif r < 0.9:
            ks = R.choice(chords); base = t
            for i, k in enumerate(ks):
                dn = base + R.randint(0, 60) * (i > 0); up = dn + R.randint(50, 220); ev += [(dn, 'DN', k), (up, 'UP', k)]
            t += R.randint(60, 260)
        else:
            sd = t; n2 = R.randint(2, 3); tt = t + R.randint(5, 60)
            for _ in range(n2):
                k = R.choice(sorted(singles)); d = R.randint(40, 120); ev += [(tt, 'DN', k), (tt + d, 'UP', k)]; tt += R.randint(30, 150)
            ev += [(sd, 'DN', SPACE), (tt + R.randint(-40, 40), 'UP', SPACE)]; t = tt + R.randint(60, 200)
    ev.sort(key=lambda e: (e[0], 0 if e[1] == 'UP' else 1))
    out = []; held = set()
    for e in ev:
        if e[1] == 'DN':
            if e[2] in held: continue
            held.add(e[2]); out.append(e)
        else:
            if e[2] not in held: continue
            held.discard(e[2]); out.append(e)
    return out
if __name__ == '__main__':
    singles, combos = load_layout(sys.argv[1]); N = int(sys.argv[2])
    for s in range(N):
        print(f"[0ms] === ログ記録開始 fuzz seed {s} ===")
        for t, kind, k in gen(s, singles, combos):
            print(f"[{t}ms] {kind} {nm(k)}")
