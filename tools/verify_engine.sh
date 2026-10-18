#!/bin/bash
# Swift版の判定エンジンが Python 版（tools/engine_sim/new_engine.py）と同じ判定をするかを確かめる。
#   使い方: ビルド後に  tools/verify_engine.sh [打鍵ログ...]
#   ランダム打鍵（v17・v18配列）に加え、引数で渡した打鍵ログも再生して比較する。
set -e
cd "$(dirname "$0")/.."
APP_NAME=$(grep -E '^APP_NAME=' build.sh | sed -E 's/APP_NAME="([^"]*)".*/\1/')
BIN="$APP_NAME.app/Contents/MacOS/$APP_NAME"
[ -x "$BIN" ] || { echo "先に ./build.sh でビルドしてください"; exit 1; }
SIM=tools/engine_sim
TMP=$(mktemp -d)
EDIT=resources/edit_presets/author_example.json
ok=0; ng=0
check() {   # $1=ログ $2=配列 $3=名前
    python3 "$SIM/replay.py" "$1" "$2" "$EDIT" > "$TMP/py.txt"
    "$BIN" --replay "$1" --layout "$2" --edit "$EDIT" > "$TMP/sw.txt"
    n=$(grep -cv '^#' "$TMP/py.txt" || true)
    if diff -q "$TMP/py.txt" "$TMP/sw.txt" >/dev/null; then
        echo "一致   $3（判定 $n 件）"; ok=$((ok+1))
    else
        echo "不一致 $3 — 最初の相違:"; diff "$TMP/py.txt" "$TMP/sw.txt" | head -10; ng=$((ng+1))
    fi
}
for v in v17 v18; do
    L=resources/layouts/naginata_$v.json
    python3 "$SIM/make_fuzz_log.py" "$L" 100 > "$TMP/fuzz_$v.log"
    check "$TMP/fuzz_$v.log" "$L" "ランダム打鍵 100系列（${v}配列）"
done
for log in "$@"; do
    check "$log" resources/layouts/naginata_v17.json "打鍵ログ $(basename "$log")（v17 配列）"
done
rm -rf "$TMP"
echo "結果: 一致 $ok / 不一致 $ng"
[ $ng -eq 0 ]
