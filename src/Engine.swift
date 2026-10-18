// Engine.swift
// -----------------------------------------------------------------------------
// 同時打鍵の判定エンジン（純粋なロジック部。OSのイベントや出力には触れない）
//
// 設計の要点
//  1. 押下順に「先頭キー」を一つずつ確定させる。出力は必ず押下順になる
//     （和音は、その和音の最初のキーの押下位置に置かれる）。
//  2. 先頭キーの相手には「先頭キーと組める（配列に定義がある）キー」だけを探す。
//     組めないキーは先頭キーの判定を左右しない（ただし関係が未確定の間は待つ）。
//  3. 2キーが同時押しかどうかの規則は Judge.judge() の一か所にまとめてあり、
//     判定を確定させるタイマーの時刻も、同じ規則の境界時刻（Judge.boundaries）から導く。
//  4. 編集モード（アンカー2キー＋3キー目）も同じエンジンの中で扱い、
//     アンカーに使われたキーは、かなの和音に再利用されない。
//
// このファイルは Python の検証用シミュレータ（tools/engine_sim/new_engine.py）と
// 一行ずつ対応しており、`--replay` で同じ打鍵ログを流すと同じ結果になることを確認できる。
// -----------------------------------------------------------------------------

import Foundation

let NS_PER_MS: Double = 1_000_000

/// 判定パラメータ（設定画面のスライダーと対応）
struct JudgeParams {
    var thumbRatio: Double = 0.60          // 親指が先（Space→文字）の重なり割合
    var charThenThumbRatio: Double = 0.80  // 文字が先（文字→Space）の重なり割合
    var charRatio: Double = 0.60           // 文字同士の重なり割合（後キー基準）
    var shorterLo: Double = 0.60           // 文字同士の第2判定: 短い方基準の下限
    var shorterHi: Double = 0.90           //  〃 上限（内包型ロールの除外）
    var shorterMinOvMs: Double = 40        //  〃 最小重なり[ms]
    var shorterNestCapMs: Double = 200     //  〃 上限超でも両キーの押下がこれ以下なら成立（短い完全同時押し）
    var thumbOverlapOkMs: Double = 25      // Space先行の絶対重なり救済[ms]（0で無効）
    var rolloverGuardMs: Double = 12       // 誤和音ガード[ms]
    var editPairMs: Double = 60            // 編集モード: アンカー2キーの押下時刻差の上限[ms]
    var timerMarginMs: Double = 1          // 確定タイマーの余裕[ms]
}

/// エンジンの判定結果
enum Decision: Equatable {
    case single(Int64)          // 単打
    case chord(Set<Int64>)      // 同時打鍵（2〜3キー）
    case edit(Int)              // 編集モード（editChords の添字）
}

final class KeyPress {
    let code: Int64
    let down: UInt64
    var up: UInt64? = nil
    var shift = false   // 連続シフトとして保持中のSpace
    var done = false    // 出力済み（解放待ち）
    init(_ code: Int64, _ down: UInt64) { self.code = code; self.down = down }
}

/// 2キーが同時押しかどうかの規則。true=同時押し / false=別打鍵 / nil=まだ決められない
struct Judge {
    var p: JudgeParams
    let space: Int64

