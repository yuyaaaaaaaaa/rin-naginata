// naginata_app.swift
// -----------------------------------------------------------------------------
// 薙刀式（v18）入力エミュレータ for macOS — メニューバー常駐アプリ
//
//  薙刀式は大岡俊彦氏が考案したカナ配列です。
//  同時打鍵の判定は Engine.swift（押下順に先頭キーを確定させる方式）で行います。
//  重なり割合による判定と方向別のしきい値は紅皿・桔梗に学んだものです（README「謝辞と出自」参照）。
//
//  ・メニューバーの薙刀アイコン: 有効/無効、設定…、ログ記録、ログイン時自動起動、終了
//  ・設定画面: 同時打鍵しきい値のスライダー調整（UserDefaults保存・初期値リセット）、
//    配列ファイル(.json / .bnz 直接読込)の選択と再読込、編集モード定義(JSON)の再読込
//  ・設定ファイル: ~/Library/Application Support/<アプリ名>/
//    ログ:         ~/Library/Logs/<アプリ名>/
//
//  ビルド: ./build.sh  （名称は build.sh 冒頭の APP_NAME / DISPLAY_NAME で決まる）
// -----------------------------------------------------------------------------

import Cocoa
import CoreGraphics
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

// APP_NAME: 英字表記（ファイル・フォルダ名用）/ DISPLAY_NAME: 正式名称（画面表示用）
let APP_NAME = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Rin"
let DISPLAY_NAME = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? APP_NAME
let APP_VERSION = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
let ENGINE_VERSION = "2.0"

// ==== 調整パラメータ（設定画面から変更可・UserDefaultsに保存） =================
var THUMB_RATIO: Double = 0.60            // 親指が先（Space→文字）の重なり割合
var CHAR_THEN_THUMB_RATIO: Double = 0.80  // 文字が先（文字→Space）の重なり割合
var CHAR_RATIO: Double = 0.60             // 文字同士の重なり割合（後キー基準）
var CHAR_SHORTER_LO: Double = 0.60        // 文字同士の第2判定: 短い方基準の下限
var CHAR_SHORTER_HI: Double = 0.90        //  〃 上限（内包型ロール除外）
var CHAR_SHORTER_MIN_OV_MS: Double = 40   //  〃 最小重なり[ms]
var CHAR_SHORTER_NEST_CAP_MS: Double = 200 //  〃 上限超（完全内包型）でも、両キーの押下がこれ以下なら成立（短い完全同時押しの救済）
var THUMB_OVERLAP_OK_MS: Double = 25      // Space先行の絶対重なり救済[ms]（0で無効）
var ROLLOVER_GUARD_MS: Double = 12        // 誤和音ガード[ms]
var EDIT_PAIR_MS: Double = 60             // 編集モード: アンカー同時押し判定[ms]
let DEN_SHORTER = false

struct Param {
    let key: String; let label: String; let lo: Double; let hi: Double; let def: Double
    let isPercent: Bool
    let get: () -> Double; let set: (Double) -> Void
}
let params: [Param] = [
    Param(key: "thumbRatio",      label: "親指→文字 重なり割合",        lo: 0.30, hi: 0.90, def: 0.60, isPercent: true,  get: { THUMB_RATIO },            set: { THUMB_RATIO = $0 }),
    Param(key: "charThenThumb",   label: "文字→親指 重なり割合",        lo: 0.50, hi: 1.00, def: 0.80, isPercent: true,  get: { CHAR_THEN_THUMB_RATIO },  set: { CHAR_THEN_THUMB_RATIO = $0 }),
    Param(key: "charRatio",       label: "文字同士 重なり割合",          lo: 0.30, hi: 0.90, def: 0.60, isPercent: true,  get: { CHAR_RATIO },             set: { CHAR_RATIO = $0 }),
    Param(key: "charShortLo",     label: "文字同士 第2判定 下限",        lo: 0.30, hi: 0.90, def: 0.60, isPercent: true,  get: { CHAR_SHORTER_LO },        set: { CHAR_SHORTER_LO = $0 }),
    Param(key: "charShortHi",     label: "文字同士 第2判定 上限",        lo: 0.60, hi: 1.00, def: 0.90, isPercent: true,  get: { CHAR_SHORTER_HI },        set: { CHAR_SHORTER_HI = $0 }),
    Param(key: "charShortMinOv",  label: "文字同士 第2判定 最小重なり",   lo: 0,    hi: 100,  def: 40,   isPercent: false, get: { CHAR_SHORTER_MIN_OV_MS }, set: { CHAR_SHORTER_MIN_OV_MS = $0 }),
    Param(key: "charShortNestCap", label: "第2判定 短同時押しの押下上限",  lo: 100,  hi: 400,  def: 200,  isPercent: false, get: { CHAR_SHORTER_NEST_CAP_MS }, set: { CHAR_SHORTER_NEST_CAP_MS = $0 }),
    Param(key: "thumbOvOk",       label: "Space先行の絶対重なり救済",     lo: 0,    hi: 100,  def: 25,   isPercent: false, get: { THUMB_OVERLAP_OK_MS },    set: { THUMB_OVERLAP_OK_MS = $0 }),
    Param(key: "rolloverGuard",   label: "誤和音ガード",                lo: 0,    hi: 40,   def: 12,   isPercent: false, get: { ROLLOVER_GUARD_MS },      set: { ROLLOVER_GUARD_MS = $0 }),
    Param(key: "editPair",        label: "編集モード同時押し判定",        lo: 20,   hi: 150,  def: 60,   isPercent: false, get: { EDIT_PAIR_MS },           set: { EDIT_PAIR_MS = $0 }),
]
func loadPrefs() {
    let ud = UserDefaults.standard
    for p in params where ud.object(forKey: p.key) != nil { p.set(ud.double(forKey: p.key)) }
}

// ==== パス ====================================================================
// 設定類は ~/Library/Application Support/<アプリ名>/ に置く（iCloud同期の対象外）。
// ログは全打鍵を記録するため、同期されない ~/Library/Logs/<アプリ名>/ に置く。
let SUPPORT_DIR: String = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent(APP_NAME).path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()
let LOG_DIR: String = {
    let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("Logs").appendingPathComponent(APP_NAME).path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()
let EDIT_PATH = SUPPORT_DIR + "/edit_mode.json"
let LOG_PATH = LOG_DIR + "/keylog.log"
// 同梱の配列（Contents/Resources/layouts/*.json）。選ぶと設定フォルダへ書き出して使う。
// バージョンごとに別ファイルなので、配列エディタでの変更は切り替えても失われない。
let BUNDLED_LAYOUTS: [(name: String, label: String)] = [
    ("naginata_v18", "薙刀式 v18 トップ版（公式）"),
    ("naginata_v17", "薙刀式 v17 ベスト版"),
]
let DEFAULT_LAYOUT = SUPPORT_DIR + "/naginata_v18.json"
/// 同梱配列を設定フォルダへ書き出し（既にあれば何もしない）、そのパスを返す
@discardableResult
func installBundledLayout(_ name: String) -> String? {
    let dst = SUPPORT_DIR + "/\(name).json"
    if FileManager.default.fileExists(atPath: dst) { return dst }
    guard let src = Bundle.main.path(forResource: name, ofType: "json", inDirectory: "layouts") else { return nil }
    do { try FileManager.default.copyItem(atPath: src, toPath: dst) } catch { return nil }
    return dst
}
func installDefaultLayoutIfNeeded() {
    installBundledLayout("naginata_v18")
}
// 同梱の編集モードプリセット（Contents/Resources/edit_presets/*.json）。公式準拠は内蔵定義から生成する。
let BUNDLED_EDIT_PRESETS: [(name: String?, label: String)] = [
    (nil, "公式準拠（薙刀式v18マニュアル）"),
    ("author_example", "作者の設定例"),
]
var layoutPath: String {
    get { UserDefaults.standard.string(forKey: "layoutPath") ?? DEFAULT_LAYOUT }
    set { UserDefaults.standard.set(newValue, forKey: "layoutPath") }
}

let SYNTH_MAGIC: Int64 = 0x495A_4159  // "IZAY"
let SPACE: Int64 = 49
let RET=36, DELk=51, FDEL=117, ESC=53, LEFT=123, RIGHT=124, DOWN=125, UP=126
let SEMI=41, COLON=39, MINUS=27, SLASH=44, LBR=30, RBR=42, COMMA=43, PERIOD=47
let D1=18, D2=19, D3=20, D7=26, D8=28, D9=25
let CMD: CGEventFlags = .maskCommand
let SFT: CGEventFlags = .maskShift
let OPT: CGEventFlags = .maskAlternate
let CTL: CGEventFlags = .maskControl

struct Step { var flags: CGEventFlags = []; var key: Int = 0; var text: String? = nil; var confirmOnly: Bool = false }
func K(_ key: Int, _ flags: CGEventFlags = []) -> Step { Step(flags: flags, key: key) }
func Kc(_ key: Int, _ flags: CGEventFlags = []) -> Step { Step(flags: flags, key: key, confirmOnly: true) }
func T(_ s: String) -> Step { Step(text: s) }

// ==== 編集モード定義（内蔵デフォルト＝薙刀式v18公式マニュアル準拠） =================
// 初回起動時に edit_mode.json へ書き出し、以後はそのファイルが正本（GUIエディタで自由に変更可）。
// 公式マニュアルの編集モードは Windows のキー操作を前提にしているため、Mac の慣習に置き換えている:
//   Home/End → cmd+←/cmd+→（行頭/行末）、ファイル末尾(Ctrl+End) → cmd+↓、
//   カタカナ/ひらがな変換 → F7/F6、再変換 → かなキー2回（macOS標準の日本語入力の作法）
// 配置は「アンカー2キー（逆手の人差し指＋中指）＋ 3キー目」。
//   D+F + 右手 = タテ移動・選択・操作系 / C+V + 右手 = ヨコ移動・選択・操作系
//   J+K + 左手 = 記号1                 / M+, + 左手 = 記号2・マクロ（脚本/小説マクロは縦書き用）
let F6=97, F7=98, KANA=104
let DF: Set<Int64> = [2,3], JK: Set<Int64> = [38,40], CV: Set<Int64> = [8,9], MC: Set<Int64> = [46,43]
func E(_ anchor: Set<Int64>, _ k: Int64, _ steps: [Step]) -> (keys: Set<Int64>, steps: [Step]) { (anchor.union([k]), steps) }
let RECONVERT: [Step] = [K(KANA), K(KANA)]
let defaultEditActions: [(keys: Set<Int64>, steps: [Step])] = [
    // ---- D+F + 右手: タテ移動、選択、操作系 ----
    E(DF, 16, [K(LEFT, CMD)]),                       // Y: Home（行頭）
    E(DF, 32, [K(40, CTL)]),                         // U: 文末まで消去（ctrl+K）
    E(DF, 34, RECONVERT),                            // I: 再変換
    E(DF, 31, [K(FDEL)]),                            // O: Del
    E(DF, 35, [Kc(ESC), Kc(ESC)]),                   // P: 入力キャンセル
    E(DF, 4,  [Kc(RET), K(RIGHT, CMD)]),             // H: 確定エンド（確定して行末へ）
    E(DF, 38, [K(UP)]),                              // J: ↑
    E(DF, 40, [K(UP, SFT)]),                         // K: shift+↑
    E(DF, 37, Array(repeating: K(UP, SFT), count: 7)),   // L: shift+↑ ×7
    E(DF, 41, [K(F7)]),                              // ;: カタカナ変換
    E(DF, 45, [K(RIGHT, CMD)]),                      // N: End（行末）
    E(DF, 46, [K(DOWN)]),                            // M: ↓
    E(DF, 43, [K(DOWN, SFT)]),                       // ,: shift+↓
    E(DF, 47, Array(repeating: K(DOWN, SFT), count: 7)), // .: shift+↓ ×7
    E(DF, 44, [K(F6)]),                              // /: ひらがな変換
    // ---- C+V + 右手: ヨコ移動、選択、操作系 ----
    E(CV, 16, [K(LEFT, [CMD, SFT])]),                // Y: 行頭まで選択
    E(CV, 32, [K(7, CMD)]),                          // U: カット
    E(CV, 34, RECONVERT),                            // I: 再変換
    E(CV, 31, [K(9, CMD)]),                          // O: ペースト
    E(CV, 35, [K(6, CMD)]),                          // P: アンドゥ
    E(CV, 4,  [K(8, CMD)]),                          // H: コピー
    E(CV, 38, [K(LEFT)]),                            // J: ←
    E(CV, 40, [K(RIGHT)]),                           // K: →
    E(CV, 37, Array(repeating: K(LEFT, SFT), count: 7)),  // L: shift+← ×7
    E(CV, 41, Array(repeating: K(RIGHT, SFT), count: 7)), // ;: shift+→ ×7
    E(CV, 45, [K(RIGHT, [CMD, SFT])]),               // N: 行末まで選択
    E(CV, 46, [K(LEFT, SFT)]),                       // M: shift+←
    E(CV, 43, [K(RIGHT, SFT)]),                      // ,: shift+→
    E(CV, 47, [K(LEFT, CMD), K(RIGHT, [CMD, SFT])]), // .: 一行選択
    E(CV, 44, [K(6, [CMD, SFT])]),                   // /: リドゥ
    // ---- J+K + 左手: 記号1（「・」以外は確定入り）。E は外来音「ディ」と重なるため不使用 ----
    E(JK, 12, [K(DOWN, CMD)]),                       // Q: 最新の位置へ（ファイル末尾）
    E(JK, 13, [T("／")]),                            // W: ／
    E(JK, 15, [K(1, CMD)]),                          // R: 保存
    E(JK, 17, [K(SLASH)]),                           // T: ・（未確定のまま）
    E(JK, 0,  [T("……")]),                            // A: ……
    E(JK, 1,  [T("『")]),                            // S: 『
    E(JK, 2,  [K(SLASH, SFT), Kc(RET)]),             // D: ？
    E(JK, 3,  [K(LBR), Kc(RET)]),                    // F: 「
    E(JK, 5,  [K(D8, SFT), Kc(RET)]),                // G: （
    E(JK, 6,  [T("――")]),                            // Z: ――
    E(JK, 7,  [T("』")]),                            // X: 』
    E(JK, 8,  [K(D1, SFT), Kc(RET)]),                // C: ！
    E(JK, 9,  [K(RBR), Kc(RET)]),                    // V: 」
    E(JK, 11, [K(D9, SFT), Kc(RET)]),                // B: ）
    // ---- M+, + 左手: 記号2、マクロ（脚本マクロ・小説マクロは縦書き用） ----
    E(MC, 12, [T("｜")]),                            // Q: ｜（ルビ開始位置）
    E(MC, 13, [T("　　　×　　　×　　　×")]),          // W: ×××（時間経過記号）
    E(MC, 14, [K(LEFT, CMD), K(RIGHT), K(RIGHT, CMD), K(FDEL), K(FDEL), K(LEFT)]),  // E: セリフ接ぎ
    E(MC, 15, [K(LEFT, CMD), K(RET), T("　"), K(LEFT)]),                            // R: セリフ切り
    E(MC, 17, [T("○")]),                             // T: ○（柱）
    E(MC, 0,  [T("《")]),                            // A: 《
    E(MC, 1,  [T("【")]),                            // S: 【
    E(MC, 2,  [K(LEFT, CMD), K(RIGHT), K(RIGHT, CMD), K(FDEL), K(FDEL), K(FDEL), K(FDEL), K(LEFT)]), // D: ト書き接ぎ
    E(MC, 3,  [K(LEFT, CMD), K(RET), T("　　　"), K(LEFT)]),                        // F: ト書き切り
    E(MC, 5,  [T("　　　")]),                         // G: □□□（空白3）
    E(MC, 6,  [T("》")]),                            // Z: 》
    E(MC, 7,  [T("】")]),                            // X: 】
    E(MC, 8,  [K(RBR), Kc(RET), K(RET)]),            // C: 」確定・改行して次行へ
    E(MC, 9,  [K(RBR), Kc(RET), K(RET), K(LBR), Kc(RET)]),  // V: 」確定・改行して「確定
    E(MC, 11, [K(RBR), Kc(RET), K(RET), T("　")]),   // B: 」確定・改行して空白一文字
]
// 単打の操作キー（v18）: U=BS、T=←、Y=→
let defaultBaseAction: [Int64: [Step]] = [
    32: [K(DELk)], 17: [K(LEFT)], 16: [K(RIGHT)],
]
var editActions: [(keys: Set<Int64>, steps: [Step])] = defaultEditActions
var baseAction: [Int64: [Step]] = defaultBaseAction

// ---- 編集モード定義の JSON シリアライズ ----
let flagNames: [(String, CGEventFlags)] = [("cmd", CMD), ("shift", SFT), ("opt", OPT), ("ctl", CTL)]
func stepToDict(_ s: Step) -> [String: Any] {
    if let t = s.text { return ["text": t] }
    var d: [String: Any] = ["key": s.key]
    let mods = flagNames.filter { s.flags.contains($0.1) }.map { $0.0 }
    if !mods.isEmpty { d["mods"] = mods }
    if s.confirmOnly { d["confirmOnly"] = true }
    return d
}
func dictToStep(_ d: [String: Any]) -> Step? {
    if let t = d["text"] as? String { return T(t) }
    guard let k = d["key"] as? Int else { return nil }
    var f: CGEventFlags = []
    for m in (d["mods"] as? [String]) ?? [] { if let fl = flagNames.first(where: { $0.0 == m }) { f.insert(fl.1) } }
    return Step(flags: f, key: k, text: nil, confirmOnly: (d["confirmOnly"] as? Bool) ?? false)
}
func writeEditFileCurrent() {
    let obj: [String: Any] = [
        "_説明": "編集モード定義。keys=同時押しするキーコード集合。steps=順に実行(text=文字出力 / key+mods=キー操作, confirmOnly=かな入力時のみ)。baseActions=単打の操作キー。設定画面のGUIエディタでも編集可能。初期値は薙刀式v18公式準拠。",
        "editActions": editActions.map { ["keys": $0.keys.sorted(), "steps": $0.steps.map(stepToDict)] },
        "baseActions": Dictionary(uniqueKeysWithValues: baseAction.map { (String($0.key), $0.value.map(stepToDict)) }),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: EDIT_PATH))
    }
}
func writeDefaultEditFile() {
    editActions = defaultEditActions
    baseAction = defaultBaseAction
    writeEditFileCurrent()
}
func loadEditFile(path: String = EDIT_PATH) -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    var ea: [(keys: Set<Int64>, steps: [Step])] = []
    for e in (obj["editActions"] as? [[String: Any]]) ?? [] {
        guard let ks = e["keys"] as? [Int], let ss = e["steps"] as? [[String: Any]] else { continue }
        let steps = ss.compactMap(dictToStep)
        if !ks.isEmpty && !steps.isEmpty { ea.append((Set(ks.map { Int64($0) }), steps)) }
    }
    var ba: [Int64: [Step]] = [:]
    for (k, v) in (obj["baseActions"] as? [String: [[String: Any]]]) ?? [:] {
        if let kk = Int64(k) { ba[kk] = v.compactMap(dictToStep) }
    }
    if ea.isEmpty { return false }
    editActions = ea
    if !ba.isEmpty { baseAction = ba }
    return true
}

