import Foundation
import FluidAudio

/// Runs the speaker model (Sortformer, 4 speaker slots, on the Neural Engine) on the mic audio and turns its
/// "who is talking in each 80 ms frame" output into gate values for Audio.
///
/// Gate rule for the selected person S, per frame:
///   S talking (alone or with others) -> let through
///   someone else talking, S not      -> mute
///   nobody talking                   -> keep open for 0.32 s after S last talked, then mute
/// Frames first get a quick "tentative" answer, which is replaced by the confident one ~0.5 s later.
final class Voices {
    struct Slot { var speechSec: Double = 0; var talking = false; var lastP: Float = 0 }

    let audio: Audio
    private(set) var status = "not loaded"
    private(set) var ready = false
    private var diarizer: SortformerDiarizer?
    private let config = Tuning.sortformerConfig
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private var readIdx = 0

    // predictions: frame -> 4 probabilities, plus whether it is the confident (finalized) answer
    private var preds: [Int: [Float]] = [:]
    private var final: Set<Int> = []
    private(set) var latestFrame = -1
    private(set) var slots = [Slot](repeating: Slot(), count: 4)
    private(set) var procMs: Double = 0
    private(set) var modelLagSec: Double = 0
    private(set) var errors = 0
    var threshold: Float = 0.5
    let hangover = 4                                   // frames (0.32 s)

    private var selectedSlot: Int? = nil
    private var extraction = false          // voice filter running: when nobody is detected, let the filtered audio through

    func setExtraction(_ on: Bool) {
        lock.withLock {
            guard extraction != on else { return }
            extraction = on
            if latestFrame >= 0 { recompute(from: max(0, latestFrame - 100)) }
        }
    }

    /// Confident frames where only this person was talking: (frame, score = p_them * (1 - max p_others)).
    func soloFrames(slot s: Int) -> [(Int, Float)] {
        lock.withLock {
            final.compactMap { f -> (Int, Float)? in
                guard let p = preds[f], p[s] > 0.6 else { return nil }
                let other = (0..<4).filter { $0 != s }.map { p[$0] }.max() ?? 0
                return other < 0.25 ? (f, p[s] * (1 - other)) : nil
            }.sorted { $0.0 < $1.0 }
        }
    }

    init(audio: Audio) { self.audio = audio }

    func load() async {
        status = "downloading speaker model (first time only)..."
        do {
            let models = try await SortformerModels.loadFromHuggingFace(config: config)
            let d = SortformerDiarizer(config: config)
            d.initialize(models: models)
            diarizer = d
            ready = true
            status = "ready"
        } catch {
            status = "model failed to load: \(error.localizedDescription)"
        }
    }

    func start() {
        guard let diarizer else { return }
        diarizer.reset()
        lock.withLock { preds = [:]; final = []; latestFrame = -1; slots = .init(repeating: Slot(), count: 4) }
        readIdx = 0
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    func stop() { running = false }

    func select(_ slot: Int?) {
        lock.withLock {
            selectedSlot = slot
            audio.gating = slot != nil
            if slot != nil, latestFrame >= 0 { recompute(from: max(0, latestFrame - 100)) }
        }
    }

    /// Confident (finalized) probabilities for frame f, or nil if not decided yet. And the newest finalized frame.
    func finalPred(_ f: Int) -> [Float]? { lock.withLock { final.contains(f) ? preds[f] : nil } }
    var latestFinal: Int { lock.withLock { final.max() ?? -1 } }

    func snapshot() -> (slots: [Slot], latest: [Float], latestIsFinal: Bool, recent: [[Float]]) {
        lock.withLock {
            let latest = preds[latestFrame] ?? [0, 0, 0, 0]
            let recent = (max(0, latestFrame - 99)...max(0, latestFrame)).map { preds[$0] ?? [0, 0, 0, 0] }
            return (slots, latest, final.contains(latestFrame), recent)
        }
    }

    // MARK: model thread
    private func loop() {
        let minBatch = Int(audio.sampleRate * 0.04)
        while running {
            let w = audio.wIdx
            if w - readIdx > audio.ringSize - Int(audio.sampleRate) { readIdx = w - Int(audio.sampleRate) }   // fell far behind: skip
            if w - readIdx < minBatch { Thread.sleep(forTimeInterval: 0.01); continue }
            let samples = audio.read(from: readIdx, to: w)
            readIdx = w
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                if let u = try diarizer?.process(samples: samples, sourceSampleRate: audio.sampleRate) {
                    procMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    apply(u.chunkResult)
                }
            } catch { errors += 1 }
            modelLagSec = Double(w) / audio.sampleRate - Double(latestFrame + 1) * Audio.frameSec
        }
    }

