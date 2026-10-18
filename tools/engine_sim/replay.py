# 打鍵ログを新エンジンで再生し、Swift の --replay と同じ書式で出力する
#   python3 replay.py <ログ> <配列.json> [<編集モード.json>]
import sys
from common import *
from new_engine import NewEngine
log, lay = sys.argv[1], sys.argv[2]
singles, combos = load_layout(lay)
ea, ba = load_edit(sys.argv[3]) if len(sys.argv) > 3 else ([], {})
rc = release_combos(combos)
for i, ses in enumerate(parse_log(log)):
    print(f"# session {i}")
    for t, tok in NewEngine(singles, rc, ea, ba).run(ses['events']):
        if tok[0] == 'single': print(f"{t//10**6} S {tok[1]}")
        elif tok[0] == 'chord': print(f"{t//10**6} C {','.join(map(str, sorted(tok[1])))}")
        elif tok[0] == 'edit': print(f"{t//10**6} E {','.join(map(str, sorted(tok[1])))}")