let charKeycode: [Character: Int] = [
    "a":0,"b":11,"c":8,"d":2,"e":14,"f":3,"g":5,"h":4,"i":34,"j":38,"k":40,"l":37,"m":46,
    "n":45,"o":31,"p":35,"q":12,"r":15,"s":1,"t":17,"u":32,"v":9,"w":13,"x":7,"y":16,"z":6,"-":27,
]

// ==== 配列データ ===============================================================
var singleRomaji: [Int64: String] = [:]
var eisuPlain: [Int64: String] = [:]
var eisuShift: [Int64: String] = [:]
enum REmit { case romaji(String); case action([Step]) }
struct RCombo { let keys: Set<Int64>; let emit: REmit; let kanaOnly: Bool }
var releaseCombos: [RCombo] = []
var layoutStatus = "未読込"
// 配列エディタ用: かな表示と面メタデータ
var singleKana: [Int64: String] = [:]
var comboKana: [Set<Int64>: String] = [:]
var layoutPlanes: [(mods: [Int64], label: String)] = []
/// 配列の薙刀式バージョン（"v17" / "v18"）。配列エディタでの導出法則（ヴの扱い）がこれで変わる
var layoutVersion = "v18"

func loadLayoutJSON(_ path: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    if let arr = obj["singles"] as? [[String: Any]] {
        for e in arr { if let k = e["key"] as? Int, let r = e["romaji"] as? String {
            singleRomaji[Int64(k)] = r
            singleKana[Int64(k)] = (e["kana"] as? String) ?? r
        } }
    }
    if let arr = obj["combos"] as? [[String: Any]] {
        for e in arr { if let ks = e["keys"] as? [Int], let r = e["romaji"] as? String {
            let set = Set(ks.map { Int64($0) })
            releaseCombos.append(RCombo(keys: set, emit: .romaji(r), kanaOnly: true))
            comboKana[set] = (e["kana"] as? String) ?? r
        } }
    }
    if let arr = obj["planes"] as? [[String: Any]] {
        for e in arr { if let m = e["mods"] as? [Int], let l = e["label"] as? String {
            layoutPlanes.append((m.map { Int64($0) }.sorted(), l)) } }
    }
    layoutVersion = (obj["version"] as? String) ?? "v18"
    if let e = obj["eisu"] as? [String: Any] {
        if let p = e["plain"] as? [String: String] { for (k, v) in p { if let kk = Int64(k) { eisuPlain[kk] = v } } }
        if let s = e["shift"] as? [String: String] { for (k, v) in s { if let kk = Int64(k) { eisuShift[kk] = v } } }
    }
    return !singleRomaji.isEmpty
}

// 現在の配列をJSONへ保存（エディタからの変更を永続化）
func layoutSavePath() -> String {
    return layoutPath.lowercased().hasSuffix(".json") ? layoutPath : SUPPORT_DIR + "/naginata_layout_edited.json"
}
func saveLayoutFile() -> Bool {
    var singles: [[String: Any]] = []
    for (k, kana) in singleKana.sorted(by: { $0.key < $1.key }) {
        if let rom = kana2romaji(kana) { singles.append(["key": Int(k), "romaji": rom, "kana": kana]) }
    }
    var combos: [[String: Any]] = []
    let sortedCombos = comboKana.sorted { a, b in
        let x = a.key.sorted(), y = b.key.sorted()
        if x.count != y.count { return x.count < y.count }
        for (p, q) in zip(x, y) where p != q { return p < q }
        return false
    }
    for (ks, kana) in sortedCombos {
        if let rom = kana2romaji(kana) { combos.append(["keys": ks.sorted().map { Int($0) }, "romaji": rom, "kana": kana]) }
    }
    let planes: [[String: Any]] = layoutPlanes.map { ["mods": $0.mods.map { Int($0) }, "label": $0.label] }
    let eisu: [String: Any] = [
        "plain": Dictionary(uniqueKeysWithValues: eisuPlain.map { (String($0.key), $0.value) }),
        "shift": Dictionary(uniqueKeysWithValues: eisuShift.map { (String($0.key), $0.value) }),
    ]
    let obj: [String: Any] = ["version": layoutVersion, "singles": singles, "combos": combos, "planes": planes, "eisu": eisu]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return false }
    let path = layoutSavePath()
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { return false }
    if !layoutPath.lowercased().hasSuffix(".json") { layoutPath = path }  // bnz→編集後はJSONが正本
    return true
}

// エディタでの変更をエンジンへ反映（かな辞書 → ローマ字テーブル再構築）
func rebuildFromKana() {
    singleRomaji = [:]
    for (k, kana) in singleKana { if let r = kana2romaji(kana) { singleRomaji[k] = r } }
    releaseCombos = []
    for (ks, kana) in comboKana { if let r = kana2romaji(kana) { releaseCombos.append(RCombo(keys: ks, emit: .romaji(r), kanaOnly: true)) } }
    buildTables()
    configureEngine()
}

