import Foundation
import Accelerate
import AVFoundation

/// 48 kHz <-> 16 kHz by a factor of 3, with a 63-tap windowed-sinc low-pass (cut-off 7 kHz).
/// Both directions have 31 samples (at 48 kHz) of delay, which cancel out when used as a pair.
final class Resampler3 {
    static let L = 63
    static let h: [Float] = {
        let fc = 7000.0 / 48000.0, M = Double(L - 1) / 2
        var h = (0..<L).map { n -> Double in
            let x = Double(n) - M
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(n) / Double(L - 1)) + 0.08 * cos(4 * .pi * Double(n) / Double(L - 1))
            return sinc * w
        }
        let s = h.reduce(0, +); h = h.map { $0 / s }
        return h.map { Float($0) }
    }()
    private var dBuf: [Float] = []
    private var uHist = [Float](repeating: 0, count: 21)

    func reset() { dBuf = []; uHist = .init(repeating: 0, count: 21) }

    func down(_ x: [Float]) -> [Float] {
        dBuf += x
        var out: [Float] = []; out.reserveCapacity(x.count / 3 + 1)
        var i = 0
        Resampler3.h.withUnsafeBufferPointer { hp in dBuf.withUnsafeBufferPointer { bp in
            while i + Resampler3.L <= bp.count {
                var s: Float = 0
                vDSP_dotpr(hp.baseAddress!, 1, bp.baseAddress! + i, 1, &s, vDSP_Length(Resampler3.L))
                out.append(s); i += 3
            }
        } }
        dBuf.removeFirst(i)
        return out
    }

    func up(_ y: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: y.count * 3)
        let h = Resampler3.h
        for (m, v) in y.enumerated() {
            uHist.removeFirst(); uHist.append(v)                   // uHist[20] = newest
            for p in 0..<3 {
                var s: Float = 0
                var j = 0
                while 3 * j + p < Resampler3.L { s += h[3 * j + p] * uHist[20 - j]; j += 1 }
                out[3 * m + p] = 3 * s
            }
        }
        return out
    }
}

/// Runs the voice filter for the selected person (reworked 2026-11-22).
///  - keeps the last 65 s of mic audio at 16 kHz;
///  - clip: built from moments the speaker model says only that person talked, cut into ~1 s pieces, each piece
///    voiceprinted (CAM++) and dropped if it doesn't match the others (stops a wrong voice getting into the clip);
///  - subtraction: the filter is much weaker when your person is quieter than the interrupter (measured 56% vs 90%),
///    so a second filter pulls out the most recent other talker and subtracts them first (measured 56% -> 74%);
///  - quality meter: every 1.5 s, the voiceprint of what is being played is compared with the person's (logged);
///  - all slow voiceprint work runs on a side queue; the audio path never waits for it.
final class Extractor {
    let audio: Audio
    let voices: Voices
    private var tse: TSE?, tse2: TSE?
    private(set) var loadError: String?

    // 16 kHz history (index m ~ 48 kHz index 3m)
    let histSize = 1 << 20
    let hist: UnsafeMutablePointer<Float>
    let outHist: UnsafeMutablePointer<Float>
    private(set) var histW = 0
    private var read48 = 0
    private let down = Resampler3(), upR = Resampler3()

    // control (set from UI, handled on the worker thread)
    var enabled = true
    var wantedSlot: Int? = nil
    /// Narrows a slot's solo frames to the selected person's (set while the voiceprint layer is on).
    var framesFilter: (([(Int, Float)]) -> [(Int, Float)])? = nil
    private var slot: Int? = nil

    // status
    private(set) var active = false
    private(set) var soloSec: Double = 0
    private(set) var refreshes = 0
    private(set) var ms: Double = 0
    private(set) var load: Double = 0              // filter compute time / audio time (must stay < 1)
    private(set) var clipScore: Float = 0          // mean voiceprint agreement of the clip's pieces
    private(set) var quality: Float = -1           // last quality-meter score (played audio vs the person), -1 = none
    private(set) var subtracting: Int? = nil       // interrupter slot being subtracted
    private(set) var subtractSuspended = false
    static let minSoloSec = 2.0