    func threshold(_ a: KeyPress, _ b: KeyPress) -> Double {
        if a.code == space { return p.thumbRatio }
        if b.code == space { return p.charThenThumbRatio }
        return p.charRatio
    }
    static func overlapNs(_ a: KeyPress, _ b: KeyPress, _ now: UInt64) -> UInt64 {
        let e1 = a.up ?? now, e2 = b.up ?? now
        let s = max(a.down, b.down), e = min(e1, e2)
        return e > s ? e - s : 0
    }
    func shorterOK(_ ovMs: Double, _ r2: Double, _ maxDurMs: Double) -> Bool {
        return ovMs >= p.shorterMinOvMs && r2 >= p.shorterLo && (r2 < p.shorterHi || maxDurMs <= p.shorterNestCapMs)
    }
    /// a: 先に押したキー, b: 後に押したキー
    func judge(_ a: KeyPress, _ b: KeyPress, _ now: UInt64) -> Bool? {
        let th = threshold(a, b)
        let isChar = a.code != space && b.code != space
        let ovMs = Double(Judge.overlapNs(a, b, now)) / NS_PER_MS
        // 規則1: Space先行の絶対重なり救済（どちらかが離された後、重なりが一定以上）
        if a.code == space && p.thumbOverlapOkMs > 0 && (a.up != nil || b.up != nil) && ovMs >= p.thumbOverlapOkMs {
            return true
        }
        if let bu = b.up {
            // 規則2: 後キー基準の重なり割合
            let bDur = Double(bu - b.down) / NS_PER_MS
            let r = bu > b.down ? ovMs / bDur : 0
            if r >= th { return true }
            // 規則3: 文字同士の第2判定（短い方の押下時間基準）
            if isChar, let au = a.up {
                let d1 = Double(au - a.down) / NS_PER_MS
                if shorterOK(ovMs, ovMs / max(1, min(d1, bDur)), max(d1, bDur)) { return true }
            }
            return false
        }
        guard let au = a.up else { return nil }        // 両方押下中
        let d1 = Double(au - a.down) / NS_PER_MS
        // a は離され、b は押下中
        if b.code == space {                            // 文字→親指: 文字の押下時間を分母に即決
            return (d1 > 0 ? ovMs / d1 : 0) >= th
        }
        let d2now = Double(now - b.down) / NS_PER_MS
        let maxRatio = d2now > 0 ? ovMs / d2now : 1.0
        if isChar {
            if d2now >= d1 && d1 > 0 && shorterOK(ovMs, ovMs / d1, max(d1, d2now)) { return true }
            let r2min = d1 > 0 ? ovMs / d1 : 0
            let r2max = ovMs / max(1, min(d1, d2now))
            let capPossible = d1 <= p.shorterNestCapMs && d2now <= p.shorterNestCapMs
            let r2possible = ovMs >= p.shorterMinOvMs && r2max >= p.shorterLo && (r2min < p.shorterHi || capPossible)
            if maxRatio < th && !r2possible { return false }
            return nil
        }
        if maxRatio < th { return false }
        return nil
    }
    /// judge(a,b) の結果が変わりうる時刻（a離鍵済み・b押下中のときだけ意味がある）
    func boundaries(_ a: KeyPress, _ b: KeyPress) -> [UInt64] {
        guard let au = a.up, b.up == nil else { return [] }
        let ov = au > b.down ? au - b.down : 0
        let th = threshold(a, b)
        var t: [UInt64] = [b.down + UInt64(Double(ov) / th)]            // 割合がしきい値を割る時刻
        if a.code != space && b.code != space {
            t.append(b.down + (au - a.down))                            // bの押下時間がaに並ぶ時刻
            t.append(b.down + UInt64(p.shorterNestCapMs * NS_PER_MS))   // 短同時押し救済の上限を超える時刻
        }
        return t
    }
}

final class ChordEngine {
    let space: Int64
    var judge: Judge
    /// 配列の和音: キー集合 → 各定義が「かな入力時のみ」か
    private(set) var combos: [Set<Int64>: [Bool]] = [:]
    private var triplePairs: Set<Set<Int64>> = []
    /// 編集モードのキー集合（アプリ側の editActions と同じ順）
    var editChords: [Set<Int64>] = []
    /// かな入力中か（英数入力では「かな入力時のみ」の和音を使わず、Space+キーはShift扱い）
    var kanaMode = true

    private(set) var buf: [KeyPress] = []
    private(set) var pressed: Set<Int64> = []
    private var lastDown: [Int64: UInt64] = [:]
    private var out: [Decision] = []
    private(set) var nextDeadline: UInt64? = nil

    init(space: Int64 = 49, params: JudgeParams = JudgeParams()) {
        self.space = space
        self.judge = Judge(p: params, space: space)
    }
    var params: JudgeParams {
        get { judge.p }
        set { judge.p = newValue }
    }
    func setCombos(_ list: [(keys: Set<Int64>, kanaOnly: Bool)]) {
        combos = [:]
        for c in list { combos[c.keys, default: []].append(c.kanaOnly) }
        triplePairs = []
        for (k, _) in combos where k.count == 3 {
            let a = k.sorted()
            triplePairs.insert([a[0], a[1]]); triplePairs.insert([a[0], a[2]]); triplePairs.insert([a[1], a[2]])
        }
    }
    func reset() {
        buf.removeAll(); pressed.removeAll(); lastDown.removeAll(); out.removeAll(); nextDeadline = nil
    }
    func isPressed(_ code: Int64) -> Bool { pressed.contains(code) }

    func hasCombo(_ keys: Set<Int64>) -> Bool {
        if let flags = combos[keys] {
            for kanaOnly in flags where !kanaOnly || kanaMode { return true }
        }
        if !kanaMode && keys.count == 2 && keys.contains(space) { return true }   // 英数時の Space+キー = Shift+キー
        return false
    }