// ---- BNZ 直接読込（bnz2layout.py と同一ロジック・golden test済） ----
let BNZ_ROWS: [[Int]] = [
    [18,19,20,21,23,22,26,28,25,29,27,24,93,51],
    [12,13,14,15,17,16,32,34,31,35,33,30],
    [0,1,2,3,5,4,38,40,37,41,39,42],
    [6,7,8,9,11,45,46,43,47,44,94],
]
var BNZ_CHARKEY: [Character: Int] = {
    var d = charKeycode; d[";"]=41; d[","]=43; d["."]=47; d["/"]=44; return d
}()
let BNZ_BASE: [Character: String] = {
    var b: [Character: String] = [:]
    for (row, cons) in [("あいうえお",""),("かきくけこ","k"),("がぎぐげご","g"),("さしすせそ","s"),("ざじずぜぞ","z"),
                        ("たちつてと","t"),("だぢづでど","d"),("なにぬねの","n"),("はひふへほ","h"),("ばびぶべぼ","b"),
                        ("ぱぴぷぺぽ","p"),("まみむめも","m"),("らりるれろ","r")] {
        for (k, v) in zip(row, "aiueo") { b[k] = cons + String(v) }
    }
    for (k, v) in [("や","ya"),("ゆ","yu"),("よ","yo"),("わ","wa"),("を","wo"),("ん","nn"),("ヴ","vu"),("ゔ","vu"),("っ","xtu"),("ー","-")] {
        b[Character(k)] = v
    }
    return b
}()
let BNZ_SMALL: [Character: String] = ["ゃ":"xya","ゅ":"xyu","ょ":"xyo","ぁ":"xa","ぃ":"xi","ぅ":"xu","ぇ":"xe","ぉ":"xo","ゎ":"xwa","っ":"xtu"]
func kana2romaji(_ cell: String) -> String? {
    var out = ""
    for (i, ch) in cell.enumerated() {
        if i == 0 {
            if let b = BNZ_BASE[ch] { out += b }
            else if let s = BNZ_SMALL[ch] { out += s }
            else { return nil }
        } else {
            guard let s = BNZ_SMALL[ch] else { return nil }
            out += s
        }
    }
    return out.isEmpty ? nil : out
}
func eisuHalf(_ cellRaw: String, _ kc: Int) -> String? {
    let cell = cellRaw.trimmingCharacters(in: .whitespaces)
    if cell == "無" || cell.isEmpty || cell == "''" || cell == "後" { return nil }
    if cell == "￥" { return kc == 94 ? "\\" : "¥" }
    if let o = ["”":"\"", "’":"'", "‘":"`"][cell] { return o }
    let h = cell.precomposedStringWithCompatibilityMapping
    return h.isEmpty ? nil : h
}
func parseBNZ(_ path: String) -> Bool {
    guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    var sec: [String: Int] = [:]
    for (i, l) in lines.enumerated() {
        if l.hasPrefix("["), let r = l.firstIndex(of: "]") {
            sec[String(l[l.index(after: l.startIndex)..<r])] = i + 1
        }
    }
    func grid(_ start: Int) -> ([[String]], Int) {
        var rows: [[String]] = []; var i = start
        while i < lines.count && rows.count < 4 {
            let t = lines[i]; i += 1
            if t.isEmpty || t.hasPrefix(";") { continue }
            if t.hasPrefix("[") || t.hasPrefix("{") || t.hasPrefix("<") { break }
            rows.append(t.components(separatedBy: ","))
        }
        return (rows, i)
    }
    var addedCount = 0
    func addCells(_ rows: [[String]], _ extra: [Int64]) {
        for (r, keys) in BNZ_ROWS.enumerated() {
            if r >= rows.count { break }
            for (c, kc) in keys.enumerated() {
                if c >= rows[r].count { break }
                let cell = rows[r][c].trimmingCharacters(in: .whitespaces)
                if cell == "無" || cell.isEmpty { continue }
                guard let rom = kana2romaji(cell) else { continue }
                var ks = Set(extra); ks.insert(Int64(kc))
                if ks.count != extra.count + 1 { continue }
                addedCount += 1
                if extra.isEmpty { singleRomaji[Int64(kc)] = rom; singleKana[Int64(kc)] = cell }
                else {
                    releaseCombos.append(RCombo(keys: ks, emit: .romaji(rom), kanaOnly: true))
                    comboKana[ks] = cell
                }
            }
        }
    }
    guard let base = sec["ローマ字シフト無し"] else { return false }
    // [配列] のバージョン行から薙刀式のバージョンを推定（v17以前の表記ならv17扱い、それ以外はv18）
    layoutVersion = "v18"
    if let head = sec["配列"] {
        for l in lines[head..<min(head + 10, lines.count)] where l.hasPrefix("バージョン=") {
            if let r = l.range(of: #"v(\d+)"#, options: .regularExpression), let n = Int(l[r].dropFirst()), n <= 17 { layoutVersion = "v17" }
        }
    }
    let (g0, _) = grid(base); addCells(g0, [])
    if let sp = sec["ローマ字スペースシフト"] { let (g, _) = grid(sp); addCells(g, [SPACE]) }
    // トリガー面（ローマ字シフト無しセクション内）
    let end = (sec["ローマ字スペースシフト"] ?? lines.count + 1) - 1
    var i = base
    var seenPlanes = Set<[Int64]>()
    while i < end && i < lines.count {
        let t = lines[i]
        if t.hasPrefix("{") || t.hasPrefix("<") {
            var trig: [Int64] = []
            var seen = Set<Character>()
            let firstTok = t.components(separatedBy: " ").first ?? t
            var idx = firstTok.startIndex
            while idx < firstTok.endIndex {
                let ch = firstTok[idx]
                if ch == "{" || ch == "<" {
                    let nx = firstTok.index(after: idx)
                    if nx < firstTok.endIndex {
                        let c = firstTok[nx]
                        if c != "*", !seen.contains(c), let kc = BNZ_CHARKEY[c] { seen.insert(c); trig.append(Int64(kc)) }
                    }
                }
                idx = firstTok.index(after: idx)
            }
            // 直後のコメント行を面の名前にする
            var label = String(firstTok.filter { "abcdefghijklmnopqrstuvwxyz;,./".contains($0) })
            if i + 1 < lines.count, lines[i + 1].hasPrefix(";") {
                let l = lines[i + 1].drop(while: { $0 == ";" }).trimmingCharacters(in: .whitespaces)
                if !l.isEmpty { label = l }
            }
            let (g, ni) = grid(i + 1)
            if !trig.isEmpty {
                addedCount = 0
                addCells(g, trig)
                let mods = trig.sorted()
                if addedCount > 0 && !seenPlanes.contains(mods) {
                    seenPlanes.insert(mods)
                    layoutPlanes.append((mods, label))
                }
            }
            i = ni
        } else { i += 1 }
    }
    // 重複除去（後勝ち）
    var seenKeys: [Set<Int64>: Int] = [:]
    var dedup: [RCombo] = []
    for c in releaseCombos {
        if let old = seenKeys[c.keys] { dedup[old] = c } else { seenKeys[c.keys] = dedup.count; dedup.append(c) }
    }
    releaseCombos = dedup
    // 英数面
    for (name, isShift) in [("英数シフト無し", false), ("英数スペースシフト", true)] {
        guard let st = sec[name] else { continue }
        let (g, _) = grid(st)
        for (r, keys) in BNZ_ROWS.enumerated() {
            if r >= g.count { break }
            for (c, kc) in keys.enumerated() {
                if c >= g[r].count { break }
                if let h = eisuHalf(g[r][c], kc) {
                    if isShift { eisuShift[Int64(kc)] = h } else { eisuPlain[Int64(kc)] = h }
                }
            }
        }
    }
    return !singleRomaji.isEmpty
}

// ==== 薙刀式 導出法則（v18マニュアル準拠。旧v17配置では配布bnzの105コンボと完全一致を確認済み） ====
// 基本面＋シフト面の清音配置から、濁音・半濁音・小書き・拗音・外来音を機械導出する。
let NAGINATA_LEFT: Set<Int64> = [12,13,14,15,17, 0,1,2,3,5, 6,7,8,9,11, 18,19,20,21,23]
let SMALL_MOD_KEY: Int64 = 12   // 小書きキー（Q）
let DAKU_MAP: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("かきくけこさしすせそたちつてとはひふへほ", "がぎぐげござじずぜぞだぢづでどばびぶべぼ"))
let HAN_MAP: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("はひふへほ", "ぱぴぷぺぽ"))
let SMALL_MAP: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("やゆよあいうえおわ", "ゃゅょぁぃぅぇぉゎ"))
let YOON_FIRST = "きしちにひみり"
// 外来音: (1文字目, 半濁マーカーか, 2文字目, 出力)
let GAIRAI: [(String, Bool, Character, String)] = [
    ("て",true,"い","てぃ"),("て",false,"い","でぃ"),("て",true,"ゆ","てゅ"),("て",false,"ゆ","でゅ"),
    ("と",true,"う","とぅ"),("と",false,"う","どぅ"),
    ("し",true,"え","しぇ"),("し",false,"え","じぇ"),("ち",true,"え","ちぇ"),("ち",false,"え","ぢぇ"),
    ("う",true,"い","うぃ"),("う",true,"え","うぇ"),("う",true,"お","うぉ"),("い",true,"え","いぇ"),
    ("つ",true,"あ","つぁ"),
    ("ふ",true,"あ","ふぁ"),("ふ",true,"い","ふぃ"),("ふ",true,"え","ふぇ"),("ふ",true,"お","ふぉ"),("ふ",true,"ゆ","ふゅ"),
    ("く",true,"あ","くぁ"),("く",true,"い","くぃ"),("く",true,"え","くぇ"),("く",true,"お","くぉ"),("く",true,"う","くゎ"),
    ("く",false,"あ","ぐぁ"),("く",false,"い","ぐぃ"),("く",false,"え","ぐぇ"),("く",false,"お","ぐぉ"),("く",false,"う","ぐゎ"),
]
// ヴ行の外来音はバージョンで異なる
//  v18: 「う＋濁点＋2文字目」（濁音外来音の法則どおり）、ヴ単独は「う＋濁点＋ー」
//  v17: 「ヴ（Q）＋逆手の半濁点＋2文字目」
let GAIRAI_VU_V18: [(String, Bool, Character, String)] = [
    ("う",false,"あ","ゔぁ"),("う",false,"い","ゔぃ"),("う",false,"え","ゔぇ"),("う",false,"お","ゔぉ"),("う",false,"ゆ","ゔゅ"),
]
let GAIRAI_VU_V17: [(String, Bool, Character, String)] = [
    ("ヴ",true,"あ","ゔぁ"),("ヴ",true,"い","ゔぃ"),("ヴ",true,"え","ゔぇ"),("ヴ",true,"お","ゔぉ"),("ヴ",true,"ゆ","ゔゅ"),
]
let CHOON_KEY: Int64 = 41   // 「ー」のキー（;）。v18の例外「ヴ＝う＋濁点＋ー」で使う
func oppDaku(_ k: Int64) -> Int64 { NAGINATA_LEFT.contains(k) ? 38 : 3 }   // 逆手の濁点(J/F)
func oppHan(_ k: Int64)  -> Int64 { NAGINATA_LEFT.contains(k) ? 46 : 9 }   // 逆手の半濁点(M/V)

// 基本面(singleKana)＋シフト面(comboKana内の{Space,k})から、非Spaceコンボを全再導出
func deriveCombos() {
    var newCombos: [Set<Int64>: String] = [:]
    var keyOf: [Character: Int64] = [:]
    var allKana: [(Int64, String)] = []
    for (k, v) in singleKana { allKana.append((k, v)) }
    for (ks, v) in comboKana where ks.contains(SPACE) && ks.count == 2 {
        newCombos[ks] = v   // シフト面は編集対象なので保持
        if let k = ks.first(where: { $0 != SPACE }) { allKana.append((k, v)) }
    }
    for (k, v) in allKana where v.count == 1 { keyOf[v.first!] = k }
    // 濁音・半濁音・小書き
    for (k, v) in allKana where v.count == 1 {
        let ch = v.first!
        if let d = DAKU_MAP[ch] { newCombos[Set([k, oppDaku(k)])] = String(d) }
        if let h = HAN_MAP[ch] { newCombos[Set([k, oppHan(k)])] = String(h) }
        if let s = SMALL_MAP[ch] { newCombos[Set([k, SMALL_MOD_KEY])] = String(s) }
    }
    // 拗音・濁拗音・半濁拗音
    for ch in YOON_FIRST {
        guard let kc = keyOf[ch] else { continue }
        for y in "やゆよ" {
            guard let ky = keyOf[y], let sy = SMALL_MAP[y] else { continue }
            newCombos[Set([kc, ky])] = String(ch) + String(sy)
            if let d = DAKU_MAP[ch] { newCombos[Set([kc, ky, oppDaku(kc)])] = String(d) + String(sy) }
            if let h = HAN_MAP[ch] { newCombos[Set([kc, ky, oppHan(kc)])] = String(h) + String(sy) }
        }
    }
    // 外来音
    let isV17 = layoutVersion == "v17"
    for (c1, isHan, c2, out) in GAIRAI + (isV17 ? GAIRAI_VU_V17 : GAIRAI_VU_V18) {
        guard let k1 = keyOf[c1.first!], let k2 = keyOf[c2] else { continue }
        let marker = isHan ? oppHan(k1) : oppDaku(k1)
        newCombos[Set([k1, marker, k2])] = out
    }
    // v18の例外: ヴ単独は「う＋濁点＋ー」の3キー
    if !isV17, let ku = keyOf["う"] { newCombos[Set([ku, oppDaku(ku), CHOON_KEY])] = "ゔ" }
    comboKana = newCombos
}

