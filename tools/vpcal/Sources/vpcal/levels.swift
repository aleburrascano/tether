import Foundation
import FluidAudio
func scoreLevels(dir: String, emb: CampPlusEmbedder, refA: [Float], refB: [Float], A: [Float], B: [Float]) async throws {
    for (tag, label) in [("m7", "A 7 dB quieter (as recorded)"), ("eq", "A and B equally loud")] + (CommandLine.arguments.count > 3 ? [("sic1", "quieter + subtract interrupter (w=1.0)"), ("sic2", "quieter + subtract interrupter (w=0.8)")] : []) {
        let out = try load16k(dir + (tag.hasPrefix("sic") ? "/outA_\(tag).wav" : "/outA_lvl_\(tag).wav"))
        var ok = 0, tot = 0, wrong = 0; var sims: [Float] = []
        var t = 16000; let n = 24000
        while t + n < out.count {
            let src = t + 10 * 16000
            if rms(A[src..<(src + n)]) > 0.01 && rms(B[src..<(src + n)]) > 0.01 {
                let e = try await emb.embed(audio: Array(out[t..<(t + n)])); let a = cos(e, refA), b = cos(e, refB)
                sims.append(a); tot += 1; if a >= 0.40 { ok += 1 }; if b > a { wrong += 1 }
            }
            t += n
        }
        print(String(format: "%@: filter output matches A %.2f, pass %d/%d, wrong person %d", label, sims.sorted()[sims.count / 2], ok, tot, wrong))
    }
}
