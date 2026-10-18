# 判定エンジンの検証ツール（Python）

凛の判定エンジン（`src/Engine.swift`）と同じロジックを Python で書いたシミュレータと、検証用スクリプトです。Python 3 だけで動きます（追加ライブラリ不要）。

| ファイル | 役割 |
|---|---|
| `new_engine.py` | 凛の判定エンジン（Engine.swift と一行ずつ対応） |
| `common.py` | 打鍵ログ・配列・編集モード定義の読み込み |
| `replay.py` | 打鍵ログを再生し、判定結果を `--replay` と同じ書式で出力する |
| `scenarios.py` | 基本的な打ち方（単打順序・ロールオーバー・センターシフト・連続シフト・3キーなど）の期待出力テスト |
| `audit.py` | ランダム打鍵での監査（出力順の逆転・打鍵の消失・重複の数） |
| `make_fuzz_log.py` | ランダム打鍵を打鍵ログ形式で書き出す（Swift側の再生と突き合わせる用） |

## Swift版とPython版が同じ結果になることの確認

```sh
# 1) Python 側の結果
python3 tools/engine_sim/replay.py <ログ> <配列.json> <編集モード.json> > py.txt
# 2) Swift 側の結果（ビルド済みのアプリで）
./Rin.app/Contents/MacOS/Rin --replay <ログ> --layout <配列.json> --edit <編集モード.json> > swift.txt
# 3) 比較（何も表示されなければ完全一致）
diff py.txt swift.txt
```