var hasTriples = false
var triplePairs: Set<[Int64]> = []
var monitored: Set<Int64> = []
var eisuOnly: Set<Int64> = []
// ABC(US)配列でも同じ文字になるキーは横取りせず物理イベントを素通しする
// （YouTube等のショートカットは物理キーで判定するため。文字の結果は変わらない）
let usPlainChar: [Int64: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",27:"-",41:";",43:",",47:".",44:"/"]
let usShiftChar: [Int64: String] = {
    var d: [Int64: String] = [18:"!",19:"@",20:"#",21:"$",23:"%",22:"^",26:"&",28:"*",25:"(",29:")",
                              27:"_",24:"+",41:":",39:"\"",42:"|",30:"}",33:"{",43:"<",47:">",44:"?"]
    for (ch, kc) in charKeycode where ch.isLetter { d[Int64(kc)] = String(ch).uppercased() }
    return d
}()
var eisuShiftIntercept: Set<Int64> = []   // 物理Shift時に横取りが必要なキー（JIS≠US）
var eisuPlainIntercept: Set<Int64> = []   // 単打時に横取りが必要な英数専用キー（JIS≠US）
func buildTables() {
    // ; = ー（配列データに定義がなければ補う。文字盤エディタにも表示されるよう、かなの表にも入れる）
    if singleRomaji[41] == nil { singleRomaji[41] = "-" }
    if singleKana[41] == nil && singleRomaji[41] == "-" { singleKana[41] = "ー" }
    releaseCombos.append(RCombo(keys: [9,46],  emit: .action([K(RET)]),            kanaOnly: false))
    releaseCombos.append(RCombo(keys: [49,9],  emit: .action([K(COMMA), Kc(RET)]), kanaOnly: true))
    releaseCombos.append(RCombo(keys: [49,46], emit: .action([K(PERIOD), Kc(RET)]),kanaOnly: true))
    releaseCombos.append(RCombo(keys: [5,3],  emit: .action([K(102)]), kanaOnly: false))  // g+f=英数へ
    releaseCombos.append(RCombo(keys: [38,4], emit: .action([K(104)]), kanaOnly: false))  // j+h=かなへ
    hasTriples = releaseCombos.contains { $0.keys.count == 3 }
    triplePairs = []
    for c in releaseCombos where c.keys.count == 3 {
        let a = c.keys.sorted()
        triplePairs.insert([a[0], a[1]]); triplePairs.insert([a[0], a[2]]); triplePairs.insert([a[1], a[2]])
    }
    monitored = Set(singleRomaji.keys)
    monitored.insert(SPACE)
    for c in releaseCombos { monitored.formUnion(c.keys) }
    for e in editActions { monitored.formUnion(e.keys) }
    for (k, _) in baseAction { monitored.insert(k) }
    eisuOnly = Set(eisuPlain.keys).subtracting(monitored)
    eisuShiftIntercept = Set(eisuShift.keys.filter { usShiftChar[$0] != eisuShift[$0] })
    eisuPlainIntercept = Set(eisuOnly.filter { usPlainChar[$0] != eisuPlain[$0] })
}
func tripleMayExtend(_ x: Int64, _ y: Int64) -> Bool { triplePairs.contains([min(x,y), max(x,y)]) }

// 配列＋編集定義の（再）読込。実行中の状態もリセットする。
func reloadAll() -> Bool {
    singleRomaji = [:]; eisuPlain = [:]; eisuShift = [:]; releaseCombos = []
    singleKana = [:]; comboKana = [:]; layoutPlanes = []
    let ok = layoutPath.lowercased().hasSuffix(".bnz") ? parseBNZ(layoutPath) : loadLayoutJSON(layoutPath)
    if !ok { layoutStatus = "読込失敗: \(layoutPath)"; return false }
    if !loadEditFile() { writeDefaultEditFile(); _ = loadEditFile() }
    buildTables()
    configureEngine()
    let n2 = releaseCombos.filter { $0.keys.count == 2 }.count
    let n3 = releaseCombos.filter { $0.keys.count == 3 }.count
    layoutStatus = "単打\(singleRomaji.count) / 2キー\(n2) / 3キー\(n3) / 英数\(eisuPlain.count)+\(eisuShift.count) / 編集\(editActions.count)"
    return true
}

// ==== IME判定 =================================================================
var kanaMode = true
var eisuIsABC = true   // 英数ソースがABC等の素のキーレイアウト（US解釈）か。かわせみ英字等ならfalse＝JIS強制不要
var lastModeLog = ""
func detectKanaMode() {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
    func prop(_ key: CFString) -> String {
        guard let p = TISGetInputSourceProperty(src, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    let mode = prop(kTISPropertyInputModeID), sid = prop(kTISPropertyInputSourceID)
    let low = (mode + " " + sid).lowercased()
    let ja = low.contains("japanese") || low.contains("kotoeri") || low.contains("atok")
          || low.contains("kawasemi") || low.contains("azookey")
    let alpha = low.contains("roman") || low.contains("alphanumeric") || low.contains("ascii")
          || low.contains("abc") || low.contains("eisu")
    let newMode = ja && !alpha
    if !newMode { eisuIsABC = sid.hasPrefix("com.apple.keylayout") }
    let shown = (mode.isEmpty ? sid : mode)
    if shown != lastModeLog || newMode != kanaMode {
        lastModeLog = shown
        dbg("[mode] \(shown) => \(newMode ? "かな" : "英数\(eisuIsABC ? "(ABC・JIS強制)" : "(JISネイティブ・素通し)")")")
    }
    kanaMode = newMode
}

// ==== 出力 ====================================================================
func postKey(_ keycode: Int, down: Bool, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .privateState)
    let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keycode), keyDown: down)
    e?.flags = flags
    e?.setIntegerValueField(.eventSourceUserData, value: SYNTH_MAGIC)
    e?.post(tap: .cgSessionEventTap)
}
func tapKey(_ keycode: Int, _ flags: CGEventFlags = []) { postKey(keycode, down: true, flags: flags); postKey(keycode, down: false, flags: flags) }
func emitUnicode(_ s: String) {
    let src = CGEventSource(stateID: .privateState)
    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
    let u = Array(s.utf16); e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
    e?.setIntegerValueField(.eventSourceUserData, value: SYNTH_MAGIC); e?.post(tap: .cgSessionEventTap)
}
func emitRomaji(_ r: String) { for ch in r { if let kc = charKeycode[ch] { tapKey(kc) } } }
func emitAction(_ steps: [Step]) {
    for s in steps {
        if !kanaMode && s.confirmOnly { continue }
        if let t = s.text { emitUnicode(t) } else { tapKey(s.key, s.flags) }
    }
}

// ==== ログ ====================================================================
var logEnabled = false
var logFH: FileHandle? = nil
let t0 = DispatchTime.now().uptimeNanoseconds
func ms() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000) }
let keyName: [Int64: String] = [15:"r(し)",3:"f",1:"s",2:"d",0:"a",40:"k(い)",37:"l(う)",49:"SPACE",43:",",47:".",9:"v",46:"m",31:"o(す)",13:"w",14:"e",34:"i(る)"]
func nm(_ c: Int64) -> String { keyName[c] ?? "code\(c)" }
func dbg(_ s: String) {
    guard logEnabled, let fh = logFH else { return }
    fh.write("[\(ms())ms] \(s)\n".data(using: .utf8)!)
}
/// エンジンに渡したのと同じ時刻でログを書く（再生時に同じ判定を再現するため）
func dbgAt(_ t: UInt64, _ s: String) {
    guard logEnabled, let fh = logFH else { return }
    fh.write("[\((t &- t0) / 1_000_000)ms] \(s)\n".data(using: .utf8)!)
}
func setLogging(_ on: Bool) {
    if on {
        if !FileManager.default.fileExists(atPath: LOG_PATH) {
            FileManager.default.createFile(atPath: LOG_PATH, contents: nil)
        }
        logFH = FileHandle(forWritingAtPath: LOG_PATH)
        logFH?.seekToEndOfFile()
        logEnabled = true
        dbg("=== ログ記録開始 \(APP_NAME) \(ENGINE_VERSION) (\(Date())) ===")
    } else {
        dbg("=== ログ記録停止 ===")
        logEnabled = false
        try? logFH?.close(); logFH = nil
    }
}

// ==== エンジンとの接続 ========================================================
// 判定そのものは Engine.swift の ChordEngine が行う。ここでは
//  ・設定（配列の和音・編集モード・しきい値）をエンジンへ渡す
//  ・エンジンの判定結果を、かな（ローマ字列）やキー操作として送出する
//  ・確定タイマーを動かす
// を担当する。
let engine = ChordEngine(space: SPACE)
var editRepeat: [Int64: [Step]] = [:]   // 編集モード・長押しリピート中のキー → 繰り返す操作
var flushToken: UInt64 = 0
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func currentJudgeParams() -> JudgeParams {
    var p = JudgeParams()
    p.thumbRatio = THUMB_RATIO; p.charThenThumbRatio = CHAR_THEN_THUMB_RATIO; p.charRatio = CHAR_RATIO
    p.shorterLo = CHAR_SHORTER_LO; p.shorterHi = CHAR_SHORTER_HI; p.shorterMinOvMs = CHAR_SHORTER_MIN_OV_MS
    p.shorterNestCapMs = CHAR_SHORTER_NEST_CAP_MS; p.thumbOverlapOkMs = THUMB_OVERLAP_OK_MS
    p.rolloverGuardMs = ROLLOVER_GUARD_MS; p.editPairMs = EDIT_PAIR_MS
    return p
}
func syncEngineParams() { engine.params = currentJudgeParams() }
/// 配列・編集モードの読み直し後に呼ぶ
func configureEngine() {
    engine.setCombos(releaseCombos.map { (keys: $0.keys, kanaOnly: $0.kanaOnly) })
    engine.editChords = editActions.map { $0.keys }
    syncEngineParams()
    resetEngine()
}
func resetEngine() {
    engine.reset(); editRepeat.removeAll(); flushToken &+= 1
}

func chordEmitter(_ keys: Set<Int64>) -> (() -> Void)? {
    for c in releaseCombos where c.keys == keys {
        if c.kanaOnly && !kanaMode { continue }
        let e = c.emit
        return { switch e { case .romaji(let r): emitRomaji(r); case .action(let s): emitAction(s) } }
    }
    if !kanaMode && keys.count == 2 && keys.contains(SPACE) {
        if let other = keys.first(where: { $0 != SPACE }) {
            if eisuIsABC, let ch = eisuShift[other] { return { emitUnicode(ch) } }
            let kk = Int(other); return { tapKey(kk, SFT) }   // JISネイティブ時はShift+実キー
        }
    }
    return nil
}
func emitSingle(_ code: Int64) {
    if kanaMode {
        if code == SMALL_MOD_KEY && singleRomaji[code] == nil { dbg("  単打 \(nm(code)) -> 小書きキー単打（無視）"); return }
        if let r = singleRomaji[code] { dbg("  単打 \(nm(code)) -> \(r)"); emitRomaji(r) }
        else if let a = baseAction[code] { dbg("  単打 \(nm(code)) -> action"); emitAction(a) }
        else { dbg("  単打 \(nm(code)) -> 素通し"); tapKey(Int(code)) }
    } else {
        if eisuIsABC, let ch = eisuPlain[code] { dbg("  単打(英数) \(nm(code)) -> \(ch)"); emitUnicode(ch) }
        else { dbg("  単打(英数) \(nm(code))"); tapKey(Int(code)) }   // JISネイティブ時は実キーを送出（ショートカット互換）
    }
}
/// エンジンの判定結果を実際の入力に変換する
func dispatch(_ decisions: [Decision], trigger: Int64? = nil) {
    for d in decisions {
        switch d {
        case .single(let c):
            if c == SPACE { dbg("  SPACE単打 -> 空白(=変換)"); tapKey(Int(SPACE)) } else { emitSingle(c) }
        case .chord(let keys):
            let names = keys.sorted().map(nm).joined(separator: "+")
            dbg(keys.count == 3 ? "  3キー同時 \(names)" : "  同時打鍵 \(names)")
            chordEmitter(keys)?()
        case .edit(let i):
            guard i < editActions.count else { continue }
            dbg("  編集モード \(editActions[i].keys.sorted().map(nm).joined(separator: "+"))")
            emitAction(editActions[i].steps)
            if let t = trigger { editRepeat[t] = editActions[i].steps }
        }
    }
}
/// エンジンが求める時刻に確定タイマーを仕掛ける（古いタイマーは token で無効化）
func armTimer() {
    flushToken &+= 1
    guard let deadline = engine.nextDeadline else { return }
    let token = flushToken
    let now = nowNs()
    let delay = deadline > now ? Double(deadline - now) / 1_000_000_000.0 : 0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard token == flushToken else { return }
        detectKanaMode(); engine.kanaMode = kanaMode
        dispatch(engine.timerFired(at: max(nowNs(), deadline)))
        armTimer()
    }
}
func onKeyDown(_ code: Int64, isRepeat: Bool) {
    if isRepeat {
        if let s = editRepeat[code] { emitAction(s); return }
        // 操作キー（BSなど）の長押しリピート
        if kanaMode, let a = baseAction[code], engine.takeLoneHeld(code) {
            dbg("  長押しリピート \(nm(code))")
            emitAction(a); editRepeat[code] = a
        }
        return
    }
    detectKanaMode(); engine.kanaMode = kanaMode
    let t = nowNs()
    dbgAt(t, "DN \(nm(code))")
    dispatch(engine.keyDown(code, at: t), trigger: code)
    armTimer()
}
func onKeyUp(_ code: Int64) {
    let t = nowNs()
    dbgAt(t, "UP \(nm(code))")
    if editRepeat[code] != nil { editRepeat[code] = nil }
    dispatch(engine.keyUp(code, at: t))
    armTimer()
}