    private var streamStart16 = 0, produced16 = 0, lastRefresh = 0.0, lastTry = 0.0, lastQuality = 0.0, lastInterf = 0.0
    private var lastClipFrames: Set<Int> = []
    private var centroid: [Float]? = nil, interfCentroid: [Float]? = nil
    private var pending: [Float] = []              // samples waiting for the interrupter estimate
    private var denoising = false                  // decided when a filtered stream starts
    private var ambient = false                    // nobody selected: the noise remover runs on the whole room
    private var lp: Float = 0                      // brighten: low-pass state
    private(set) var skips = 0                     // times the filter fell behind and jumped to now
    private var levelEnv: Float = 0                // auto-level: running speech level of what we play
    private(set) var autoGainDB: Float = 0
    private var sessionFile: AVAudioFile?
    private(set) var sessionName = ""
    private var loadHist: [Double] = []
    private var thread: Thread?
    private var running = false
    private let side = DispatchQueue(label: "extractor.side", qos: .utility)
    private var sideBusy = false
    // results handed from the side queue to the worker thread
    private let handoff = NSLock()
    private var newClip: (clip: [Float], solo: Double, frames: Set<Int>, score: Float, centroid: [Float]?, slot: Int, first: Bool)? = nil
    private var newInterf: (clip: [Float], slot: Int, centroid: [Float]?)? = nil
    // events for the log (drained by Model)
    private let evLock = NSLock()
    private var events: [[String: Any]] = []
    func drainEvents() -> [[String: Any]] { evLock.withLock { let e = events; events = []; return e } }
    private func log(_ type: String, _ d: [String: Any]) { var x = d; x["type"] = type; x["audio_t"] = (now * 100).rounded() / 100; evLock.withLock { events.append(x) } }

    init(audio: Audio, voices: Voices) {
        self.audio = audio; self.voices = voices
        hist = .allocate(capacity: 1 << 20); hist.initialize(repeating: 0, count: 1 << 20)
        outHist = .allocate(capacity: 1 << 20); outHist.initialize(repeating: 0, count: 1 << 20)
        var err: NSString?
        tse = TSE(threads: 4, error: &err)
        if tse == nil { loadError = (err as String?) ?? "filter failed to load" }
        tse2 = TSE(threads: 4, error: &err)
    }