    private func apply(_ c: DiarizerChunkResult) {
        let n = 4
        lock.withLock {
            var first = Int.max
            for i in 0..<c.finalizedFrameCount {
                let f = c.startFrame + i
                let p = Array(c.finalizedPredictions[(i * n)..<(i * n + n)])
                preds[f] = p; final.insert(f); first = min(first, f)
                for s in 0..<n where p[s] > threshold { slots[s].speechSec += Audio.frameSec }
            }
            for i in 0..<c.tentativeFrameCount {
                let f = c.tentativeStartFrame + i
                if final.contains(f) { continue }
                preds[f] = Array(c.tentativePredictions[(i * n)..<(i * n + n)]); first = min(first, f)
            }
            latestFrame = max(latestFrame, c.tentativeStartFrame + c.tentativeFrameCount - 1, c.startFrame + c.finalizedFrameCount - 1)
            // "talking" = above threshold in any of the last 6 frames we have
            for s in 0..<n {
                let lastFrames = (max(0, latestFrame - 5)...max(0, latestFrame)).compactMap { preds[$0]?[s] }
                slots[s].lastP = lastFrames.last ?? 0
                slots[s].talking = lastFrames.contains { $0 > threshold }
            }
            // forget old frames
            if preds.count > 3000 { let cut = latestFrame - 2000; preds = preds.filter { $0.key >= cut }; final = final.filter { $0 >= cut } }
            if first != Int.max { recompute(from: first) }
        }
    }

    /// caller holds lock
    private func recompute(from start: Int) {
        guard selectedSlot != nil, latestFrame >= 0 else { return }
        if Tuning.smoothing { recomputeSmoothed(from: start) } else { recomputeOld(from: start) }
    }

    /// Smoothed mute (2026-11-22). Built from NVIDIA's tuned Sortformer post-processing and the replay of 13 sessions
    /// (peeps 45 -> 5):
    ///  - your person: counts as talking above 0.5, keeps counting until below 0.3 (no flicker cuts); and the mute
    ///    opens 0.24 s BEFORE they start (possible because of the playback delay), so first syllables aren't clipped;
    ///  - someone else: must pass NVIDIA's 0.641 (and stay above 0.561) for 2 frames in a row before it mutes;
    ///  - nobody: stays open for 0.64 s after your person, otherwise closed (stops the "peep" at others' onsets).
    private func recomputeSmoothed(from start: Int) {
        guard let s = selectedSlot else { return }
        let tOn: Float = 0.5, tOff: Float = 0.3, oOn: Float = 0.641, oOff: Float = 0.561
        let padOn = 3, gapFill = 4, otherRun = 2, quietHang = 8
        let from = max(0, start - 40)                   // replay a little history to rebuild the state
        var tgt = false, oth = [Bool](repeating: false, count: 4), lastT = Int.min / 2, run = 0
        var vals: [(Int, Float)] = []
        for f in from...latestFrame {
            guard let p = preds[f] else { continue }
            let wasT = tgt
            if p[s] > tOn { tgt = true } else if p[s] < tOff { tgt = false }
            for k in 0..<4 where k != s { if p[k] > oOn { oth[k] = true } else if p[k] < oOff { oth[k] = false } }
            let other = (0..<4).contains { $0 != s && oth[$0] }
            if tgt { lastT = f }
            run = (other && !tgt) ? run + 1 : 0
            let v: Float
            if tgt { v = 1 }
            else if other { v = (run >= otherRun || f - lastT > gapFill) ? 0 : 1 }
            else { v = f - lastT <= quietHang ? 1 : 0 }
            vals.append((f, v))
            if tgt && !wasT {                              // early start: open the frames just before they began
                for k in 1...padOn { if let i = vals.firstIndex(where: { $0.0 == f - k }) { vals[i].1 = 1 } }
            }
        }
        for (f, v) in vals where f >= start - padOn { audio.setGate(frame: f, v) }
        audio.lastKnownGate = vals.last?.1 ?? 1
    }

    private func recomputeOld(from start: Int) {
        guard let s = selectedSlot else { return }
        var v: Float = 1
        for f in max(0, start)...latestFrame {
            guard let p = preds[f] else { continue }
            let target = p[s] > threshold
            let other = (0..<4).contains { $0 != s && p[$0] > threshold }
            if target { v = 1 }
            else if other { v = 0 }
            else if extraction { v = 1 }
            else {
                var recent = false
                for k in 1...hangover where f - k >= 0 { if let q = preds[f - k], q[s] > threshold { recent = true; break } }
                v = recent ? 1 : 0
            }
            audio.setGate(frame: f, v)
        }
        audio.lastKnownGate = v
    }

    /// Frames (finalized) where slot s was the clear single talker, most recent last — used to pick the interrupter.
    func lastSolo(slot s: Int) -> Int {
        lock.withLock { final.filter { f in preds[f].map { $0[s] > 0.6 && (0..<4).allSatisfy { $0 == s || preds[f]![$0] < 0.25 } } ?? false }.max() ?? -1 }
    }
}