// ---- 打鍵ログの再生（ターミナルから: Rin.app/Contents/MacOS/Rin --replay <ログ> [--layout <配列.json>] [--edit <編集.json>]）----
func runReplayCLI(_ args: [String]) {
    guard let logPath = args.first, let text = try? String(contentsOfFile: logPath, encoding: .utf8) else {
        print("使い方: --replay <ログファイル> [--layout <配列.json|.bnz>] [--edit <編集モード.json>]"); return
    }
    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let lay = opt("--layout") ?? DEFAULT_LAYOUT
    singleRomaji = [:]; eisuPlain = [:]; eisuShift = [:]; releaseCombos = []
    singleKana = [:]; comboKana = [:]; layoutPlanes = []
    let ok = lay.lowercased().hasSuffix(".bnz") ? parseBNZ(lay) : loadLayoutJSON(lay)
    if !ok { print("配列を読み込めません: \(lay)"); return }
    if !loadEditFile(path: opt("--edit") ?? EDIT_PATH) { editActions = defaultEditActions; baseAction = defaultBaseAction }
    buildTables()
    engine.setCombos(releaseCombos.map { (keys: $0.keys, kanaOnly: $0.kanaOnly) })
    engine.editChords = editActions.map { $0.keys }
    engine.params = JudgeParams()      // 再生は常に初期値のしきい値で行う（比較のため）
    let nameToCode: [String: Int64] = Dictionary(uniqueKeysWithValues: keyName.map { ($0.value, $0.key) })
    let sessions = parseReplayLog(text) { s in
        if let c = nameToCode[s] { return c }
        if s.hasPrefix("code"), let n = Int64(s.dropFirst(4)) { return n }
        return nil
    }
    for (i, ev) in sessions.enumerated() {
        print("# session \(i)")
        for l in replay(engine, ev) { print(l) }
    }
}

// ==== タップ ==================================================================
var gTap: CFMachPort? = nil
var engineEnabled = true
var keyCapture: ((Int64) -> Void)? = nil   // 編集モードエディタのキー記録用
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gTap, engineEnabled { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == SYNTH_MAGIC { return Unmanaged.passUnretained(event) }
    if let cap = keyCapture {
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let c = event.getIntegerValueField(.keyboardEventKeycode)
            DispatchQueue.main.async { cap(c) }
        }
        return nil   // 記録中は全キーを飲み込む
    }
    let f = event.flags
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let shiftOnly = f.contains(.maskShift) && !f.contains(.maskCommand) && !f.contains(.maskControl) && !f.contains(.maskAlternate)
    if shiftOnly && (type == .keyDown || type == .keyUp) && eisuShiftIntercept.contains(code) {
        detectKanaMode()
        if !kanaMode, eisuIsABC, let ch = eisuShift[code] {
            if type == .keyDown { dbg("  英数(Shift) \(nm(code)) -> \(ch)"); emitUnicode(ch) }
            return nil
        }
    }
    if f.contains(.maskCommand) || f.contains(.maskControl) || f.contains(.maskAlternate) || f.contains(.maskShift) {
        return Unmanaged.passUnretained(event)
    }
    if !monitored.contains(code) {
        if eisuOnly.contains(code), type == .keyDown || type == .keyUp {
            detectKanaMode()
            if !kanaMode {
                if engine.isPressed(SPACE) {
                    if type == .keyDown, let ch = eisuShift[code] {
                        engine.markSpaceAsShift()
                        dbg("  英数(Space) \(nm(code)) -> \(ch)"); emitUnicode(ch)
                    }
                    return nil
                }
                // US配列と同じ文字になるキー、またはJISネイティブな英数ソースなら素通し
                if !eisuPlainIntercept.contains(code) || !eisuIsABC { return Unmanaged.passUnretained(event) }
                if type == .keyDown, let ch = eisuPlain[code] {
                    dbg("  英数 \(nm(code)) -> \(ch)"); emitUnicode(ch)
                }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown { onKeyDown(code, isRepeat: isRepeat); return nil }
    if type == .keyUp { onKeyUp(code); return nil }
    return Unmanaged.passUnretained(event)
}

func startTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
        return false
    }
    gTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// ==== 配列エディタ =============================================================
let keyDisplay: [Int64: String] = {
    var d: [Int64: String] = [:]
    for (ch, kc) in charKeycode { d[Int64(kc)] = String(ch) }
    let extras: [(Int, String)] = [(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),(29,"0"),
                                   (27,"-"),(24,"^"),(93,"¥"),(33,"@"),(30,"["),(39,":"),(42,"]"),(94,"_"),
                                   (41,";"),(43,","),(47,"."),(44,"/"),(49,"Space"),(51,"⌫")]
    for (kc, s) in extras { d[Int64(kc)] = s }
    return d
}()

// ==== 文字盤エディタ（格子配列） ================================================
// かな配列と編集モードを、格子状のキーボード図の上で表示・編集する。
// 左手 3段×5列、右手 3段×6列（P・;・/ の外側の @・:・_ まで。編集モードで使うことがあるため）
let GRID_ROWS: [[Int64]] = [
    [12, 13, 14, 15, 17,   16, 32, 34, 31, 35, 33],   // Q W E R T | Y U I O P @
    [0, 1, 2, 3, 5,        4, 38, 40, 37, 41, 39],    // A S D F G | H J K L ; :
    [6, 7, 8, 9, 11,       45, 46, 43, 47, 44, 94],   // Z X C V B | N M , . / _
]
let GRID_LEFT: Set<Int64> = Set(GRID_ROWS.flatMap { Array($0.prefix(5)) })
let GRID_RIGHT: Set<Int64> = Set(GRID_ROWS.flatMap { Array($0.dropFirst(5)) })
func keyCap(_ c: Int64) -> String { (keyDisplay[c] ?? "key\(c)").uppercased() }

final class KeyGridView: NSView {
    enum Style { case normal, anchor, dim, empty }
    struct Cell { var label: String; var style: Style }
    var cells: [Int64: Cell] = [:]
    var onClick: ((Int64) -> Void)?
    let keyW: CGFloat = 64, keyH: CGFloat = 58, gap: CGFloat = 6, handGap: CGFloat = 30, pad: CGFloat = 10

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: pad * 2 + keyW * 11 + gap * 9 + handGap, height: pad * 2 + keyH * 4 + gap * 3)
    }
    func keyRect(row: Int, col: Int) -> NSRect {
        var x = pad + CGFloat(col) * (keyW + gap)
        if col >= 5 { x += handGap - gap }
        return NSRect(x: x, y: pad + CGFloat(row) * (keyH + gap), width: keyW, height: keyH)
    }
    func spaceRect() -> NSRect {
        let l = keyRect(row: 3, col: 3), r = keyRect(row: 3, col: 6)
        return NSRect(x: l.minX, y: l.minY, width: r.maxX - l.minX, height: keyH)
    }
    override func draw(_ dirtyRect: NSRect) {
        for (r, row) in GRID_ROWS.enumerated() {
            for (c, code) in row.enumerated() { drawKey(keyRect(row: r, col: c), code) }
        }
        drawKey(spaceRect(), SPACE)
    }
    private func drawKey(_ rect: NSRect, _ code: Int64) {
        let cell = cells[code] ?? Cell(label: "", style: .empty)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let fill: NSColor, text: NSColor
        switch cell.style {
        case .anchor: fill = NSColor.systemGreen.withAlphaComponent(0.85); text = .white
        case .normal: fill = NSColor.textBackgroundColor; text = .labelColor
        case .dim: fill = NSColor.textBackgroundColor.withAlphaComponent(0.55); text = .tertiaryLabelColor
        case .empty: fill = NSColor.windowBackgroundColor; text = .tertiaryLabelColor
        }
        fill.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        // キー名（左上）
        let capAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: cell.style == .anchor ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor]
        ((code == SPACE ? "Space" : keyCap(code)) as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 3), withAttributes: capAttr)
        // 中身（中央）
        let n = cell.label.count
        let size: CGFloat = n <= 1 ? 22 : n <= 2 ? 18 : n <= 4 ? 13 : 10
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: text, .paragraphStyle: para]
        let s = NSAttributedString(string: cell.label, attributes: attr)
        let inner = rect.insetBy(dx: 4, dy: 12)
        let h = s.boundingRect(with: inner.size, options: [.usesLineFragmentOrigin], context: nil).height
        s.draw(with: NSRect(x: inner.minX, y: inner.midY - h / 2 + 4, width: inner.width, height: h + 2),
               options: [.usesLineFragmentOrigin], context: nil)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, row) in GRID_ROWS.enumerated() {
            for (c, code) in row.enumerated() where keyRect(row: r, col: c).contains(p) { onClick?(code); return }
        }
        if spaceRect().contains(p) { onClick?(SPACE) }
    }
}

// 編集モードで選べる機能の一覧（メニュー表示名, キー図での短い表示, 記法）
let EDIT_CATALOG: [(menu: String, short: String, dsl: String)] = [
    ("← 左", "←", "左"), ("→ 右", "→", "右"), ("↑ 上", "↑", "上"), ("↓ 下", "↓", "下"),
    ("行頭（Home）", "Home", "cmd+左"), ("行末（End）", "End", "cmd+右"),
    ("文書の先頭", "先頭", "cmd+上"), ("最新の位置へ（文書の末尾）", "新", "cmd+下"),
    ("⇧← 選択", "⇧←", "shift+左"), ("⇧→ 選択", "⇧→", "shift+右"), ("⇧↑ 選択", "⇧↑", "shift+上"), ("⇧↓ 選択", "⇧↓", "shift+下"),
    ("⇧←×7 選択", "⇧←7", "shift+左*7"), ("⇧→×7 選択", "⇧→7", "shift+右*7"),
    ("⇧↑×7 選択", "⇧↑7", "shift+上*7"), ("⇧↓×7 選択", "⇧↓7", "shift+下*7"),
    ("行頭まで選択", "⇧Home", "cmd+shift+左"), ("行末まで選択", "⇧End", "cmd+shift+右"),
    ("一行選択", "一行選択", "cmd+左 cmd+shift+右"), ("すべて選択", "全選択", "cmd+a"),
    ("BS（1文字削除）", "BS", "BS"), ("Del（後ろを1文字削除）", "Del", "Del"), ("文末まで消去", "文末消去", "ctrl+k"),
    ("Enter", "⏎", "Enter"), ("確定して行末へ", "確定End", "Enter? cmd+右"), ("入力キャンセル", "入力取消", "Esc?*2"),
    ("再変換（かなキー2回）", "再", "かな*2"), ("再変換（ctrl+shift+R）", "再", "ctrl+shift+r"),
    ("カタカナ変換（F7）", "カナ", "key98"), ("ひらがな変換（F6）", "ひら", "key97"),
    ("コピー", "Copy", "cmd+c"), ("カット", "Cut", "cmd+x"), ("ペースト", "Paste", "cmd+v"),
    ("取り消し", "Undo", "cmd+z"), ("やり直し", "Redo", "cmd+shift+z"), ("保存", "保", "cmd+s"),
    ("英数入力へ", "英数", "英数"), ("かな入力へ", "かな", "かな"),
    ("「（確定）", "「", "[ Enter?"), ("」（確定）", "」", "] Enter?"),
    ("？（確定）", "？", "shift+/ Enter?"), ("！（確定）", "！", "shift+1 Enter?"),
    ("（（確定）", "（", "shift+8 Enter?"), ("）（確定）", "）", "shift+9 Enter?"), ("・（未確定）", "・", "/"),
    ("……", "……", "「……」"), ("――", "――", "「――」"), ("『", "『", "「『」"), ("』", "』", "「』」"),
    ("／", "／", "「／」"), ("｜（ルビ開始）", "｜", "「｜」"), ("《", "《", "「《」"), ("》", "》", "「》」"),
    ("【", "【", "「【」"), ("】", "】", "「】」"), ("○（柱）", "○", "「○」"),
    ("×××（時間経過）", "×××", "「　　　×　　　×　　　×」"), ("空白3", "□□□", "「　　　」"),
    ("セリフ接ぎ", "セリフ接", "cmd+左 右 cmd+右 Del*2 左"), ("セリフ切り", "セリフ切", "cmd+左 Enter 「　」 左"),
    ("ト書き接ぎ", "ト書接", "cmd+左 右 cmd+右 Del*4 左"), ("ト書き切り", "ト書切", "cmd+左 Enter 「　　　」 左"),
    ("」確定・改行", "」次行", "] Enter? Enter"), ("」確定・改行して「", "」⏎「", "] Enter? Enter [ Enter?"),
    ("」確定・改行して空白", "」⏎□", "] Enter? Enter 「　」"),
]
/// 記法を正規化（同じ操作が同じ文字列になるように）
func normalizeDSL(_ dsl: String) -> String? { dslToSteps(dsl).map(stepsToDSL) }
// 注意: main.swift の大域変数は上から順に初期化されるため、後方で定義している記法の変換表
// （dslNameCode など）を使うこの対応表は、起動時ではなく最初に使うときに作る。
var editCatalogNormCache: [String: (menu: String, short: String)]? = nil
func editCatalogNorm() -> [String: (menu: String, short: String)] {
    if let c = editCatalogNormCache { return c }
    var d: [String: (menu: String, short: String)] = [:]
    for c in EDIT_CATALOG { if let n = normalizeDSL(c.dsl), d[n] == nil { d[n] = (c.menu, c.short) } }
    editCatalogNormCache = d
    return d
}
/// 操作の短い表示名（キー図用）
func shortLabel(_ steps: [Step]) -> String {
    let dsl = stepsToDSL(steps)
    if let c = editCatalogNorm()[dsl] { return c.short }
    if steps.count == 1, let t = steps[0].text { return t }
    return dsl.count <= 8 ? dsl : String(dsl.prefix(7)) + "…"
}