    func start() {
        histW = 0; read48 = 0; down.reset(); upR.reset()
        slot = nil; active = false; soloSec = 0; refreshes = 0; quality = -1; clipScore = 0
        ambient = false; skips = 0; lp = 0
        subtracting = nil; subtractSuspended = false; pending = []; loadHist = []; centroid = nil; interfCentroid = nil
        handoff.withLock { newClip = nil; newInterf = nil }
        autoGainDB = 0; levelEnv = 0
        sessionFile = nil; sessionName = ""
        if Tuning.recordSession {
            let name = "session_\(Audio.stamp()).wav"
            let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            sessionFile = try? AVAudioFile(forWriting: u, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
            if sessionFile != nil { sessionName = name }
        }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.start(); thread = t
    }
    func stop() { running = false; audio.endClean(); voices.setExtraction(false); sessionFile = nil }

    private var now: Double { Double(histW) / 16000 }

    // MARK: worker thread
    private func loop() {
        let block = 1920                                        // 40 ms at 48 kHz
        while running {
            let avail = audio.wIdx - read48
            if avail < block { Thread.sleep(forTimeInterval: 0.005); control(); continue }
            // Fell more than 0.8 s behind (phone too busy): never play old sound. Jump to now and start the
            // filtered stream again; the skipped stretch stays silent in the history so frame numbers still line up.
            if avail > Int(audio.sampleRate * 0.8) {
                let skip = (avail - block) / (3 * 1280) * (3 * 1280)
                for i in 0..<(skip / 3) { hist[(histW + i) & (histSize - 1)] = 0; outHist[(histW + i) & (histSize - 1)] = 0 }
                histW += skip / 3; read48 += skip; down.reset(); skips += 1
                log("filter_skip", ["skipped_sec": Double(skip) / audio.sampleRate, "load": (load * 100).rounded() / 100])
                loadHist = []; ambient = false
                if slot != nil { slot = nil }                    // control() sees a fresh selection and restarts cleanly
                else { audio.endClean() }
                continue
            }
            let n = avail / block * block
            let x = audio.read(from: read48, to: read48 + n); read48 += n
            let y = down.down(x)
            let base = histW
            for (i, v) in y.enumerated() { hist[(base + i) & (histSize - 1)] = v; outHist[(base + i) & (histSize - 1)] = 0 }
            histW += y.count
            if let f = sessionFile, !y.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
                                                                          frameCapacity: AVAudioFrameCount(y.count)) {
                b.frameLength = AVAudioFrameCount(y.count)
                y.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: y.count) }
                try? f.write(from: b)
            }
            if active, let tse {
                let t0 = CFAbsoluteTimeGetCurrent()
                var feed = y
                if Tuning.subtract && !subtractSuspended, let t2 = tse2 {
                    pending += y
                    if t2.hasVoice && subtracting != nil {
                        var b = [Float](repeating: 0, count: y.count + 2048)
                        let k = Int(y.withUnsafeBufferPointer { yp in b.withUnsafeMutableBufferPointer { bp in
                            t2.push(yp.baseAddress!, count: Int32(y.count), out: bp.baseAddress!, capacity: Int32(bp.count)) } })
                        let m = min(k, pending.count)
                        feed = (0..<m).map { pending[$0] - b[$0] }
                        pending.removeFirst(m)
                    } else { feed = pending; pending = [] }
                } else if !pending.isEmpty { feed = pending + y; pending = [] }
                var out = [Float](repeating: 0, count: feed.count + 4096)
                let k = feed.isEmpty ? 0 : Int(feed.withUnsafeBufferPointer { fp in out.withUnsafeMutableBufferPointer { op in
                    tse.push(fp.baseAddress!, count: Int32(feed.count), out: op.baseAddress!, capacity: Int32(op.count)) } })
                var clean = Array(out[0..<k])
                if denoising, let d = Denoiser.shared.process(clean) { clean = d }
                if Tuning.brighten { clean = brighten(clean) }
                if Tuning.autoLevel { clean = autoLevel(clean) }
                for (i, v) in clean.enumerated() { outHist[(streamStart16 + produced16 + i) & (histSize - 1)] = v }
                produced16 += clean.count
                audio.writeClean(upR.up(clean))
                ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                trackLoad(ms / (Double(y.count) / 16.0))
            } else if slot == nil && wantedSlot == nil && Tuning.denoise && Denoiser.shared.ready && !y.isEmpty {
                // Nobody selected: everyone is heard, with background noise and echo removed.
                if !ambient {
                    ambient = true
                    Denoiser.shared.restart(); upR.reset()
                    audio.beginClean(at: 3 * base)
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                if let d = Denoiser.shared.process(y) { audio.writeClean(upR.up(d)) }
                ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                trackLoad(ms / (Double(y.count) / 16.0))
            } else if ambient {
                ambient = false
                if !active { audio.endClean() }
            }
            control()
        }
    }

    /// Brighten: +5 dB shelf above ~2 kHz (the filter and the noise remover both dull the voice).
    private func brighten(_ x: [Float]) -> [Float] {
        var out = x
        for i in 0..<x.count { lp = 0.456 * lp + 0.544 * x[i]; out[i] = x[i] + 0.8 * (x[i] - lp) }
        return out
    }

    /// Auto-level: bring the person you're hearing to about -24 dBFS (before your boost slider), at most +15 dB up or
    /// 6 dB down, following their speech level over ~1 s (quiet moments don't count, so background isn't pumped up).
    private func autoLevel(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let ms = x.reduce(0) { $0 + $1 * $1 } / Float(x.count)
        let db = 10 * log10f(ms + 1e-12)
        if db > -55 {                                            // speech-ish, not silence
            let e = sqrtf(ms)
            levelEnv = levelEnv == 0 ? e : levelEnv * 0.95 + e * 0.05
        }
        guard levelEnv > 0 else { return x }
        let want = max(-6, min(15, -24 - 20 * log10f(levelEnv)))
        autoGainDB += (want - autoGainDB) * 0.1
        let g = powf(10, autoGainDB / 20)
        return x.map { $0 * g }
    }

    /// Everything must stay faster than real time; if the 2 s average passes 97%, stop subtracting (first thing to drop).
    private func trackLoad(_ r: Double) {
        loadHist.append(r); if loadHist.count > 50 { loadHist.removeFirst() }
        load = loadHist.reduce(0, +) / Double(loadHist.count)
        if Tuning.subtract && !subtractSuspended && loadHist.count == 50 && load > 0.97 {
            subtractSuspended = true
            log("subtract_suspended", ["load": (load * 100).rounded() / 100])
        }
    }

    /// Start / stop / refresh, on the worker thread. Slow work goes to the side queue.
    private func control() {
        let want = enabled ? wantedSlot : nil
        if want != slot {
            slot = want; active = false; soloSec = 0; lastClipFrames = []; lastTry = 0; quality = -1; centroid = nil
            subtracting = nil; interfCentroid = nil; pending = []
            handoff.withLock { newClip = nil; newInterf = nil }
            ambient = false
            audio.endClean(); voices.setExtraction(false)
        }
        guard let s = slot, let tse else { return }

        // apply results from the side queue
        handoff.lock(); let c = newClip, i = newInterf; newClip = nil; newInterf = nil; handoff.unlock()
        if let c, c.slot == s {
            let ok = c.clip.withUnsafeBufferPointer { tse.setVoice($0.baseAddress!, count: Int32($0.count), resetState: c.first) }
            if ok {
                soloSec = c.solo; lastClipFrames = c.frames; clipScore = c.score; centroid = c.centroid ?? centroid
                if c.first {
                    streamStart16 = histW; produced16 = 0; upR.reset(); pending = []
                    denoising = Tuning.denoise && Denoiser.shared.ready
                    if denoising { Denoiser.shared.restart() }
                    levelEnv = 0
                    audio.beginClean(at: 3 * streamStart16)
                    active = true; lastRefresh = now; voices.setExtraction(true)
                } else { refreshes += 1 }
                log("clip", ["slot": s, "first": c.first, "solo_sec": c.solo, "score": Double(c.score)])
            }
        }
        if let i, let t2 = tse2, i.slot != s {
            if !pending.isEmpty, active {                      // flush what the old interrupter stream still held
                var out = [Float](repeating: 0, count: pending.count + 4096)
                let k = Int(pending.withUnsafeBufferPointer { fp in out.withUnsafeMutableBufferPointer { op in
                    tse.push(fp.baseAddress!, count: Int32(pending.count), out: op.baseAddress!, capacity: Int32(op.count)) } })
                for (j, v) in out[0..<k].enumerated() { outHist[(streamStart16 + produced16 + j) & (histSize - 1)] = v }
                produced16 += k; audio.writeClean(upR.up(Array(out[0..<k]))); pending = []
            }
            if i.clip.withUnsafeBufferPointer({ t2.setVoice($0.baseAddress!, count: Int32($0.count), resetState: true) }) {
                subtracting = i.slot; interfCentroid = i.centroid
                log("subtract", ["interrupter": i.slot])
            }
        }

        guard !sideBusy else { return }
        if !active {
            if now - lastTry < 0.5 { return }
            lastTry = now
            runSide { self.buildClip(slot: s, first: true) }
        } else if now - lastRefresh >= 10 {
            lastRefresh = now
            runSide { self.buildClip(slot: s, first: false) }
        } else if Tuning.subtract && !subtractSuspended && now - lastInterf >= 3 {
            lastInterf = now
            runSide { self.pickInterrupter(target: s) }
        } else if now - lastQuality >= 3 && Voiceprint.shared.ready {
            lastQuality = now
            let end = produced16 + streamStart16
            runSide { self.measureQuality(end: end) }
        }
    }

    private func runSide(_ f: @escaping () -> Void) {
        sideBusy = true
        side.async { f(); self.sideBusy = false }
    }

    // MARK: side queue
    /// The person's best ~3 s from the last minute. Runs of frames where only they talked are grouped into pieces of
    /// at least ~1 s; with the voiceprint check on, pieces that don't match the others are dropped.
    private func buildClip(slot s: Int, first: Bool) {
        let fLen = 1280
        let prevSolo = soloSec
        var frames = voices.soloFrames(slot: s)
        if let narrow = framesFilter { frames = narrow(frames) }
        let oldest = histW - histSize + fLen
        let usable = frames.filter { $0.0 * fLen >= max(0, oldest) && ($0.0 + 1) * fLen <= histW }
        if usable.isEmpty { soloSec = 0; return }
        var runs: [[(Int, Float)]] = []
        for f in usable { if let last = runs.last?.last, last.0 == f.0 - 1 { runs[runs.count - 1].append(f) } else { runs.append([f]) } }
        // rank runs: longer and more confident first, most recent wins ties
        let ranked = runs.sorted { a, b in
            let sa = a.map { $0.1 }.reduce(0, +), sb = b.map { $0.1 }.reduce(0, +)
            return sa != sb ? sa > sb : a.last!.0 > b.last!.0
        }
        // pieces of >= 13 frames (~1 s): a long run alone, or short runs joined
        var pieces: [[Int]] = [], cur: [Int] = []
        for r in ranked {
            cur += r.map { $0.0 }
            if cur.count >= 13 { pieces.append(cur); cur = [] }
            if pieces.count >= 8 { break }
        }
        if !cur.isEmpty && pieces.count < 8 { pieces.append(cur) }
        func audioOf(_ fs: [Int]) -> [Float] {
            var a: [Float] = []
            for f in fs.sorted() {
                var piece = (0..<fLen).map { hist[(f * fLen + $0) & (histSize - 1)] }
                for i in 0..<40 { let g = Float(i) / 40; piece[i] *= g; piece[fLen - 1 - i] *= g }
                a += piece
            }
            return a
        }
        var keep = pieces, score: Float = 1, cent: [Float]? = nil, dropped = 0
        if Tuning.clipCheck && Voiceprint.shared.ready && pieces.count >= 2 {
            let embs = pieces.map { Voiceprint.shared.embed(audioOf($0)) }
            let good = zip(pieces, embs).compactMap { p, e in e.map { (p, $0) } }
            // reference: the first (most confident) pieces; plus the earlier centroid if refining
            var ref = Voiceprint.mean(Array(good.prefix(3)).map { $0.1 })
            if let c = centroid, !first { ref = Voiceprint.mean([c, ref ?? c]) }
            if let ref {
                let scored = good.map { ($0.0, Voiceprint.cos($0.1, ref), $0.1) }
                let ok = scored.filter { $0.1 >= Voiceprint.sameThreshold }
                dropped = scored.count - ok.count
                keep = ok.map { $0.0 }
                score = ok.isEmpty ? 0 : ok.map { $0.1 }.reduce(0, +) / Float(ok.count)
                cent = Voiceprint.mean(ok.map { $0.2 })
            }
        }
        var clip: [Float] = [], used = Set<Int>()
        for p in keep { clip += audioOf(p); p.forEach { used.insert($0) }; if clip.count >= 48000 { break } }
        let solo = Double(min(clip.count, 48000)) / 16000
        if first { soloSec = solo }                                   // shown while still learning
        if clip.isEmpty || solo < Extractor.minSoloSec { return }
        if !first && (used == lastClipFrames || solo < prevSolo - 0.01) { return }
        while clip.count < 48000 { clip += clip }
        clip = Array(clip[0..<48000])
        if dropped > 0 { log("clip_pieces_dropped", ["slot": s, "dropped": dropped, "kept": keep.count]) }
        saveWav("clip_s\(s)_\(Audio.stamp())", clip)
        handoff.withLock { newClip = (clip, solo, used, score, cent, s, first) }
    }

    /// The other person who most recently talked alone (within 20 s) becomes the one to subtract.
    private func pickInterrupter(target s: Int) {
        let recent = (0..<4).filter { $0 != s }.map { ($0, voices.lastSolo(slot: $0)) }.filter { $0.1 >= 0 }
        guard let best = recent.max(by: { $0.1 < $1.1 }), Double(voices.latestFinal - best.1) * 0.08 < 20 else { return }
        if best.0 == subtracting { return }
        // reuse the clip builder's piece logic, without the voiceprint check (speed), for the interrupter
        let fLen = 1280
        let frames = voices.soloFrames(slot: best.0).filter { $0.0 * fLen >= max(0, histW - histSize + fLen) && ($0.0 + 1) * fLen <= histW }
        guard frames.count >= 25 else { return }                 // need >= 2 s of them alone
        var clip: [Float] = []
        for (f, _) in frames.suffix(60) { clip += (0..<fLen).map { hist[(f * fLen + $0) & (histSize - 1)] } }
        while clip.count < 48000 { clip += clip }
        let c = Voiceprint.shared.ready ? Voiceprint.shared.embed(Array(clip.prefix(24000))) : nil
        handoff.withLock { newInterf = (Array(clip.suffix(48000)), best.0, c) }
    }

    /// Quality meter: does the last 1.5 s of what we played sound like the person? (and not like the interrupter)
    private func measureQuality(end: Int) {
        guard let cent = centroid, end > 24000 else { return }
        let a = (end - 24000)..<end
        let x = a.map { outHist[$0 & (histSize - 1)] }
        let e = x.reduce(0) { $0 + $1 * $1 } / Float(x.count)
        guard 10 * log10(e + 1e-12) > -50, let v = Voiceprint.shared.embed(x) else { return }
        quality = Voiceprint.cos(v, cent)
        var d: [String: Any] = ["score": (Double(quality) * 100).rounded() / 100, "ms": Int(Voiceprint.shared.lastMs)]
        if let ic = interfCentroid { d["vs_interrupter"] = (Double(Voiceprint.cos(v, ic)) * 100).rounded() / 100 }
        log("quality", d)
    }

    // MARK: metrics / recordings
    func levels(frame f: Int) -> (inDB: Double, outDB: Double?)? {
        let a = f * 1280, b = a + 1280
        guard a >= 0, b <= histW, a >= histW - histSize else { return nil }
        var ei: Float = 0, eo: Float = 0
        for i in a..<b { let x = hist[i & (histSize - 1)], y = outHist[i & (histSize - 1)]; ei += x * x; eo += y * y }
        let inDB = 10 * log10(Double(ei / 1280) + 1e-12)
        let outOK = active && a >= streamStart16 && b <= streamStart16 + produced16
        return (inDB, outOK ? 10 * log10(Double(eo / 1280) + 1e-12) : nil)
    }
    var outReady16: Int { active ? streamStart16 + produced16 : histW }

    func saveRecent(seconds: Double, stamp: String, tag: String = "rec16") -> [URL] {
        let n = min(Int(seconds * 16000), histW)
        let a = (histW - n)..<histW
        var urls: [URL] = []
        if let u = saveWav("\(tag)_in_\(stamp)", a.map { hist[$0 & (histSize - 1)] }) { urls.append(u) }
        if let u = saveWav("\(tag)_out_\(stamp)", a.map { outHist[$0 & (histSize - 1)] }) { urls.append(u) }
        return urls
    }

    @discardableResult
    private func saveWav(_ name: String, _ x: [Float]) -> URL? {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".wav")
        return Extractor.writeWav(u, x) ? u : nil
    }

    static func writeWav(_ url: URL, _ x: [Float]) -> Bool {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let f = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                                       commonFormat: .pcmFormatFloat32, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, x.count))) else { return false }
        b.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        return (try? f.write(from: b)) != nil
    }
}