    // ---- イベント入口（返り値はこの時点で確定した判定。押下順に並ぶ） ----
    func keyDown(_ code: Int64, at t: UInt64) -> [Decision] {
        out = []
        fireTimers(until: t)
        pressed.insert(code); lastDown[code] = t
        if code != space, let idx = editCompleted(by: code) {
            out.append(.edit(idx))
            for k in buf where !k.done && editChords[idx].contains(k.code) { k.done = true }   // アンカーは出力しない
            return out
        }
        buf.append(KeyPress(code, t))
        resolve(t); schedule(t)
        return out
    }
    func keyUp(_ code: Int64, at t: UInt64) -> [Decision] {
        out = []
        fireTimers(until: t)
        pressed.remove(code)
        guard let k = buf.last(where: { $0.code == code && $0.up == nil }) else { return out }
        k.up = t
        resolve(t); schedule(t)
        return out
    }
    /// タイマー（nextDeadline）到来時に呼ぶ
    func timerFired(at t: UInt64) -> [Decision] {
        out = []
        fireTimers(until: t)
        return out
    }
    /// 単独で押しっぱなしのキーを、長押しリピート用に引き取る（そのキーの単打は出さない）
    func takeLoneHeld(_ code: Int64) -> Bool {
        let live = buf.filter { !$0.done }
        guard live.count == 1, let k = live.first, k.code == code, k.up == nil, !k.shift else { return false }
        k.done = true
        return true
    }
    /// 英数入力でSpaceを押しながらの記号入力に使われたSpaceを、連続シフト扱いにする
    func markSpaceAsShift() {
        for k in buf where k.code == space && k.up == nil && !k.done { k.shift = true }
    }

    // ---- 中核: 先頭キーを押下順に確定させる ----
    private func resolve(_ now: UInt64) {
        while true {
            buf.removeAll { $0.done && $0.up != nil }
            let live = buf.filter { !$0.done }
            guard let h = live.first else { return }
            let rest = Array(live.dropFirst())

            // (1) 3キー同時押しの候補（hを含むもの）
            var decided = false
            outer: for i in 0..<rest.count {
                for j in (i + 1)..<max(i + 1, rest.count) {
                    let b = rest[i], c = rest[j]
                    let keys: Set<Int64> = [h.code, b.code, c.code]
                    if keys.count < 3 || !hasCombo(keys) { continue }
                    if h.up == nil && b.up == nil && c.up == nil { return }          // 3つとも押下中→待つ
                    func pj(_ x: KeyPress, _ y: KeyPress) -> Bool? {
                        (x.up == nil && y.up == nil) ? true : judge.judge(x, y, now)
                    }
                    guard let v1 = pj(h, b), let v2 = pj(b, c), let v3 = pj(h, c) else { return }   // 未確定→待つ
                    let e = [h, b, c].map { Double(($0.up ?? now) - $0.down) }
                    let mx = e.max()!, mn = e.min()!
                    let symmetric = mx > 0 && mn / mx >= judge.p.charRatio
                    let held3 = [h, b].allSatisfy { $0.up == nil || $0.up! > c.down }
                    if (v1 && v2 && v3) || (symmetric && held3) {
                        out.append(.chord(keys)); consume(h); consume(b); consume(c)
                        decided = true
                        break outer
                    }
                }
            }
            if decided { continue }

            // (2) 2キー: hと組めるキーだけを押下順に調べる
            var partner: KeyPress? = nil
            for b in rest {
                let pair: Set<Int64> = [h.code, b.code]
                if pair.count < 2 { continue }
                if h.shift && b.shift { continue }
                let v = judge.judge(h, b, now)
                if !hasCombo(pair) {
                    if v == nil { return }        // 組めないキーでも、hとの関係が未確定の間は順序保持のため待つ
                    continue
                }
                guard let ok = v else { return }
                if !ok { continue }
                // 誤和音ガード: 両方離鍵済みで重なりが極小、かつ後続キーがある
                if h.up != nil && b.up != nil
                    && Double(Judge.overlapNs(h, b, now)) < judge.p.rolloverGuardMs * NS_PER_MS
                    && rest.contains(where: { $0 !== b && $0.down > b.down }) {
                    continue
                }
                // 3キーへ伸びる可能性があれば待つ
                if triplePairs.contains(pair)
                    && rest.contains(where: { $0.down > b.down && judge.judge(b, $0, now) == nil }) {
                    return
                }
                partner = b
                break
            }
            if let b = partner {
                out.append(.chord([h.code, b.code])); consume(h); consume(b)
                continue
            }

            // (3) 組める相手がいない
            if h.up == nil && !rest.contains(where: { $0.up != nil || judge.judge(h, $0, now) != nil }) {
                return                            // hは押下中で、まだ何も決まっていない→待つ
            }
            if !h.shift { out.append(.single(h.code)) }   // 連続シフトのSpaceは黙って退場
            h.done = true
        }
    }
    private func consume(_ k: KeyPress) {
        if k.code == space && k.up == nil && pressed.contains(space) { k.shift = true }   // 連続シフト
        else { k.done = true }
    }
    private func schedule(_ now: UInt64) {
        var best: UInt64? = nil
        let live = buf.filter { !$0.done }
        let margin = UInt64(judge.p.timerMarginMs * NS_PER_MS)
        for i in 0..<live.count {
            for j in (i + 1)..<max(i + 1, live.count) {
                for t in judge.boundaries(live[i], live[j]) {
                    let tt = t + margin
                    if tt > now && (best == nil || tt < best!) { best = tt }
                }
            }
        }
        nextDeadline = best
    }
    private func fireTimers(until t: UInt64) {
        while let d = nextDeadline, d <= t {
            nextDeadline = nil
            resolve(d); schedule(d)
        }
    }
    private func editCompleted(by code: Int64) -> Int? {
        var best: Int? = nil
        for (idx, keys) in editChords.enumerated() where keys.contains(code) {
            let others = keys.subtracting([code])
            if !others.allSatisfy({ pressed.contains($0) }) { continue }
            let ts = others.compactMap { lastDown[$0] }
            if ts.count >= 2, let mn = ts.min(), let mx = ts.max(),
               Double(mx - mn) / NS_PER_MS > judge.p.editPairMs { continue }
            if best == nil || keys.count > editChords[best!].count { best = idx }
        }
        return best
    }
}