/// 編集モード定義を保存してエンジンへ反映
func persistEditDefinitions() {
    writeEditFileCurrent()
    buildTables()
    configureEngine()
}

final class KeyboardEditorWindowController: NSWindowController {
    let modeControl = NSSegmentedControl(labels: ["かな配列", "編集モード"], trackingMode: .selectOne, target: nil, action: nil)
    let popup = NSPopUpButton()
    let grid = KeyGridView()
    let infoLabel = NSTextField(wrappingLabelWithString: "")
    let editButtons = NSStackView()
    var kanaPlanes: [(label: String, mods: [Int64])] = []
    /// 編集モードの面（アンカーのキー集合。空集合は単打の操作キー）
    var faces: [Set<Int64>] = []
    var extraFaces: [Set<Int64>] = []   // まだ定義のない、新しく作った面
    var listEditor: EditModeEditorWindowController?

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "\(DISPLAY_NAME) 文字盤エディタ"
        self.init(window: win)
        buildUI()
    }
    var isEditMode: Bool { modeControl.selectedSegment == 1 }

    func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        let head = NSStackView(); head.orientation = .horizontal; head.spacing = 12
        popup.target = self; popup.action = #selector(popupChanged)
        head.addArrangedSubview(modeControl); head.addArrangedSubview(popup)
        stack.addArrangedSubview(head)
        grid.onClick = { [weak self] code in self?.keyClicked(code) }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let size = grid.intrinsicContentSize
        grid.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        grid.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        stack.addArrangedSubview(grid)
        infoLabel.font = NSFont.systemFont(ofSize: 11); infoLabel.textColor = .secondaryLabelColor
        infoLabel.preferredMaxLayoutWidth = size.width
        stack.addArrangedSubview(infoLabel)
        editButtons.orientation = .horizontal; editButtons.spacing = 8
        editButtons.addArrangedSubview(NSButton(title: "新しい面を作る…", target: self, action: #selector(newFace)))
        editButtons.addArrangedSubview(NSButton(title: "一覧で編集…", target: self, action: #selector(openList)))
        stack.addArrangedSubview(editButtons)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(stack.fittingSize)
        window?.center()
    }
    func show(editMode: Bool) {
        modeControl.selectedSegment = editMode ? 1 : 0
        refreshAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func modeChanged() { refreshAll() }
    @objc func popupChanged() { refreshGrid() }

    func refreshAll() {
        editButtons.isHidden = !isEditMode
        let sel = popup.indexOfSelectedItem
        popup.removeAllItems()
        if isEditMode {
            faces = computeFaces()
            popup.addItems(withTitles: faces.map(faceTitle))
        } else {
            kanaPlanes = [("基本面（単打）", []), ("シフト面（Space＋キー）", [SPACE])]
            for p in layoutPlanes { kanaPlanes.append(("\(p.mods.map(keyCap).joined(separator: "＋")) 同時押し — \(p.label)（自動導出）", p.mods)) }
            popup.addItems(withTitles: kanaPlanes.map { $0.label })
        }
        popup.selectItem(at: (sel >= 0 && sel < popup.numberOfItems) ? sel : 0)
        refreshGrid()
    }

    // ---- 編集モードの面 ----
    /// 3キーの定義から「アンカー2キー」を推定し、面の一覧を作る（出現の多い2キー組をアンカーとみなす）
    func computeFaces() -> [Set<Int64>] {
        var count: [Set<Int64>: Int] = [:]
        for e in editActions where e.keys.count == 3 {
            let k = e.keys.sorted()
            for p in [[k[0], k[1]], [k[0], k[2]], [k[1], k[2]]] { count[Set(p), default: 0] += 1 }
        }
        var result: [Set<Int64>] = [[]]
        for e in editActions where e.keys.count == 3 {
            if let a = anchor(of: e.keys, count), !result.contains(a) { result.append(a) }
        }
        for f in extraFaces where !result.contains(f) { result.append(f) }
        return result
    }
    func anchor(of keys: Set<Int64>, _ count: [Set<Int64>: Int]) -> Set<Int64>? {
        let k = keys.sorted()
        let pairs: [Set<Int64>] = [[k[0], k[1]], [k[0], k[2]], [k[1], k[2]]]
        return pairs.max { (count[$0] ?? 0, -($0.sorted().first ?? 0)) < (count[$1] ?? 0, -($1.sorted().first ?? 0)) }
    }
    func faceTitle(_ f: Set<Int64>) -> String {
        if f.isEmpty { return "単打の操作キー" }
        let hand = f.isSubset(of: GRID_LEFT) ? "（右手で選ぶ）" : f.isSubset(of: GRID_RIGHT) ? "（左手で選ぶ）" : ""
        return "\(f.sorted().map(keyCap).joined(separator: "＋")) を押しながら\(hand)"
    }
    var currentFace: Set<Int64> {
        let i = popup.indexOfSelectedItem
        return (i >= 0 && i < faces.count) ? faces[i] : []
    }
    var currentPlaneMods: [Int64] {
        let i = popup.indexOfSelectedItem
        return (i >= 0 && i < kanaPlanes.count) ? kanaPlanes[i].mods : []
    }

    func refreshGrid() {
        var cells: [Int64: KeyGridView.Cell] = [:]
        let all = GRID_ROWS.flatMap { $0 }
        if isEditMode {
            let f = currentFace
            if f.isEmpty {
                for c in all {
                    if let a = baseAction[c] { cells[c] = .init(label: shortLabel(a), style: .normal) }
                    else if let k = singleKana[c] { cells[c] = .init(label: k, style: .dim) }
                }
                infoLabel.stringValue = "単独で押したときの操作です（かなが割り当てられていないキーだけに効きます。薄い文字はかな）。キーをクリックすると機能を選べます。"
            } else {
                for c in all {
                    if f.contains(c) { cells[c] = .init(label: "", style: .anchor); continue }
                    if let e = editActions.first(where: { $0.keys == f.union([c]) }) { cells[c] = .init(label: shortLabel(e.steps), style: .normal) }
                }
                infoLabel.stringValue = "緑のキーを押しながら、ほかのキーを押したときの操作です。キーをクリックすると機能を選べます。編集モードは自分の書き方に合わせて自由に変えてかまいません。"
            }
            cells[SPACE] = .init(label: "", style: .empty)
        } else {
            let mods = currentPlaneMods
            for c in all {
                if mods.contains(c) { cells[c] = .init(label: singleKana[c] ?? "", style: .anchor); continue }
                let k = mods.isEmpty ? singleKana[c] : comboKana[Set(mods + [c])]
                if let k = k { cells[c] = .init(label: k, style: popup.indexOfSelectedItem <= 1 ? .normal : .dim) }
            }
            cells[SPACE] = .init(label: mods == [SPACE] ? "シフト" : "", style: mods == [SPACE] ? .anchor : .empty)
            infoLabel.stringValue = popup.indexOfSelectedItem <= 1
                ? "キーをクリックすると、割り当てるかなを変えられます。濁音・拗音などの面は、ここでの清音配置から自動で導出されます。"
                : "この面は、基本面とシフト面の清音配置から「すべて同置」の法則で自動導出されます（\(layoutVersion)の法則）。"
        }
        grid.cells = cells
        grid.needsDisplay = true
    }

    func keyClicked(_ code: Int64) {
        if code == SPACE { return }
        if isEditMode { editActionDialog(code) } else { kanaDialog(code) }
    }

    // ---- かな配列の編集 ----
    func kanaDialog(_ code: Int64) {
        let mods = currentPlaneMods
        guard popup.indexOfSelectedItem <= 1 else {
            let a = NSAlert(); a.messageText = "この面は自動導出です"
            a.informativeText = "濁音・半濁音・小書き・拗音・外来音は、基本面とシフト面の清音配置から自動的に決まります。変えたい場合は、基本面またはシフト面で清音の位置を変えてください。"
            a.runModal(); return
        }
        if mods.contains(code) { return }
        let current = mods.isEmpty ? singleKana[code] : comboKana[Set(mods + [code])]
        let a = NSAlert()
        a.messageText = "\(keyCap(code)) キー（\(popup.titleOfSelectedItem ?? "")）"
        a.informativeText = "割り当てるかなを入力してください（例: か・て・ヴ）。空欄にすると割り当てを解除します。保存すると、濁音・拗音などの面が自動で導出し直されます。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = current ?? ""
        a.accessoryView = tf
        a.addButton(withTitle: "保存"); a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let kana = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if kana.isEmpty {
            if mods.isEmpty { singleKana.removeValue(forKey: code) } else { comboKana.removeValue(forKey: Set(mods + [code])) }
        } else {
            guard kana2romaji(kana) != nil else {
                let e = NSAlert(); e.messageText = DISPLAY_NAME
                e.informativeText = "「\(kana)」はローマ字に変換できません。ひらがな（＋小書き）で入力してください。"
                e.runModal(); return
            }
            if mods.isEmpty { singleKana[code] = kana } else { comboKana[Set(mods + [code])] = kana }
        }
        deriveCombos()
        rebuildFromKana()
        infoLabel.stringValue = saveLayoutFile() ? "保存しました → \(layoutSavePath())" : "保存に失敗しました（\(layoutSavePath())）"
        refreshGrid()
    }

    // ---- 編集モードの編集 ----
    func editActionDialog(_ code: Int64) {
        let f = currentFace
        if f.contains(code) { return }
        let keys = f.union([code])
        let existing: [Step]? = f.isEmpty ? baseAction[code] : editActions.first(where: { $0.keys == keys })?.steps
        if f.isEmpty && singleKana[code] != nil {
            let a = NSAlert(); a.messageText = DISPLAY_NAME
            a.informativeText = "\(keyCap(code)) キーにはかな（\(singleKana[code]!)）が割り当てられているので、単打の操作は設定できません。"
            a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = f.isEmpty ? "\(keyCap(code)) キー（単打）" : "\(f.sorted().map(keyCap).joined(separator: "＋"))＋\(keyCap(code))"
        a.informativeText = "一覧から機能を選ぶか、記法で直接入力してください。\n記法: 「文字」=文字を出す / cmd+z / shift+8 / 左*5（5回）/ Enter?（?=かな入力時のみ）/ key98（キーコード）"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 360, height: 26))
        menu.addItem(withTitle: "機能を選ぶ…")
        menu.addItems(withTitles: EDIT_CATALOG.map { $0.menu })
        let field = NSTextField(frame: NSRect(x: 0, y: 2, width: 360, height: 24))
        field.stringValue = existing.map(stepsToDSL) ?? ""
        field.placeholderString = "例: cmd+z / 「年」 / 左*5"
        final class MenuTarget: NSObject {
            var onChange: ((Int) -> Void)?
            @objc func changed(_ s: NSPopUpButton) { onChange?(s.indexOfSelectedItem) }
        }
        let target = MenuTarget()
        target.onChange = { i in if i >= 1 { field.stringValue = EDIT_CATALOG[i - 1].dsl } }
        menu.target = target; menu.action = #selector(MenuTarget.changed(_:))
        box.addSubview(menu); box.addSubview(field)
        a.accessoryView = box
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "この割り当てを削除")
        a.addButton(withTitle: "キャンセル")
        let r = a.runModal()
        withExtendedLifetime(target) {}
        if r == .alertThirdButtonReturn { return }
        if r == .alertSecondButtonReturn {
            if f.isEmpty { baseAction.removeValue(forKey: code) } else { editActions.removeAll { $0.keys == keys } }
        } else {
            guard let steps = dslToSteps(field.stringValue) else {
                let e = NSAlert(); e.messageText = DISPLAY_NAME
                e.informativeText = "記法を解釈できませんでした。\n例: 「年」 / cmd+z / shift+8 Enter? / 左*5"
                e.runModal(); return
            }
            if f.isEmpty { baseAction[code] = steps }
            else if let i = editActions.firstIndex(where: { $0.keys == keys }) { editActions[i].steps = steps }
            else { editActions.append((keys, steps)) }
        }
        persistEditDefinitions()
        infoLabel.stringValue = "保存しました → edit_mode.json"
        let sel = popup.indexOfSelectedItem
        refreshAll()
        popup.selectItem(at: min(sel, popup.numberOfItems - 1))
        refreshGrid()
    }

    @objc func newFace() {
        var captured: [Int64] = []
        let a = NSAlert()
        a.messageText = "新しい面を作る"
        a.informativeText = "「キーを記録」を押してから、アンカーにする2つのキーを押してください（例: D と F）。記録中は打鍵が入力されません。"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 110, y: 4, width: 190, height: 22)
        let btn = NSButton(title: "キーを記録", target: nil, action: nil)
        btn.frame = NSRect(x: 0, y: 0, width: 105, height: 28)
        final class CapTarget: NSObject {
            var onClick: (() -> Void)?
            @objc func click() { onClick?() }
        }
        let t = CapTarget()
        t.onClick = {
            captured = []; label.stringValue = "（記録中…）"
            keyCapture = { code in
                if code != SPACE && !captured.contains(code) { captured.append(code) }
                label.stringValue = captured.map(keyCap).joined(separator: " ＋ ") + (captured.count >= 2 ? "" : " …")
                if captured.count >= 2 { keyCapture = nil }
            }
        }
        btn.target = t; btn.action = #selector(CapTarget.click)
        box.addSubview(btn); box.addSubview(label)
        a.accessoryView = box
        a.addButton(withTitle: "作る"); a.addButton(withTitle: "キャンセル")
        let r = a.runModal()
        keyCapture = nil
        withExtendedLifetime(t) {}
        guard r == .alertFirstButtonReturn, captured.count == 2 else { return }
        let f = Set(captured)
        if !extraFaces.contains(f) { extraFaces.append(f) }
        refreshAll()
        if let i = faces.firstIndex(of: f) { popup.selectItem(at: i); refreshGrid() }
    }
    @objc func openList() {
        if listEditor == nil { listEditor = EditModeEditorWindowController() }
        listEditor?.loadRows()
        listEditor?.table.reloadData()
        listEditor?.showWindow(nil)
        listEditor?.window?.makeKeyAndOrderFront(nil)
    }
}

