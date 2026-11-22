import Foundation
import AVFoundation
import FluidAudio

// Voiceprint calibration: CAM++ cosine similarity for same vs different speakers, and on mixtures.
func load16k(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = AVAudioFormat(standardFormatWithSampleRate: f.fileFormat.sampleRate, channels: 1)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: b)
    precondition(f.fileFormat.sampleRate == 16000)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}
func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))) }

let dir = CommandLine.arguments[1]
let A = try load16k(dir + "/voice_a.wav"), B = try load16k(dir + "/voice_b.wav")
let emb = try await CampPlusEmbedder.load()
// reference voiceprints from 6 s of each (different part of the memo than the tests)
let refA = try await emb.embed(audio: Array(A[(200*16000)..<(206*16000)]))
let refB = try await emb.embed(audio: Array(B[(200*16000)..<(206*16000)]))
print(String(format: "reference A vs B cosine: %.3f", cos(refA, refB)))

for win in [0.5, 1.0, 1.5, 3.0] {
    let n = Int(win * 16000)
    var same: [Float] = [], diff: [Float] = [], mixT: [Float] = []
    var ms: [Double] = []
    var t = 10 * 16000
    while t + n < 180 * 16000 {
        let a = A[t..<(t + n)], b = B[t..<(t + n)]
        if rms(a) > 0.01 && rms(b) > 0.01 {
            let t0 = Date()
            let ea = try await emb.embed(audio: Array(a))
            ms.append(Date().timeIntervalSince(t0) * 1000)
            let eb = try await emb.embed(audio: Array(b))
            let mix = zip(a, b).map { $0 + $1 }
            let em = try await emb.embed(audio: mix)
            same.append(cos(ea, refA)); same.append(cos(eb, refB))
            diff.append(cos(ea, refB)); diff.append(cos(eb, refA))
            mixT.append(cos(em, refA))
        }
        t += n
    }
    func q(_ v: [Float], _ p: Double) -> Float { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
    // best threshold = max balanced accuracy
    var best: (Float, Double) = (0, 0)
    for th in stride(from: Float(0), through: 1, by: 0.01) {
        let hitS: Double = Double(same.filter { $0 >= th }.count) / Double(same.count)
        let hitD: Double = Double(diff.filter { $0 < th }.count) / Double(diff.count)
        let acc: Double = 0.5 * hitS + 0.5 * hitD
        if acc > best.1 { best = (th, acc) }
    }
    let avgMs = ms.reduce(0, +) / Double(max(1, ms.count))
    let line1 = String(format: "%.1f s windows (n=%d): same median %.2f [10%% %.2f]", win, same.count / 2, q(same, 0.5), q(same, 0.1))
    let line2 = String(format: "  diff median %.2f [90%% %.2f]  mix-vs-A median %.2f", q(diff, 0.5), q(diff, 0.9), q(mixT, 0.5))
    let line3 = String(format: "  best threshold %.2f -> %.1f%% correct | %.0f ms each on this Mac", best.0, best.1 * 100, avgMs)
    print(line1 + line2 + line3)
}

// --- does the FILTER OUTPUT during overlap still match the selected person?
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "filtered" {
    let fa = try load16k(dir + "/filtered_mix_forA.wav"), fb = try load16k(dir + "/filtered_mix_forB.wav")
    for win in [1.0, 1.5] {
        let n = Int(win * 16000)
        var aOK: [Float] = [], aVsB: [Float] = [], bOK: [Float] = [], bVsA: [Float] = []
        var t = 16000
        while t + n < min(fa.count, fb.count) {
            let src = t + 10 * 16000                     // same time in the original memos
            if rms(A[src..<(src + n)]) > 0.01 && rms(B[src..<(src + n)]) > 0.01 {   // both actually talking
                let ea = try await emb.embed(audio: Array(fa[t..<(t + n)])), eb = try await emb.embed(audio: Array(fb[t..<(t + n)]))
                aOK.append(cos(ea, refA)); aVsB.append(cos(ea, refB)); bOK.append(cos(eb, refB)); bVsA.append(cos(eb, refA))
            }
            t += n
        }
        let med: ([Float]) -> Float = { let s = $0.sorted(); return s[s.count / 2] }
        let okA = aOK.filter { $0 >= 0.40 }.count, okB = bOK.filter { $0 >= 0.40 }.count
        let wrongA = zip(aOK, aVsB).filter { $0.1 > $0.0 }.count, wrongB = zip(bOK, bVsA).filter { $0.1 > $0.0 }.count
        print(String(format: "filtered overlap %.1f s: for A matches A %.2f vs B %.2f (pass>=0.40: %d/%d, closer to wrong person: %d)", win, med(aOK), med(aVsB), okA, aOK.count, wrongA))
        print(String(format: "                        for B matches B %.2f vs A %.2f (pass>=0.40: %d/%d, closer to wrong person: %d)", med(bOK), med(bVsA), okB, bOK.count, wrongB))
    }
}

if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "clips" { try await scoreClips(dir: dir, emb: emb, refA: refA, refB: refB, A: A, B: B) }

if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "levels" { try await scoreLevels(dir: dir, emb: emb, refA: refA, refB: refB, A: A, B: B) }