// ---- 打鍵ログの再生（検証用） ------------------------------------------------
// ログ形式: "[123ms] DN <キー名>" / "[123ms] UP <キー名>" / "[123ms] [mode] ... => かな|英数..."
enum ReplayEvent { case down(Int64, UInt64), up(Int64, UInt64), mode(Bool, UInt64) }

func parseReplayLog(_ text: String, keyCode: (String) -> Int64?) -> [[ReplayEvent]] {
    var sessions: [[ReplayEvent]] = []
    for line in text.components(separatedBy: "\n") {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
        let tsStr = line[line.index(after: line.startIndex)..<close].replacingOccurrences(of: "ms", with: "")
        guard let ms = UInt64(tsStr) else { continue }
        let t = ms * 1_000_000
        let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("=== ログ記録開始") { sessions.append([]); continue }
        if sessions.isEmpty { continue }
        if body.hasPrefix("DN "), let c = keyCode(String(body.dropFirst(3))) { sessions[sessions.count - 1].append(.down(c, t)) }
        else if body.hasPrefix("UP "), let c = keyCode(String(body.dropFirst(3))) { sessions[sessions.count - 1].append(.up(c, t)) }
        else if body.hasPrefix("[mode]") { sessions[sessions.count - 1].append(.mode(body.hasSuffix("かな"), t)) }
    }
    return sessions
}

/// 再生して、判定結果を1行ずつの文字列で返す（Python 側と同じ書式）
func replay(_ engine: ChordEngine, _ events: [ReplayEvent]) -> [String] {
    var lines: [String] = []
    func fmt(_ t: UInt64, _ ds: [Decision]) {
        for d in ds {
            switch d {
            case .single(let c): lines.append("\(t / 1_000_000) S \(c)")
            case .chord(let ks): lines.append("\(t / 1_000_000) C \(ks.sorted().map(String.init).joined(separator: ","))")
            case .edit(let i): lines.append("\(t / 1_000_000) E \(engine.editChords[i].sorted().map(String.init).joined(separator: ","))")
            }
        }
    }
    func drainTimers(until t: UInt64) {
        while let d = engine.nextDeadline, d <= t { fmt(d, engine.timerFired(at: d)) }
    }
    engine.reset()
    for e in events {
        switch e {
        case .down(let c, let t): drainTimers(until: t); fmt(t, engine.keyDown(c, at: t))
        case .up(let c, let t): drainTimers(until: t); fmt(t, engine.keyUp(c, at: t))
        case .mode(let k, let t): drainTimers(until: t); engine.kanaMode = k
        }
    }
    drainTimers(until: UInt64.max)
    return lines
}