// ==== 編集モードの簡易記法（DSL） ==============================================
// 例: 「年」= 年 の文字出力 / cmd+z / shift+8 / 左*5 / Enter?（?=かな入力時のみ）
let dslSpecial: [(Int, String)] = [(123,"左"),(124,"右"),(126,"上"),(125,"下"),(51,"BS"),(117,"Del"),
                                   (36,"Enter"),(53,"Esc"),(115,"Home"),(119,"End"),(48,"Tab"),(49,"Space"),(102,"英数"),(104,"かな")]
let dslCodeName: [Int: String] = {
    var d: [Int: String] = [:]
    for (k, v) in keyDisplay { d[Int(k)] = v }
    for (c, n) in dslSpecial { d[c] = n }
    return d
}()
let dslNameCode: [String: Int] = {
    var d: [String: Int] = [:]
    for (c, n) in dslCodeName { d[n] = c }
    return d
}()
let dslMods: [(String, CGEventFlags)] = [("cmd", CMD), ("shift", SFT), ("opt", OPT), ("ctrl", CTL)]

func stepToken(_ s: Step) -> String {
    if let t = s.text { return "「\(t)」" }
    var out = ""
    for (n, f) in dslMods where s.flags.contains(f) { out += n + "+" }
    out += dslCodeName[s.key] ?? "key\(s.key)"
    if s.confirmOnly { out += "?" }
    return out
}
func stepsToDSL(_ steps: [Step]) -> String {
    var out: [String] = []
    var i = 0
    while i < steps.count {
        let tok = stepToken(steps[i])
        var n = 1
        while i + n < steps.count && stepToken(steps[i + n]) == tok { n += 1 }
        out.append(n > 1 ? "\(tok)*\(n)" : tok)
        i += n
    }
    return out.joined(separator: " ")
}
func dslToSteps(_ dsl: String) -> [Step]? {
    var steps: [Step] = []
    var rest = Substring(dsl)
    while !rest.isEmpty {
        rest = rest.drop(while: { $0 == " " || $0 == "　" })
        if rest.isEmpty { break }
        if rest.first == "「" {
            guard let close = rest.firstIndex(of: "」") else { return nil }
            let text = String(rest[rest.index(after: rest.startIndex)..<close])
            steps.append(T(text))
            rest = rest[rest.index(after: close)...]
            continue
        }
        let tokEnd = rest.firstIndex(where: { $0 == " " || $0 == "　" }) ?? rest.endIndex
        var tok = String(rest[..<tokEnd])
        rest = rest[tokEnd...]
        // 繰り返し *N
        var repeatN = 1
        if let star = tok.lastIndex(of: "*"), let n = Int(tok[tok.index(after: star)...]), n >= 1 {
            repeatN = min(n, 50); tok = String(tok[..<star])
        }
        var confirmOnly = false
        if tok.hasSuffix("?") { confirmOnly = true; tok = String(tok.dropLast()) }
        var flags: CGEventFlags = []
        var keyPart = tok
        while let plus = keyPart.firstIndex(of: "+"), keyPart.index(after: plus) != keyPart.endIndex {
            let m = String(keyPart[..<plus]).lowercased()
            guard let f = dslMods.first(where: { $0.0 == m })?.1 else { break }
            flags.insert(f)
            keyPart = String(keyPart[keyPart.index(after: plus)...])
        }
        var code: Int? = dslNameCode[keyPart] ?? dslNameCode[keyPart.lowercased()]
        if code == nil, keyPart.hasPrefix("key"), let n = Int(keyPart.dropFirst(3)) { code = n }
        guard let kc = code else { return nil }
        for _ in 0..<repeatN {
            steps.append(Step(flags: flags, key: kc, text: nil, confirmOnly: confirmOnly))
        }
    }
    return steps.isEmpty ? nil : steps
}

