import Foundation
import FluidAudio
// Score several clips of A: how much the filter output (on 60 s of A+B overlap) sounds like A, and the clip's own voiceprint match.
func scoreClips(dir: String, emb: CampPlusEmbedder, refA: [Float], refB: [Float], A: [Float], B: [Float]) async throws {
    for s in [60, 100, 140, 220, 260] {
        let out = try load16k(dir + "/outA_\(s).wav"), clip = try load16k(dir + "/clipA_\(s).wav")
        let clipMatch = cos(try await emb.embed(audio: clip), refA)
        var okN = 0, tot = 0, wrong = 0; var sims: [Float] = []
        var t = 16000; let n = 24000
        while t + n < out.count {
            let src = t + 10 * 16000
            if rms(A[src..<(src + n)]) > 0.01 && rms(B[src..<(src + n)]) > 0.01 {
                let e = try await emb.embed(audio: Array(out[t..<(t + n)]))
                let a = cos(e, refA), b = cos(e, refB); sims.append(a)
                tot += 1; if a >= 0.40 { okN += 1 }; if b > a { wrong += 1 }
            }
            t += n
        }
        let med = sims.sorted()[sims.count / 2]
        print(String(format: "clip A @%3ds: clip voiceprint match %.2f | filter output matches A %.2f, pass %d/%d, wrong person %d", s, clipMatch, med, okN, tot, wrong))
    }
}