// ==== 編集モードGUIエディタ ====================================================
final class EditModeEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var rows: [(keys: [Int64], steps: [Step])] = []
    let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "\(DISPLAY_NAME) 編集モードエディタ"
        self.init(window: win)
        buildUI()
    }
    func loadRows() {
        rows = baseAction.sorted { $0.key < $1.key }.map { ([$0.key], $0.value) }
            + editActions.map { ($0.keys.sorted(), $0.steps) }
    }
    func persist() {
        baseAction = Dictionary(uniqueKeysWithValues: rows.filter { $0.keys.count == 1 }.map { ($0.keys[0], $0.steps) })
        editActions = rows.filter { $0.keys.count >= 2 }.map { (Set($0.keys), $0.steps) }
        writeEditFileCurrent()
        buildTables()
        configureEngine()
        statusLabel.stringValue = "保存しました（\(rows.count)件） → edit_mode.json"
        table.reloadData()
    }
    func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let info = NSTextField(labelWithString: "同時押しキーと出力の一覧。記法: 「文字」=文字出力 / cmd+z / shift+8 / 左*5 / Enter?（?=かな入力時のみ実行）")
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        stack.addArrangedSubview(info)

        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keys"))
        c1.title = "同時押しキー"; c1.width = 140
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dsl"))
        c2.title = "出力・操作"; c2.width = 340
        table.addTableColumn(c1); table.addTableColumn(c2)
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(editRow)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        stack.addArrangedSubview(scroll)

        let btns = NSStackView()
        btns.orientation = .horizontal; btns.spacing = 8
        btns.addArrangedSubview(NSButton(title: "追加…", target: self, action: #selector(addRow)))
        btns.addArrangedSubview(NSButton(title: "編集…（ダブルクリックでも）", target: self, action: #selector(editRow)))
        btns.addArrangedSubview(NSButton(title: "削除", target: self, action: #selector(deleteRow)))
        stack.addArrangedSubview(btns)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(stack.fittingSize)
        window?.center()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text = tableColumn?.identifier.rawValue == "keys"
            ? r.keys.map { keyDisplay[$0] ?? "key\($0)" }.joined(separator: " + ")
            : stepsToDSL(r.steps)
        let f = NSTextField(labelWithString: text)
        f.lineBreakMode = .byTruncatingTail
        return f
    }
    @objc func addRow() { editDialog(rowIndex: nil) }
    @objc func editRow() {
        let i = table.selectedRow
        if i >= 0 && i < rows.count { editDialog(rowIndex: i) }
    }
    @objc func deleteRow() {
        let i = table.selectedRow
        guard i >= 0 && i < rows.count else { return }
        rows.remove(at: i)
        persist()
    }
    func editDialog(rowIndex: Int?) {
        let existing = rowIndex.map { rows[$0] }
        var captured: [Int64] = existing?.keys ?? []

        let a = NSAlert()
        a.messageText = rowIndex == nil ? "組み合わせを追加" : "組み合わせを編集"
        a.informativeText = "①「キーを記録」を押して実際のキーを打鍵（1〜3キー）\n②出力・操作を記法で入力"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        let keysLabel = NSTextField(labelWithString: captured.map { keyDisplay[$0] ?? "key\($0)" }.joined(separator: " + "))
        keysLabel.frame = NSRect(x: 110, y: 56, width: 230, height: 22)
        let capBtn = NSButton(title: "キーを記録", target: nil, action: nil)
        capBtn.frame = NSRect(x: 0, y: 52, width: 105, height: 28)
        let dslField = NSTextField(frame: NSRect(x: 0, y: 16, width: 340, height: 24))
        dslField.stringValue = existing.map { stepsToDSL($0.steps) } ?? ""
        dslField.placeholderString = "例: 「年」 / cmd+z / shift+8 Enter? / 左*5"
        let hint = NSTextField(labelWithString: "記録中は打鍵が入力されません。3キーで自動終了。")
        hint.frame = NSRect(x: 0, y: 0, width: 340, height: 14)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        box.addSubview(capBtn); box.addSubview(keysLabel); box.addSubview(dslField); box.addSubview(hint)
        a.accessoryView = box
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")

        final class CapTarget: NSObject {
            var onClick: (() -> Void)?
            @objc func click() { onClick?() }
        }
        let capTarget = CapTarget()
        capTarget.onClick = {
            captured = []
            keysLabel.stringValue = "（記録中…）"
            keyCapture = { code in
                if !captured.contains(code) { captured.append(code) }
                keysLabel.stringValue = captured.map { keyDisplay[$0] ?? "key\($0)" }.joined(separator: " + ") + (captured.count >= 3 ? "" : " …")
                if captured.count >= 3 { keyCapture = nil }
            }
        }
        capBtn.target = capTarget
        capBtn.action = #selector(CapTarget.click)

        let result = a.runModal()
        keyCapture = nil
        guard result == .alertFirstButtonReturn else { return }
        guard !captured.isEmpty, captured.count <= 3 else {
            let e = NSAlert(); e.messageText = DISPLAY_NAME; e.informativeText = "キーが記録されていません。"; e.runModal(); return
        }
        guard let steps = dslToSteps(dslField.stringValue) else {
            let e = NSAlert(); e.messageText = DISPLAY_NAME
            e.informativeText = "出力・操作の記法を解釈できません。\n例: 「年」 / cmd+z / shift+8 Enter? / 左*5"
            e.runModal(); return
        }
        let sorted = captured.sorted()
        if let i = rowIndex { rows[i] = (sorted, steps) }
        else { rows.append((sorted, steps)) }
        persist()
    }
}

// ==== 設定ウィンドウ ===========================================================
final class SettingsWindowController: NSWindowController {
    var sliders: [String: NSSlider] = [:]
    var valueLabels: [String: NSTextField] = [:]
    var layoutLabel = NSTextField(labelWithString: "")
    let layoutPopup = NSPopUpButton()
    let editPresetPopup = NSPopUpButton()
    var statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "\(DISPLAY_NAME) 設定"
        self.init(window: win)
        buildUI()
    }
    func fmt(_ p: Param, _ v: Double) -> String { p.isPercent ? String(format: "%.0f%%", v * 100) : String(format: "%.0fms", v) }

    func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        func section(_ title: String) {
            let t = NSTextField(labelWithString: title)
            t.font = NSFont.boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(t)
        }
        section("同時打鍵の判定しきい値")
        for p in params {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: p.label)
            label.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let slider = NSSlider(value: p.get(), minValue: p.lo, maxValue: p.hi,
                                  target: self, action: #selector(sliderChanged(_:)))
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            slider.identifier = NSUserInterfaceItemIdentifier(p.key)
            let val = NSTextField(labelWithString: fmt(p, p.get()))
            val.widthAnchor.constraint(equalToConstant: 60).isActive = true
            sliders[p.key] = slider
            valueLabels[p.key] = val
            row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(val)
            stack.addArrangedSubview(row)
        }
        let reset = NSButton(title: "初期値に戻す（実測チューニング値）", target: self, action: #selector(resetDefaults))
        stack.addArrangedSubview(reset)

        stack.addArrangedSubview(NSBox.separator(width: 520))
        section("配列")
        let layoutRow = NSStackView()
        layoutRow.orientation = .horizontal; layoutRow.spacing = 8
        layoutPopup.removeAllItems()
        layoutPopup.addItems(withTitles: BUNDLED_LAYOUTS.map { $0.label } + ["ファイルから選んだ配列"])
        layoutPopup.target = self; layoutPopup.action = #selector(layoutPopupChanged)
        syncLayoutPopup()
        layoutRow.addArrangedSubview(layoutPopup)
        stack.addArrangedSubview(layoutRow)
        layoutLabel.stringValue = layoutPath
        layoutLabel.lineBreakMode = .byTruncatingMiddle
        layoutLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true
        stack.addArrangedSubview(layoutLabel)
        let fileRow = NSStackView()
        fileRow.orientation = .horizontal; fileRow.spacing = 8
        fileRow.addArrangedSubview(NSButton(title: "ファイルを選択（.json / 紅皿 .bnz）…", target: self, action: #selector(chooseLayout)))
        fileRow.addArrangedSubview(NSButton(title: "再読み込み", target: self, action: #selector(reloadLayout)))
        fileRow.addArrangedSubview(NSButton(title: "文字盤エディタで編集…", target: self, action: #selector(openEditor)))
        stack.addArrangedSubview(fileRow)

        stack.addArrangedSubview(NSBox.separator(width: 520))
        section("編集モード・固有名詞/矢印面などの定義")
        let editInfo = NSTextField(labelWithString: "初期値は薙刀式v18公式準拠。GUIで自由に変更できます（edit_mode.json に保存）。")
        editInfo.font = NSFont.systemFont(ofSize: 11)
        editInfo.textColor = .secondaryLabelColor
        stack.addArrangedSubview(editInfo)
        let editRow = NSStackView()
        editRow.orientation = .horizontal; editRow.spacing = 8
        editRow.addArrangedSubview(NSButton(title: "文字盤エディタで編集…", target: self, action: #selector(openEditModeEditor)))
        editRow.addArrangedSubview(NSButton(title: "定義ファイルをFinderで表示", target: self, action: #selector(revealEdit)))
        editRow.addArrangedSubview(NSButton(title: "再読み込み", target: self, action: #selector(reloadLayout)))
        stack.addArrangedSubview(editRow)
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal; presetRow.spacing = 8
        presetRow.addArrangedSubview(NSTextField(labelWithString: "プリセット:"))
        editPresetPopup.removeAllItems()
        editPresetPopup.addItems(withTitles: ["選んで適用…"] + BUNDLED_EDIT_PRESETS.map { $0.label })
        editPresetPopup.target = self; editPresetPopup.action = #selector(editPresetChosen)
        presetRow.addArrangedSubview(editPresetPopup)
        presetRow.addArrangedSubview(NSButton(title: "ファイルから読み込む…", target: self, action: #selector(importEditPreset)))
        stack.addArrangedSubview(presetRow)

        stack.addArrangedSubview(NSBox.separator(width: 520))
        statusLabel.stringValue = "配列: \(layoutStatus)"
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(stack.fittingSize)
        window?.center()
    }
    @objc func sliderChanged(_ s: NSSlider) {
        guard let key = s.identifier?.rawValue, let p = params.first(where: { $0.key == key }) else { return }
        p.set(s.doubleValue)
        UserDefaults.standard.set(s.doubleValue, forKey: p.key)
        valueLabels[key]?.stringValue = fmt(p, s.doubleValue)
        syncEngineParams()
    }
    @objc func resetDefaults() {
        for p in params {
            p.set(p.def)
            UserDefaults.standard.removeObject(forKey: p.key)
            sliders[p.key]?.doubleValue = p.def
            valueLabels[p.key]?.stringValue = fmt(p, p.def)
        }
        syncEngineParams()
    }
    @objc func chooseLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "bnz") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            layoutPath = url.path
            layoutLabel.stringValue = layoutPath
            reloadLayout()
        }
        syncLayoutPopup()
    }
    @objc func reloadLayout() {
        if reloadAll() {
            statusLabel.stringValue = "配列: \(layoutStatus)"
        } else {
            statusLabel.stringValue = "配列: \(layoutStatus)"
            let a = NSAlert(); a.messageText = DISPLAY_NAME
            a.informativeText = "配列ファイルを読み込めませんでした。\n\(layoutPath)"
            a.runModal()
        }
    }
    func syncLayoutPopup() {
        let idx = BUNDLED_LAYOUTS.firstIndex { layoutPath == SUPPORT_DIR + "/\($0.name).json" }
        layoutPopup.selectItem(at: idx ?? BUNDLED_LAYOUTS.count)
    }
    @objc func layoutPopupChanged() {
        let i = layoutPopup.indexOfSelectedItem
        guard i < BUNDLED_LAYOUTS.count else { chooseLayout(); return }
        guard let path = installBundledLayout(BUNDLED_LAYOUTS[i].name) else {
            let a = NSAlert(); a.messageText = DISPLAY_NAME; a.informativeText = "同梱の配列を書き出せませんでした。"; a.runModal(); return
        }
        layoutPath = path
        layoutLabel.stringValue = layoutPath
        reloadLayout()
    }
    /// 編集モード定義を置き換える（今の定義は edit_mode.backup.json に退避）。src=nil なら公式準拠の初期値
    func applyEditPreset(from src: String?, label: String) {
        let a = NSAlert(); a.messageText = DISPLAY_NAME
        a.informativeText = "編集モード定義を「\(label)」に置き換えます。今の定義は edit_mode.backup.json として保存されます。"
        a.addButton(withTitle: "置き換える"); a.addButton(withTitle: "キャンセル")
        if a.runModal() != .alertFirstButtonReturn { return }
        let fm = FileManager.default
        let backup = SUPPORT_DIR + "/edit_mode.backup.json"
        try? fm.removeItem(atPath: backup)
        if fm.fileExists(atPath: EDIT_PATH) { try? fm.copyItem(atPath: EDIT_PATH, toPath: backup) }
        if let src = src {
            guard let data = fm.contents(atPath: src) else { return }
            try? data.write(to: URL(fileURLWithPath: EDIT_PATH))
            if !loadEditFile() {
                if fm.fileExists(atPath: backup) { try? fm.removeItem(atPath: EDIT_PATH); try? fm.copyItem(atPath: backup, toPath: EDIT_PATH) }
                let e = NSAlert(); e.messageText = DISPLAY_NAME; e.informativeText = "編集モード定義として読み込めないファイルでした。元に戻しました。"; e.runModal()
            }
        } else {
            writeDefaultEditFile()
        }
        reloadLayout()
    }
    @objc func editPresetChosen() {
        let i = editPresetPopup.indexOfSelectedItem - 1
        editPresetPopup.selectItem(at: 0)
        guard i >= 0 && i < BUNDLED_EDIT_PRESETS.count else { return }
        let preset = BUNDLED_EDIT_PRESETS[i]
        if let name = preset.name {
            guard let path = Bundle.main.path(forResource: name, ofType: "json", inDirectory: "edit_presets") else { return }
            applyEditPreset(from: path, label: preset.label)
        } else {
            applyEditPreset(from: nil, label: preset.label)
        }
    }
    @objc func importEditPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyEditPreset(from: url.path, label: url.lastPathComponent)
    }
    @objc func revealEdit() {
        if !FileManager.default.fileExists(atPath: EDIT_PATH) { writeDefaultEditFile() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: EDIT_PATH)])
    }
    var keyboardWC: KeyboardEditorWindowController?
    @objc func openEditor() {
        if keyboardWC == nil { keyboardWC = KeyboardEditorWindowController() }
        keyboardWC?.show(editMode: false)
    }
    @objc func openEditModeEditor() {
        if keyboardWC == nil { keyboardWC = KeyboardEditorWindowController() }
        keyboardWC?.show(editMode: true)
    }
}
extension NSBox {
    static func separator(width: CGFloat) -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }
}

// ==== アプリ ==================================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var settingsWC: SettingsWindowController?
    let enabledItem = NSMenuItem(title: "薙刀式を有効にする", action: #selector(toggleEnabled), keyEquivalent: "")
    let logItem = NSMenuItem(title: "ログをファイルに記録", action: #selector(toggleLog), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "ログイン時に自動起動", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 他の配列エミュレータ（または本アプリの別インスタンス）と同時に動くと二重変換になるため起動しない
        let myPID = ProcessInfo.processInfo.processIdentifier
        // 自分自身の二重起動を検出する
        let myID = Bundle.main.bundleIdentifier ?? ""
        let conflicts = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != myPID && $0.bundleIdentifier == myID
        }
        if let c = conflicts.first {
            fatalAlert("「\(c.localizedName ?? c.bundleIdentifier ?? "別のアプリ")」が起動しています。\n\n配列エミュレータを同時に動かすとキー入力が二重に変換されます。そちらを終了してから起動してください。")
            return
        }
        installDefaultLayoutIfNeeded()
        let axOK = AXIsProcessTrusted()
        let listenOK = CGPreflightListenEventAccess()
        if !axOK {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !listenOK { _ = CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }

        loadPrefs()
        guard reloadAll() else {
            fatalAlert("配列ファイルを読み込めません。\n\(layoutPath)\n設定画面から正しいファイルを選択してください。")
            return
        }
        if !startTap() {
            fatalAlert("キーボードの取得に失敗しました。\n\nシステム設定 → プライバシーとセキュリティ で\n・アクセシビリティ\n・入力監視\nの両方に「\(DISPLAY_NAME)」（\(APP_NAME)）を追加・オンにしてから、アプリを起動し直してください。")
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let title = NSMenuItem(title: "\(DISPLAY_NAME) \(APP_VERSION)（薙刀式入力エミュレーター）", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(NSMenuItem.separator())
        enabledItem.target = self; menu.addItem(enabledItem)
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        logItem.target = self; menu.addItem(logItem)
        loginItem.target = self; menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())
        let openSupport = NSMenuItem(title: "設定フォルダを開く", action: #selector(openSupportDir), keyEquivalent: "")
        openSupport.target = self; menu.addItem(openSupport)
        let openLogs = NSMenuItem(title: "ログフォルダを開く", action: #selector(openLogDir), keyEquivalent: "")
        openLogs.target = self; menu.addItem(openLogs)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        updateUI()
    }
    func fatalAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = DISPLAY_NAME
        a.informativeText = text
        a.runModal()
        NSApp.terminate(nil)
    }
    func updateUI() {
        if let img = Bundle.main.image(forResource: "MenuIcon") {
            img.isTemplate = true          // メニューバーの明暗に合わせて自動で色が変わる
            img.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = img
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.title = "薙"
        }
        statusItem?.button?.appearsDisabled = !engineEnabled
        enabledItem.state = engineEnabled ? .on : .off
        logItem.state = logEnabled ? .on : .off
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
    @objc func toggleEnabled() {
        engineEnabled.toggle()
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: engineEnabled) }
        resetEngine()
        updateUI()
    }
    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggleLog() {
        if !logEnabled {
            let a = NSAlert()
            a.messageText = "打鍵ログを記録しますか？"
            a.informativeText = "ログには、オンにしている間のすべての打鍵（キーの種類と押した/離した時刻）が記録されます。打った文章を再現できる情報なので、パスワードや個人的な文章を打つ前にオフにし、ログを人に渡すときは中身に注意してください。\n\n保存先: \(LOG_PATH)"
            a.addButton(withTitle: "記録を開始")
            a.addButton(withTitle: "キャンセル")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        setLogging(!logEnabled); updateUI()
    }
    @objc func openSupportDir() { NSWorkspace.shared.open(URL(fileURLWithPath: SUPPORT_DIR)) }
    @objc func openLogDir() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_DIR)) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item error: \(error)") }
        updateUI()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
}

// 打鍵ログの再生モード（検証用）: アプリは起動せず、判定結果を標準出力に書いて終了する
if let i = CommandLine.arguments.firstIndex(of: "--replay") {
    runReplayCLI(Array(CommandLine.arguments[(i + 1)...]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
